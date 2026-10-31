#!/bin/bash

# shellcheck source=Containers/nextcloud/configure-apps.sh
source /configure-apps.sh

# version_greater A B returns whether A > B
version_greater() {
    [ "$(printf '%s\n' "$@" | sort -t '.' -n -k1,1 -k2,2 -k3,3 -k4,4 | head -n 1)" != "$1" ]
}

# return true if specified directory is empty
directory_empty() {
    [ -z "$(ls -A "$1/")" ]
}

if [ "$AIO_LOG_LEVEL" = 'debug' ]; then
    set -x
fi

run_upgrade_if_needed_due_to_app_update() {
    if php /var/www/html/occ status | grep maintenance | grep -q true; then
        php /var/www/html/occ maintenance:mode --off
    fi
    if php /var/www/html/occ status | grep needsDbUpgrade | grep -q true; then
        php /var/www/html/occ upgrade
    fi
}

NEXTCLOUD_LOG_LEVEL="$(case "$AIO_LOG_LEVEL" in
    debug) printf '0' ;;
    info) printf '1' ;;
    warn) printf '2' ;;
    error) printf '3' ;;
esac)"
export NEXTCLOUD_LOG_LEVEL

# Create cert bundle start # Do not remove or change this line!
if env | grep -q NEXTCLOUD_TRUSTED_CERTIFICATES_; then

    # Enable debug mode
    set -x

    # Default vars
    CERTIFICATES_ROOT_DIR="/var/www/html/data/certificates"
    CERTIFICATE_BUNDLE="/var/www/html/data/certificates/ca-bundle.crt"
    
    # Remove old root certs and recreate them with current ones
    rm -rf "$CERTIFICATES_ROOT_DIR"
    mkdir -p "$CERTIFICATES_ROOT_DIR"

    # Retrieve default root cert bundle
    if ! [ -f "$SOURCE_LOCATION/resources/config/ca-bundle.crt" ]; then
        echo "Root ca-bundle not found. Only concattening configured NEXTCLOUD_TRUSTED_CERTIFICATES files!"
        # Recreate cert file
        touch "$CERTIFICATE_BUNDLE"
    else
        # Write default bundle to the target ca file
        cat "$SOURCE_LOCATION/resources/config/ca-bundle.crt" > "$CERTIFICATE_BUNDLE"
    fi

    # Iterate through certs
    TRUSTED_CERTIFICATES="$(env | grep NEXTCLOUD_TRUSTED_CERTIFICATES_ | grep -oP '^[A-Z_a-z0-9]+')"
    mapfile -t TRUSTED_CERTIFICATES <<< "$TRUSTED_CERTIFICATES"
    for certificate in "${TRUSTED_CERTIFICATES[@]}"; do

        # Create new line
        echo "" >> "$CERTIFICATE_BUNDLE"

        # Check if variable is an actual cert
        if echo "${!certificate}" | grep -q "BEGIN CERTIFICATE" && echo "${!certificate}" | grep -q "END CERTIFICATE"; then
            # Write out cert to bundle
            echo "${!certificate}" >> "$CERTIFICATE_BUNDLE"
        fi

        # Create file in cert dir for extra logic in other places
        if ! [ -f "$CERTIFICATES_ROOT_DIR/$CERTIFICATE_NAME" ]; then
            touch "$CERTIFICATES_ROOT_DIR/$CERTIFICATE_NAME"
        fi

    done

    # Backwards compatibility with older instances
    if [ -f "/var/www/html/config/postgres.config.php" ]; then
        sed -i "s|/var/www/html/data/certificates/POSTGRES|/var/www/html/data/certificates/ca-bundle.crt|" /var/www/html/config/postgres.config.php
        sed -i "s|/var/www/html/data/certificates/MYSQL|/var/www/html/data/certificates/ca-bundle.crt|" /var/www/html/config/postgres.config.php
    fi

    # Print out bundle one last time
    cat "$CERTIFICATE_BUNDLE"

    # Disable debug mode
    if [ "$AIO_LOG_LEVEL" != 'debug' ]; then
        set +x
    fi
fi

# Create cert bundle end # Do not remove or change this line!

# Adjust DATABASE_TYPE to by Nextcloud supported value
if [ "$DATABASE_TYPE" = postgres ]; then
    export DATABASE_TYPE=pgsql
fi

# Only start container if Redis is accessible
# shellcheck disable=SC2153
if ! startup_wait "$REDIS_HOST" "$REDIS_PORT" Redis; then
    echo "Redis is unavailable; Nextcloud startup stopped." >&2
    exit 1
fi

# Check permissions in ncdata
test_file="$NEXTCLOUD_DATA_DIR/this-is-a-test-file"
touch "$test_file"
if ! [ -f "$test_file" ]; then
    echo "The www-data user does not appear to have access rights to the data directory."
    echo "It is possible that the files are on a filesystem that does not support standard Linux permissions,"
    echo "or the permissions simply need to be adjusted. Please change the permissions as described below."
    echo "Current permissions are:"
    stat -c "%u:%g %a" "$NEXTCLOUD_DATA_DIR"
    echo "(userID:groupID permissions)"
    echo "They should be:"
    echo "33:0 750"
    echo "(userID:groupID permissions)"
    echo "Also, ensure that all parent directories on the host of your chosen data directory are publicly readable."
    echo "For example: sudo chmod +r /mnt  (adjust this command as needed)."
    echo "If you want to use a FUSE mount as the data directory, add 'allow_other' as an additional mount option."
    echo "For SMB/CIFS mounts as the data directory, see:"
    echo "  https://github.com/nextcloud/all-in-one#can-i-use-a-cifssmb-share-as-nextclouds-datadir"
    exit 1
fi
rm -f "$test_file"

if [ -f /var/www/html/version.php ]; then
    # shellcheck disable=SC2016
    installed_version="$(php -r 'require "/var/www/html/version.php"; echo implode(".", $OC_Version);')"
    if [ -z "$installed_version" ]; then
        echo "Could not determine the installed Nextcloud version via php -r. The PHP installation might be broken."
        echo "Please check the container logs and your PHP installation."
        exit 1
    fi
else
    installed_version="0.0.0.0"
fi
if [ -f "$SOURCE_LOCATION/version.php" ]; then
    # shellcheck disable=SC2016
    image_version="$(php -r "require '$SOURCE_LOCATION/version.php'; echo implode('.', \$OC_Version);")"
else
    image_version="$installed_version"
fi

# unset admin password
if [ "$installed_version" != "0.0.0.0" ]; then
    unset ADMIN_PASSWORD
fi

# Don't start the container if Nextcloud is not compatible with the PHP version
if [ -f "/var/www/html/lib/versioncheck.php" ] && ! php /var/www/html/lib/versioncheck.php; then
    echo "Your installed Nextcloud version is not compatible with the PHP version provided by this image."
    echo "This typically occurs when you restore an older Nextcloud backup that does not support the"
    echo "PHP version included in this image."
    echo "Please restore a more recent backup that includes a compatible Nextcloud version."
    echo "If you do not have a more recent backup, refer to the manual upgrade documentation:"
    echo "  https://github.com/nextcloud/all-in-one/blob/main/manual-upgrade.md"
    exit 1
fi

# Do not start the container if the last update failed
if [ -f "$NEXTCLOUD_DATA_DIR/update.failed" ]; then
    echo "The last Nextcloud update failed."
    echo "Please restore from a backup and try again."
    echo "If you do not have a backup, you can delete the update.failed file in the data directory"
    echo "to allow the container to start again."
    exit 1
fi

# Do not start the container if the install failed
if [ -f "$NEXTCLOUD_DATA_DIR/install.failed" ]; then
    echo "The initial Nextcloud installation failed."
    echo "For more information about what went wrong, check the logs above."
    echo "Please reset AIO properly and try again."
    echo "See:"
    echo "  https://github.com/nextcloud/all-in-one#how-to-properly-reset-the-instance"
    exit 1
fi

# Skip any update if Nextcloud was just restored
if ! [ -f "$NEXTCLOUD_DATA_DIR/skip.update" ]; then
    if version_greater "$image_version" "$installed_version"; then
        # Check if it skips a major version
        INSTALLED_MAJOR="${installed_version%%.*}"
        IMAGE_MAJOR="${image_version%%.*}"
        
        if [ "$installed_version" != "0.0.0.0" ]; then
            # Write output to logfile.
            exec > >(tee -i "/var/www/html/data/update.log")
            exec 2>&1
        fi

        if [ "$installed_version" != "0.0.0.0" ] && [ "$((IMAGE_MAJOR - INSTALLED_MAJOR))" -gt 1 ]; then
            echo "La versión instalada no permite actualizar directamente a la versión de esta imagen. Restaure una versión compatible de la suite." >&2
            exit 1
        fi

        if [ "$installed_version" != "0.0.0.0" ]; then
# Check connection to appstore start # Do not remove or change this line!
            appstore_deadline=$((SECONDS + 90))
            CURL_STATUS=""
            while [ "$SECONDS" -lt "$appstore_deadline" ]; do
                echo -e "Checking connection to the app store..."
                APPSTORE_URL="https://apps.nextcloud.com/api/v1"
                if grep -q appstoreurl /var/www/html/config/config.php; then
                    set -x
                    APPSTORE_URL="$(grep appstoreurl /var/www/html/config/config.php | grep -oP 'https://.*v[0-9]+')"
                    if [ "$AIO_LOG_LEVEL" != 'debug' ]; then
                        set +x
                    fi
                fi
                # Default appstoreurl parameter in config.php defaults to 'https://apps.nextcloud.com/api/v1' so we check for the apps.json file stored in there
                appstore_remaining=$((appstore_deadline - SECONDS))
                [ "$appstore_remaining" -gt 0 ] || break
                CURL_STATUS="$(curl -LI "$APPSTORE_URL"/apps.json --connect-timeout 5 \
                    --max-time "$appstore_remaining" -o /dev/null -w '%{http_code}\n' -s)"
                if [[ "$CURL_STATUS" = "200" ]]
                then
                    echo "App store is reachable."
                    break
                else
                    echo "Curl did not return a 200 status. Is the app store reachable?"
                    appstore_remaining=$((appstore_deadline - SECONDS))
                    if [ "$appstore_remaining" -gt 0 ]; then
                        [ "$appstore_remaining" -le 5 ] || appstore_remaining=5
                        sleep "$appstore_remaining"
                    fi
                fi
            done
            if [ "$CURL_STATUS" != 200 ]; then
                echo "The app store is unavailable; Nextcloud update stopped." >&2
                exit 1
            fi
# Check connection to appstore end # Do not remove or change this line!

            run_upgrade_if_needed_due_to_app_update

            php /var/www/html/occ maintenance:mode --off

            echo "Getting and backing up the status of apps for later; this might take a while..."
            NC_APPS="$(find /var/www/html/custom_apps/ -type d -maxdepth 1 -mindepth 1 | sed 's|/var/www/html/custom_apps/||g')"
            if [ -z "$NC_APPS" ]; then
                echo "No apps detected. Aborting export of app status..."
                APPSTORAGE="no-export-done"
            else
                mapfile -t NC_APPS_ARRAY <<< "$NC_APPS"
                declare -Ag APPSTORAGE
                echo "Disabling apps before the update to make the update procedure safer. This can take a while..."
                for app in "${NC_APPS_ARRAY[@]}"; do
                    if APPSTORAGE[$app]="$(php /var/www/html/occ config:app:get "$app" enabled)"; then
                        php /var/www/html/occ app:disable "$app"
                    else
                        APPSTORAGE[$app]=""
                        echo "Not disabling $app because the occ command to get its enabled state failed."
                    fi
                done
            fi

            if [ "$((IMAGE_MAJOR - INSTALLED_MAJOR))" -eq 1 ]; then
                php /var/www/html/occ config:system:delete app_install_overwrite
            fi

            php /var/www/html/occ app:update --all

            run_upgrade_if_needed_due_to_app_update
        fi

        echo "Initializing Nextcloud $image_version ..."

        # Copy over initial data from Nextcloud archive
        rsync -rlD --delete \
            --exclude-from=/upgrade.exclude \
            "$SOURCE_LOCATION/" \
            /var/www/html/

        # Copy custom_apps from Nextcloud archive
        if ! directory_empty "$SOURCE_LOCATION/custom_apps"; then
            set -x
            for app in "$SOURCE_LOCATION/custom_apps"/*; do
                app_id="$(basename "$app")"
                mkdir -p "/var/www/html/custom_apps/$app_id"
                rsync -rlD --delete \
                    --include "/$app_id/" \
                    --exclude '/*' \
                    "$SOURCE_LOCATION/custom_apps/" \
                    /var/www/html/custom_apps/
            done
            if [ "$AIO_LOG_LEVEL" != 'debug' ]; then
                set +x
            fi
        fi

        # Copy these from Nextcloud archive if they don't exist yet (i.e. new install)
        for dir in config data custom_apps themes; do
            if [ ! -d "/var/www/html/$dir" ] || directory_empty "/var/www/html/$dir"; then
                rsync -rlD \
                    --include "/$dir/" \
                    --exclude '/*' \
                    "$SOURCE_LOCATION/" \
                    /var/www/html/
            fi
        done

        rsync -rlD --delete \
            --include '/config/' \
            --exclude '/*' \
            --exclude '/config/CAN_INSTALL' \
            --exclude '/config/config.sample.php' \
            --exclude '/config/config.php' \
            "$SOURCE_LOCATION/" \
            /var/www/html/

        rsync -rlD \
            --include '/version.php' \
            --exclude '/*' \
            "$SOURCE_LOCATION/" \
            /var/www/html/

        echo "Initializing finished"

        ################
        # Fresh Install
        ################
        
        if [ "$installed_version" = "0.0.0.0" ]; then
            echo "New Nextcloud instance."

            # Write output to logfile.
            mkdir -p /var/www/html/data
            exec > >(tee -i "/var/www/html/data/install.log")
            exec 2>&1

            INSTALL_OPTIONS=(-n --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASSWORD")
            if [ -n "${NEXTCLOUD_DATA_DIR}" ]; then
                INSTALL_OPTIONS+=(--data-dir "$NEXTCLOUD_DATA_DIR")
            fi

        # Skip the default permission check (we do our own)
        cat > /var/www/html/config/datadir.permission.config.php <<'EOF'
<?php
    $CONFIG = array (
        'check_data_directory_permissions' => false
    );
EOF

            echo "Installing with $DATABASE_TYPE database"
            # Set a default value for POSTGRES_PORT
            if [ -z "$POSTGRES_PORT" ]; then
                POSTGRES_PORT=5432
            fi

            # Add database options to INSTALL_OPTIONS
            # shellcheck disable=SC2153
            INSTALL_OPTIONS+=(
                --database "$DATABASE_TYPE"
                --database-name "$POSTGRES_DB"
                --database-user "$POSTGRES_USER"
                --database-pass "$POSTGRES_PASSWORD"
                --database-host "$POSTGRES_HOST"
                --database-port "$POSTGRES_PORT"
            )
            
            echo "Starting Nextcloud installation..."
            if ! php /var/www/html/occ maintenance:install "${INSTALL_OPTIONS[@]}"; then
                echo "Installation of Nextcloud failed!"
                touch "$NEXTCLOUD_DATA_DIR/install.failed"
                exit 1
            fi

            # APS (R28): the suite announces nothing through nextcloud_announcements; disabled before its
            # first cron run fetches pushfeed.nextcloud.com
            php /var/www/html/occ app:disable nextcloud_announcements

            # APS (R31): a fresh install has no legacy circles tables; marking circles' 22 migration done
            # skips the probe of oc_circle_circles that the repair below would log as an error
            php /var/www/html/occ config:app:set circles migration_22 --value=1

            # Try to force generation of appdata dir:
            php /var/www/html/occ maintenance:repair

            if [ -z "$OBJECTSTORE_S3_BUCKET" ] && [ -z "$OBJECTSTORE_SWIFT_URL" ]; then
                max_retries=10
                try=0
                while [ -z "$(find "$NEXTCLOUD_DATA_DIR/" -maxdepth 1 -mindepth 1 -type d -name "appdata_*")" ] && [ "$try" -lt "$max_retries" ]; do
                    echo "Waiting for appdata to become available..."
                    try=$((try+1))
                    sleep 10s
                done

                if [ "$try" -ge "$max_retries" ]; then
                    echo "Installation of Nextcloud failed!"
                    echo "Installation errors: $(cat /var/www/html/data/nextcloud.log)"
                    touch "$NEXTCLOUD_DATA_DIR/install.failed"
                    exit 1
                fi
            fi

            # This autoconfig is not needed anymore and should be able to be overwritten by the user
            rm /var/www/html/config/datadir.permission.config.php

            # unset admin password
            unset ADMIN_PASSWORD

            # Enable the updatenotification app but disable its UI and server update notifications
            php /var/www/html/occ config:system:set updatechecker --type=bool --value=false
            php /var/www/html/occ config:app:set updatenotification notify_groups --value="[]"


            # Apply log settings
            echo "Applying default settings..."
            mkdir -p /var/www/html/data
            php /var/www/html/occ config:system:set loglevel --value="$NEXTCLOUD_LOG_LEVEL" --type=integer
            if [ "$NEXTCLOUD_LOG_TYPE" = "errorlog" ]; then
                php /var/www/html/occ config:system:set log_type --value="errorlog"
                php /var/www/html/occ config:system:set log_type_audit --value="errorlog"
                php /var/www/html/occ app:disable logreader
            else
                php /var/www/html/occ config:system:set log_type --value="file"
                php /var/www/html/occ config:system:set log_type_audit --value="file"
                php /var/www/html/occ app:enable logreader
                php /var/www/html/occ config:system:set logfile --value="/var/www/html/data/nextcloud.log"
                php /var/www/html/occ config:system:set logfile_audit --value="/var/www/html/data/audit.log"
            fi
            php /var/www/html/occ config:system:set log_rotate_size --value="10485760" --type=integer
            php /var/www/html/occ app:enable admin_audit
            php /var/www/html/occ config:system:set log.condition apps 0 --value="admin_audit"

            # Apply preview settings
            echo "Applying preview settings..."
            php /var/www/html/occ config:system:set preview_max_x --value="2048" --type=integer
            php /var/www/html/occ config:system:set preview_max_y --value="2048" --type=integer
            php /var/www/html/occ config:system:set jpeg_quality --value="60" --type=integer
            php /var/www/html/occ config:app:set preview jpeg_quality --value="60"
            php /var/www/html/occ config:system:delete enabledPreviewProviders
            php /var/www/html/occ config:system:set enabledPreviewProviders 1 --value="OC\\Preview\\Image"
            php /var/www/html/occ config:system:set enabledPreviewProviders 2 --value="OC\\Preview\\MarkDown"
            php /var/www/html/occ config:system:set enabledPreviewProviders 3 --value="OC\\Preview\\MP3"
            php /var/www/html/occ config:system:set enabledPreviewProviders 4 --value="OC\\Preview\\TXT"
            php /var/www/html/occ config:system:set enabledPreviewProviders 5 --value="OC\\Preview\\OpenDocument"
            php /var/www/html/occ config:system:set enabledPreviewProviders 6 --value="OC\\Preview\\Movie"
            php /var/www/html/occ config:system:set enabledPreviewProviders 7 --value="OC\\Preview\\Krita"
            php /var/www/html/occ config:system:set enable_previews --value=true --type=boolean

            # Apply other settings
            echo "Applying other settings..."
            # Add missing indices after new installation because they seem to be missing on new installation
            php /var/www/html/occ db:add-missing-indices
            php /var/www/html/occ config:system:set upgrade.disable-web --type=bool --value=true
            php /var/www/html/occ config:system:set mail_smtpmode --value="smtp"
            php /var/www/html/occ config:system:set trashbin_retention_obligation --value="auto, 30"
            php /var/www/html/occ config:system:set versions_retention_obligation --value="auto, 30"
            php /var/www/html/occ config:system:set activity_expire_days --value="30" --type=integer
            php /var/www/html/occ config:system:set simpleSignUpLink.shown --type=bool --value=false
            if [ -z "$NEXTCLOUD_SHARE_FOLDER" ]; then
                php /var/www/html/occ config:system:set share_folder --value="/Shared"
            else
                php /var/www/html/occ config:system:set share_folder --value="$NEXTCLOUD_SHARE_FOLDER"
            fi

            # Install some apps by default
            if [ -n "$STARTUP_APPS" ]; then
                read -ra STARTUP_APPS_ARRAY <<< "$STARTUP_APPS"
                for app in "${STARTUP_APPS_ARRAY[@]}"; do
                    if ! echo "$app" | grep -q '^-'; then 
                        rc=0; ensure_startup_app "$app" || rc=$?
                        [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || exit "$rc"
                    else
                        app="${app#-}"
                        # Disable the app if '-' was provided in front of the appid
                        php /var/www/html/occ app:disable "$app"
                    fi
                done
            fi

        #upgrade
        else
            touch "$NEXTCLOUD_DATA_DIR/update.failed"
            echo "Upgrading Nextcloud from $installed_version to $image_version..."
            php /var/www/html/occ config:system:delete integrity.check.disabled
            if ! php /var/www/html/occ upgrade || ! php /var/www/html/occ -V; then
                echo "Upgrade failed. Please restore from backup."
                bash /notify.sh "Nextcloud update to $image_version failed!" "Please restore from backup."
                exit 1
            fi

            # shellcheck disable=SC2016
            installed_version="$(php -r 'require "/var/www/html/version.php"; echo implode(".", $OC_Version);')"

            rm "$NEXTCLOUD_DATA_DIR/update.failed"
            bash /notify.sh "Nextcloud update to $image_version successful!" "You may inspect the Nextcloud container logs for more information."

            php /var/www/html/occ app:update --all

            run_upgrade_if_needed_due_to_app_update

            # Restore app status
            if [ "${APPSTORAGE[0]}" != "no-export-done" ]; then
                echo "Restoring app statuses. This may take a while..."
                for app in "${!APPSTORAGE[@]}"; do
                    if [ -n "${APPSTORAGE[$app]}" ]; then
                        if [ "${APPSTORAGE[$app]}" != "no" ]; then
                            echo "Enabling $app..."
                            if ! php /var/www/html/occ app:enable "$app" >/dev/null; then
                                php /var/www/html/occ app:disable "$app" >/dev/null
                                if ! php /var/www/html/occ -V &>/dev/null; then
                                    rm -r "/var/www/html/custom_apps/$app"
                                    php /var/www/html/occ maintenance:mode --off
                                fi
                                run_upgrade_if_needed_due_to_app_update
                                echo "The $app app could not be re-enabled, probably because it is not compatible with the new Nextcloud version."
                                if [ "$app" = apporder ]; then
                                    CUSTOM_HINT="The apporder app was deprecated. A possible replacement is the side_menu app, aka 'Custom menu'."
                                else
                                    CUSTOM_HINT="Most likely, it is not compatible with the new Nextcloud version."
                                fi
                                bash /notify.sh "Could not re-enable the $app app after the Nextcloud update!" "$CUSTOM_HINT Feel free to review the Nextcloud update logs and force-enable the app again if you wish."
                                continue
                            fi
                            # Only restore the group settings, if the app was enabled (and is thus compatible with the new NC version)
                            if [ "${APPSTORAGE[$app]}" != "yes" ]; then
                                php /var/www/html/occ config:app:set "$app" enabled --value="${APPSTORAGE[$app]}"
                            fi
                        fi
                    fi
                done
            fi

            php /var/www/html/occ app:update --all

            run_upgrade_if_needed_due_to_app_update

            # APS (#155): updatenotification's UI and update notifications off; phase 16 owns its state
            php /var/www/html/occ config:system:set updatechecker --type=bool --value=false
            php /var/www/html/occ config:app:set updatenotification notify_groups --value="[]"

            # Apply optimization
            echo "Performing some optimizations..."
            if [ "$NEXTCLOUD_SKIP_DATABASE_OPTIMIZATION" != yes ]; then
                php /var/www/html/occ maintenance:repair --include-expensive
                php /var/www/html/occ db:add-missing-indices
                php /var/www/html/occ db:add-missing-columns
                php /var/www/html/occ db:add-missing-primary-keys
                yes | php /var/www/html/occ db:convert-filecache-bigint
            else
                php /var/www/html/occ maintenance:repair
            fi
        fi
    fi

    # APS (#42): AIO's automatic app updates are off, config or not. Upstream ran
    # app:update --all on Saturdays when its config asked for it; that leg is deleted, not
    # gated — apps move only when the operator decides (`aps-conecta actualizar`), and the
    # store stays closed on every update path besides.
fi

run_upgrade_if_needed_due_to_app_update

if [ -z "$OBJECTSTORE_S3_BUCKET" ] && [ -z "$OBJECTSTORE_SWIFT_URL" ]; then
    # Check if appdata is present
    # If not, something broke (e.g. changing ncdatadir after aio was first started)
    if [ -z "$(find "$NEXTCLOUD_DATA_DIR/" -maxdepth 1 -mindepth 1 -type d -name "appdata_*")" ]; then
        echo "Appdata is not present. Did you change the datadir after the initial Nextcloud installation? This is not supported!"
        echo "See https://github.com/nextcloud/all-in-one#how-to-change-the-default-location-of-nextclouds-datadir"
        echo "If you moved the datadir to an external drive, make sure that the drive is still mounted."
        echo "The following was found in the datadir:"
        ls -la "$NEXTCLOUD_DATA_DIR/"
        exit 1
    fi

    # Delete formerly configured tempdirectory as the default is usually faster (if the datadir is on a HDD or network FS)
    if [ "$(php /var/www/html/occ config:system:get tempdirectory)" = "$NEXTCLOUD_DATA_DIR/tmp/" ]; then
        php /var/www/html/occ config:system:delete tempdirectory
        if [ -d "$NEXTCLOUD_DATA_DIR/tmp/" ]; then
            rm -r "$NEXTCLOUD_DATA_DIR/tmp/"
        fi
    fi

fi

# Perform fingerprint update if instance was restored
if [ -f "$NEXTCLOUD_DATA_DIR/fingerprint.update" ]; then
    php /var/www/html/occ maintenance:data-fingerprint
    rm "$NEXTCLOUD_DATA_DIR/fingerprint.update"
fi

# Perform preview scan if previews were excluded from restore
if [ -f "$NEXTCLOUD_DATA_DIR/trigger-preview.scan" ]; then
    php /var/www/html/occ files:scan-app-data preview -vvv
    rm "$NEXTCLOUD_DATA_DIR/trigger-preview.scan"
fi

# #176: an establishment has as many accounts as it has staff. A boot removes the account cap
# AIO's one-click setting puts on an instance: the volume's aio.config.php (synced above only on an
# install or an upgrade) takes the image's, and the keys a config write copied into config.php go.
cp "$SOURCE_LOCATION/config/aio.config.php" /var/www/html/config/aio.config.php
php /var/www/html/occ config:system:delete one-click-instance
php /var/www/html/occ config:system:delete one-click-instance.user-limit
php /var/www/html/occ config:system:delete one-click-instance.link
if [ -n "$SUBSCRIPTION_KEY" ] && [ -z "$(php /var/www/html/occ config:app:get support potential_subscription_key)" ]; then
    php /var/www/html/occ config:app:set support potential_subscription_key --value="$SUBSCRIPTION_KEY"
    php /var/www/html/occ config:app:delete support last_check
fi
if [ -n "$NEXTCLOUD_DEFAULT_QUOTA" ]; then
    if [ "$NEXTCLOUD_DEFAULT_QUOTA" = "unlimited" ]; then
        php /var/www/html/occ config:app:delete files default_quota
    else
        php /var/www/html/occ config:app:set files default_quota --value="$NEXTCLOUD_DEFAULT_QUOTA"
    fi
fi

# Adjusting log files to be stored on a volume
echo "Adjusting log files..."
php /var/www/html/occ config:system:set upgrade.cli-upgrade-link --value="https://github.com/nextcloud/all-in-one/discussions/2726"
php /var/www/html/occ config:system:set loglevel --value="$NEXTCLOUD_LOG_LEVEL" --type=integer
if [ "$NEXTCLOUD_LOG_TYPE" = "errorlog" ]; then
    php /var/www/html/occ config:system:set log_type --value="errorlog"
    php /var/www/html/occ config:system:set log_type_audit --value="errorlog"
    php /var/www/html/occ app:disable logreader
else
    php /var/www/html/occ config:system:set log_type --value="file"
    php /var/www/html/occ config:system:set log_type_audit --value="file"
    php /var/www/html/occ app:enable logreader
    php /var/www/html/occ config:system:set logfile --value="/var/www/html/data/nextcloud.log"
    php /var/www/html/occ config:system:set logfile_audit --value="/var/www/html/data/audit.log"
fi
php /var/www/html/occ config:system:set updatedirectory --value="/nc-updater"
if [ -n "$NEXTCLOUD_SKELETON_DIRECTORY" ]; then
    if [ "$NEXTCLOUD_SKELETON_DIRECTORY" = "empty" ]; then
        php /var/www/html/occ config:system:set skeletondirectory --value=""
    else
        php /var/www/html/occ config:system:set skeletondirectory --value="$NEXTCLOUD_SKELETON_DIRECTORY"
    fi
fi
if [ -n "$SERVERINFO_TOKEN" ] && [ -z "$(php /var/www/html/occ config:app:get serverinfo token)" ]; then
    php /var/www/html/occ config:app:set serverinfo token --value="$SERVERINFO_TOKEN"
fi
# Set maintenance window so that no warning is shown in the admin overview
if [ -z "$NEXTCLOUD_MAINTENANCE_WINDOW" ]; then
    NEXTCLOUD_MAINTENANCE_WINDOW=100
fi
php /var/www/html/occ config:system:set maintenance_window_start --type=int --value="$NEXTCLOUD_MAINTENANCE_WINDOW"

# Refresh image-owned assets while retaining the establishment's generated CSS.
mkdir -p /var/www/html/themes/apsconecta || exit 1
rsync -rlD --delete --exclude='/core/css/site.css' \
    "$SOURCE_LOCATION/themes/apsconecta/" /var/www/html/themes/apsconecta/ || exit 1

# Apply network settings
echo "Applying network settings..."
php /var/www/html/occ config:system:set allow_local_remote_servers --type=bool --value=true
php /var/www/html/occ config:system:set davstorage.request_timeout --value="$PHP_MAX_TIME" --type=int
php /var/www/html/occ config:system:set trusted_domains 1 --value="$NC_DOMAIN"
php /var/www/html/occ config:system:set overwrite.cli.url --value="https://$NC_DOMAIN/"
php /var/www/html/occ config:system:set documentation_url.server_logs --value="https://github.com/nextcloud/all-in-one/discussions/5425"
php /var/www/html/occ config:system:set htaccess.RewriteBase --value="/"
php /var/www/html/occ maintenance:update:htaccess

# Handle db persistent settings
if [ "$NEXTCLOUD_PERSIST_DATABASE_CONNECTIONS" = "yes" ]; then
    php /var/www/html/occ config:system:set dbpersistent --value=true --type=bool
else
    php /var/www/html/occ config:system:set dbpersistent --value=false --type=bool
fi

if [ "$DISABLE_BRUTEFORCE_PROTECTION" = yes ]; then
    php /var/www/html/occ config:system:set auth.bruteforce.protection.enabled --type=bool --value=false
    php /var/www/html/occ config:system:set ratelimit.protection.enabled --type=bool --value=false
else
    php /var/www/html/occ config:system:set auth.bruteforce.protection.enabled --type=bool --value=true
    php /var/www/html/occ config:system:set ratelimit.protection.enabled --type=bool --value=true
fi

# Disallow creating local external storages when nothing was mounted
if [ -z "$NEXTCLOUD_MOUNT" ]; then
    php /var/www/html/occ config:system:set files_external_allow_create_new_local --type=bool --value=false
else
    php /var/www/html/occ config:system:set files_external_allow_create_new_local --type=bool --value=true
fi

# AIO app start # Do not remove or change this line!
# AIO app
# (removed with the upstream app directory, #48 — the wizard is reached at its own address,
#  and no Nextcloud surface redirects into it any more)
# AIO app end # Do not remove or change this line!

php /var/www/html/occ config:system:set trusted_proxies 0 --value="127.0.0.1"
php /var/www/html/occ config:system:set trusted_proxies 1 --value="::1"
if [ -n "$ADDITIONAL_TRUSTED_PROXY" ]; then
    php /var/www/html/occ config:system:set trusted_proxies 2 --value="$ADDITIONAL_TRUSTED_PROXY"
fi

if [ -z "$NEXTCLOUD_HOST" ]; then
    export NEXTCLOUD_HOST="aps-conecta-nextcloud"
fi
SUITE_NETWORK="$(bash /network-prefix.sh --host "$NEXTCLOUD_HOST")" || exit 1
php /var/www/html/occ config:system:set trusted_proxies 10 --value="$SUITE_NETWORK" || exit 1

if [ -n "$ADDITIONAL_TRUSTED_DOMAIN" ]; then
    php /var/www/html/occ config:system:set trusted_domains 2 --value="$ADDITIONAL_TRUSTED_DOMAIN"
fi

# Managed apps share the same presence, enable and bounded configuration policy.
configure_startup_apps || exit 1

# Imaginary
if [ "$IMAGINARY_ENABLED" = 'yes' ]; then
    php /var/www/html/occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary"
    php /var/www/html/occ config:system:set enabledPreviewProviders 23 --value="OC\\Preview\\ImaginaryPDF"
    php /var/www/html/occ config:system:set preview_imaginary_url --value="http://$IMAGINARY_HOST:9000"
    php /var/www/html/occ config:system:set preview_imaginary_key --value="$IMAGINARY_SECRET"
else
    if [ -n "$(php /var/www/html/occ config:system:get preview_imaginary_url)" ]; then
        php /var/www/html/occ config:system:delete enabledPreviewProviders 0
        php /var/www/html/occ config:system:delete preview_imaginary_url
        php /var/www/html/occ config:system:delete enabledPreviewProviders 20
        php /var/www/html/occ config:system:delete enabledPreviewProviders 21
        php /var/www/html/occ config:system:delete enabledPreviewProviders 22
        php /var/www/html/occ config:system:delete enabledPreviewProviders 23
    fi
fi

# Remove the update skip file always
rm -f "$NEXTCLOUD_DATA_DIR"/skip.update
