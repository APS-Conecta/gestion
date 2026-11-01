#!/bin/bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Shared boot/provisioning configuration. Missing signed apps defer to phase 12;
# only notify_push may use the store (ADR-0018, ADR-0020). No app updates here.

startup_occ() { php /var/www/html/occ "$@"; }

# Return 2 for an expected missing app, 1 for a failed command, 0 when enabled.
# app:list includes both shipped and custom apps, including group-enabled apps.
ensure_startup_app() {
    local app="$1" snapshot state
    snapshot="$(startup_occ app:list --output=json 2>/dev/null)" || {
        echo "app-startup: failed to list installed apps" >&2; return 1;
    }
    state="$(printf '%s' "$snapshot" | php -r '
        try {
            $apps = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
            if (!is_array($apps["enabled"] ?? null) || !is_array($apps["disabled"] ?? null)) {
                exit(1);
            }
            echo array_key_exists($argv[1], $apps["enabled"]) ? "enabled" :
                (array_key_exists($argv[1], $apps["disabled"]) ? "disabled" : "missing");
        } catch (Throwable $e) { exit(1); }
    ' "$app")" || { echo "app-startup: cannot read installed apps" >&2; return 1; }
    case "$state" in
        enabled) return 0 ;;
        disabled)
            if ! startup_occ app:enable "$app" >/dev/null 2>&1; then
                echo "app-startup: failed to enable $app" >&2; return 1
            fi
            echo "app-startup: $app -> enabled" ;;
        missing)
            if [ "$app" = notify_push ]; then
                NC_appstoreenabled=1 php /var/www/html/occ app:install notify_push >/dev/null 2>&1 || {
                    echo "app-startup: failed to install notify_push" >&2; return 1;
                }
                echo "app-startup: notify_push -> installed"
            else
                echo "app-startup: $app is absent; configuration deferred until it is installed"
                return 2
            fi ;;
        *) return 1 ;;
    esac
}

# Nextcloud's typed setters already skip unchanged values. Preserve the seed's
# write accounting without printing values (JWTs and backend passwords included).
startup_app_set() {
    local app="$1" key="$2" output
    shift 2
    output="$(startup_occ config:app:set "$app" "$key" "$@" 2>&1)" || {
        echo "app-startup: failed to configure $app:$key" >&2; return 1;
    }
    case "$output" in
        *"Config value were not updated"*) ;;
        *"is now set to"*) echo "app-startup: app:$app:$key -> updated" ;;
        *) echo "app-startup: unrecognized configuration result for $app:$key" >&2; return 1 ;;
    esac
}

startup_system_set() {
    local before after key="$1"
    before="$(sha256sum /var/www/html/config/config.php)" || return 1
    if ! startup_occ config:system:set "$@" >/dev/null 2>&1; then
        echo "app-startup: failed to configure system:$key" >&2; return 1
    fi
    after="$(sha256sum /var/www/html/config/config.php)" || return 1
    [ "$before" = "$after" ] || echo "app-startup: system:$key -> updated"
}

# Import a string from a named environment variable, preserving sibling keys.
startup_secret_set() (
    set +x
    local scope="$1" variable="$2" key="$3" label settings snapshot
    shift 2
    label="$scope:$key"
    [ "$scope" != apps ] || label="app:$key:${2:-}"
    snapshot="$(startup_occ config:list --private --output=json 2>/dev/null)" || {
        echo "app-startup: failed to read configuration for $label" >&2; return 1;
    }
    settings="$(printf '%s' "$snapshot" | php -r '
        try {
            $current = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
            $scope = $argv[1];
            $value = getenv($argv[2]);
            $path = array_slice($argv, 3);
            if (!in_array($scope, ["apps", "system"], true) || $value === false || $value === ""
                || !is_array($current[$scope] ?? null) || count($path) > 2
                || ($scope === "apps" && count($path) !== 2)) { exit(1); }
            $key = $path[0];
            $before = $current[$scope][$key] ?? null;
            if (count($path) === 2) {
                $desired = $before ?? [];
                if (!is_array($desired)) { exit(1); }
                if ($scope === "apps") {
                    if (($desired[$path[1]] ?? null) === $value) { exit(0); }
                    $desired = [];
                }
                $desired[$path[1]] = $value;
            } else { $desired = $value; }
            if ($before !== $desired) {
                echo json_encode([$scope => [$key => $desired]], JSON_THROW_ON_ERROR);
            }
        } catch (Throwable $e) { exit(1); }
    ' "$scope" "$variable" "$@")" || {
        echo "app-startup: cannot prepare configuration for $label" >&2; return 1;
    }
    [ -n "$settings" ] || return 0
    printf '%s' "$settings" | startup_occ config:import >/dev/null 2>&1 || {
        echo "app-startup: failed to configure $label" >&2; return 1;
    }
    echo "app-startup: $label -> updated"
)

startup_wait() {
    local host="$1" port="$2" name="$3" deadline=$((SECONDS + 90)) remaining
    while ! nc -z -w 1 "$host" "$port"; do
        remaining=$((deadline - SECONDS))
        if [ "$remaining" -le 0 ]; then
            echo "app-startup: $name unavailable; configuration deferred, apps remain enabled; retry on next start"
            return 2
        fi
        echo "Waiting for $name to become available..."
        [ "$remaining" -le 5 ] || remaining=5
        sleep "$remaining"
    done
}

startup_office() {
    if [ "$EUROOFFICE_ENABLED" = 'yes' ]; then
        # Nextcloud 34 ships a first-party `office` overview app enabled by default. It is not this
        # suite's editor (that is `eurooffice`, which has no nav entry and engages when a document is
        # opened from Files) and is not wired to it — no editor-url state is ever injected, so the
        # "Office" tile is an overview that bounces to /f/{fileid}. One office surface per install:
        # disabled whenever the suite's office app is EuroOffice.
        php /var/www/html/occ app:disable office || return 1
        local EUROOFFICE_PORT public_host="$EUROOFFICE_HOST"
        # Determine EuroOffice port based on host pattern
        if echo "$EUROOFFICE_HOST" | grep -q "aps-conecta-eurooffice"; then
            EUROOFFICE_PORT=80
        else
            EUROOFFICE_PORT=443
        fi

        local rc=0
        ensure_startup_app eurooffice || rc=$?
        [ "$rc" -ne 2 ] || return 0
        [ "$rc" -eq 0 ] || return "$rc"
        rc=0; startup_wait "$EUROOFFICE_HOST" "$EUROOFFICE_PORT" EuroOffice || rc=$?
        [ "$rc" -ne 2 ] || return 0
        [ "$rc" -eq 0 ] || return "$rc"
        # Set EuroOffice configuration
        startup_system_set eurooffice editors_check_interval --value="0" --type=integer || return 1
        startup_secret_set system EUROOFFICE_SECRET eurooffice jwt_secret || return 1
        startup_secret_set apps EUROOFFICE_SECRET eurooffice jwt_secret || return 1
        startup_system_set eurooffice jwt_header --value="AuthorizationJwt" || return 1

        # Adjust the EuroOffice host if using internal pattern
        if echo "$EUROOFFICE_HOST" | grep -q "aps-conecta-eurooffice"; then
            public_host="$NC_DOMAIN/eurooffice"
        fi

        startup_app_set eurooffice DocumentServerUrl --value="https://$public_host" || return 1

        # Register EuroOffice preview provider in the explicit allowlist.
        # Use a high fixed index (24) to avoid colliding with AIO's seeded indices (1-7, 23).
        local previews
        previews="$(startup_occ config:system:get enabledPreviewProviders)" || return 1
        if ! grep -q "Eurooffice" <<< "$previews"; then
            startup_system_set enabledPreviewProviders 24 --value="OCA\Eurooffice\Preview" || return 1
        fi
    else
        # Remove EuroOffice app if disabled and removal is requested
        if [ "$REMOVE_DISABLED_APPS" = yes ] && \
           [ -d "/var/www/html/custom_apps/eurooffice" ] && \
           [ -n "$EUROOFFICE_SECRET" ] && \
           [ "$(php /var/www/html/occ config:system:get eurooffice jwt_secret)" = "$EUROOFFICE_SECRET" ]; then
            php /var/www/html/occ app:remove eurooffice || return 1
        fi
    fi
}

startup_talk() {
    local TALK_HOST="${TALK_HOST:-}" TURN_DOMAIN="${TURN_DOMAIN:-}" HPB_PATH="${HPB_PATH:-}" snapshot settings
    if [ "$TALK_ENABLED" = 'yes' ]; then
        if [ -z "$TALK_HOST" ] || echo "$TALK_HOST" | grep -q "aps-conecta-talk"; then
            TALK_HOST="$NC_DOMAIN"
            HPB_PATH="/standalone-signaling/"
        fi
        if [ -z "$TURN_DOMAIN" ]; then
            TURN_DOMAIN="$TALK_HOST"
        fi
        local rc=0
        ensure_startup_app spreed || rc=$?
        [ "$rc" -ne 2 ] || return 0
        [ "$rc" -eq 0 ] || return "$rc"
        snapshot="$(startup_occ config:list spreed --private --output=json 2>/dev/null)" || {
            echo "app-startup: failed to read Talk configuration" >&2; return 1;
        }
        # Native import merges only changed keys. Secrets stay in stdin and the
        # container environment, including when a secret changes on a warm server.
        settings="$(printf '%s' "$snapshot" | php -r '
            try {
                $current = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
                $current = $current["apps"]["spreed"] ?? null;
                if (!is_array($current)) { exit(1); }
                $turn = getenv("TURN_SECRET");
                $signaling = getenv("SIGNALING_SECRET");
                if (!$turn || !$signaling) { exit(1); }
                $desired = [
                    "certificate_expiration_days" => "2",
                    "stun_servers" => json_encode([$argv[2]], JSON_THROW_ON_ERROR),
                    "turn_servers" => json_encode([["schemes" => "turn", "server" => $argv[2],
                        "protocols" => "udp,tcp", "secret" => $turn]], JSON_THROW_ON_ERROR),
                    "signaling_servers" => json_encode(["servers" => [["server" => $argv[1],
                        "verify" => true]], "secret" => $signaling], JSON_THROW_ON_ERROR),
                ];
                $changed = array_filter($desired, static fn($value, $key) =>
                    ($current[$key] ?? null) !== $value, ARRAY_FILTER_USE_BOTH);
                if ($changed) { echo json_encode(["apps" => ["spreed" => $changed]], JSON_THROW_ON_ERROR); }
            } catch (Throwable $e) { exit(1); }
        ' "https://$TALK_HOST$HPB_PATH" "$TURN_DOMAIN:$TALK_PORT")" || {
            echo "app-startup: cannot prepare Talk configuration" >&2; return 1;
        }
        if [ -n "$settings" ]; then
            printf '%s' "$settings" | startup_occ config:import >/dev/null 2>&1 || {
                echo "app-startup: failed to configure Talk" >&2; return 1;
            }
            echo "app-startup: app:spreed:wiring -> updated"
        fi

    else
        if [ "$REMOVE_DISABLED_APPS" = yes ] && [ -d "/var/www/html/custom_apps/spreed" ]; then
            php /var/www/html/occ app:remove spreed || return 1
        fi
    fi
}

startup_recording() {
    [ "${TALK_ENABLED:-}" = yes ] || return 0
    local rc=0
    ensure_startup_app spreed || rc=$?
    [ "$rc" -ne 2 ] || return 0
    [ "$rc" -eq 0 ] || return "$rc"
    if [ "${TALK_ENABLED:-}" = yes ]; then
        if [ "$TALK_RECORDING_ENABLED" = 'yes' ]; then
            rc=0; startup_wait "$TALK_RECORDING_HOST" 1234 "Talk Recording" || rc=$?
            [ "$rc" -ne 2 ] || return 0
            [ "$rc" -eq 0 ] || return "$rc"
            # TODO: migrate to occ command if that becomes available
            RECORDING_SERVERS_STRING="{\"servers\":[{\"server\":\"http://$TALK_RECORDING_HOST:1234/\",\"verify\":true}],\"secret\":\"$RECORDING_SECRET\"}"
            startup_app_set spreed recording_servers --value="$RECORDING_SERVERS_STRING" || return 1
        else
            if [ "$REMOVE_DISABLED_APPS" = yes ]; then
                php /var/www/html/occ config:app:delete spreed recording_servers || return 1
            fi
        fi
    fi
}

startup_clam() {
    if [ "$CLAMAV_ENABLED" = 'yes' ]; then
        local rc=0
        ensure_startup_app files_antivirus || rc=$?
        [ "$rc" -ne 2 ] || return 0
        [ "$rc" -eq 0 ] || return "$rc"
        local policy_dir
        policy_dir="$(dirname "${BASH_SOURCE[0]}")/.."
        bash "$policy_dir/antivirus-limit.sh" "${PHP_UPLOAD_LIMIT:-}" >/dev/null || return 1
        startup_app_set files_antivirus av_mode --value="icap" || return 1
        startup_app_set files_antivirus av_port --value="1344" || return 1
        startup_app_set files_antivirus av_host --value="$CLAMAV_HOST" || return 1
        startup_app_set files_antivirus av_icap_request_service --value="avscan" || return 1
        startup_app_set files_antivirus av_icap_mode --value="reqmod" || return 1
        startup_app_set files_antivirus av_icap_response_header --value="X-Infection-Found" || return 1
        startup_app_set files_antivirus av_icap_tls --value=false --type=boolean --no-interaction || return 1
        # This is a transport threshold, not a content cap: never split a file into separate scans.
        startup_app_set files_antivirus av_stream_max_length --value=9223372036854775807 --type=integer --no-interaction || return 1
        # This threshold skips large assembled uploads; the backend enforces the shared content budget.
        startup_app_set files_antivirus av_max_file_size --value=-1 --type=integer --no-interaction || return 1
        startup_app_set files_antivirus av_scan_first_bytes --value=-1 --type=integer --no-interaction || return 1
        startup_app_set files_antivirus av_block_unreachable --value=true --type=boolean --no-interaction || return 1
        startup_app_set files_antivirus av_block_unscannable --value=true --type=boolean --no-interaction || return 1
        startup_app_set files_antivirus av_blocklisted_directories --value='[]' --type=array --no-interaction || return 1
        rc=0; startup_wait "$CLAMAV_HOST" 1344 ClamAV || rc=$?
        [ "$rc" -ne 2 ] || return 0
        [ "$rc" -eq 0 ] || return "$rc"
    else
        if [ "$REMOVE_DISABLED_APPS" = yes ] && [ -d "/var/www/html/custom_apps/files_antivirus" ]; then
            php /var/www/html/occ app:remove files_antivirus || return 1
        fi
    fi
}

startup_fts() {
    if [ "$FULLTEXTSEARCH_ENABLED" = 'yes' ]; then
        local app rc missing=0
        for app in fulltextsearch fulltextsearch_elasticsearch files_fulltextsearch; do
            rc=0; ensure_startup_app "$app" || rc=$?
            case "$rc" in 0) ;; 2) missing=1 ;; *) return "$rc" ;; esac
        done
        [ "$missing" -eq 0 ] || return 0
        rc=0; startup_wait "$FULLTEXTSEARCH_HOST" "$FULLTEXTSEARCH_PORT" Fulltextsearch || rc=$?
        [ "$rc" -ne 2 ] || return 0
        [ "$rc" -eq 0 ] || return "$rc"
        local FULLTEXTSEARCH_PROTOCOL="${FULLTEXTSEARCH_PROTOCOL:-http}"
        php /var/www/html/occ fulltextsearch:configure '{"search_platform":"OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"}' >/dev/null 2>&1 || { echo "app-startup: fulltext configuration failed" >&2; return 1; }
        php /var/www/html/occ fulltextsearch_elasticsearch:configure "{\"elastic_host\":\"$FULLTEXTSEARCH_PROTOCOL://$FULLTEXTSEARCH_USER:$FULLTEXTSEARCH_PASSWORD@$FULLTEXTSEARCH_HOST:$FULLTEXTSEARCH_PORT\",\"elastic_index\":\"$FULLTEXTSEARCH_INDEX\"}" >/dev/null 2>&1 || { echo "app-startup: fulltext configuration failed" >&2; return 1; }
        php /var/www/html/occ files_fulltextsearch:configure "{\"files_pdf\":true,\"files_office\":true}" >/dev/null 2>&1 || { echo "app-startup: fulltext configuration failed" >&2; return 1; }

        # Do the index
        if ! [ -f "$NEXTCLOUD_DATA_DIR/fts-index.done" ]; then
            echo "Waiting 10 seconds before activating fulltextsearch..."
            sleep 10
            echo "Activating fulltextsearch..."
            if php /var/www/html/occ fulltextsearch:test && php /var/www/html/occ fulltextsearch:index "{\"errors\": \"reset\"}" --no-readline; then
                touch "$NEXTCLOUD_DATA_DIR/fts-index.done"
            else
                echo "Fulltextsearch failed. Could not index."
                echo "If you want to skip indexing in the future, see https://github.com/nextcloud/all-in-one/discussions/1709"
            fi
        fi
    else
        if [ "$REMOVE_DISABLED_APPS" = yes ]; then
            if [ -d "/var/www/html/custom_apps/fulltextsearch" ]; then
                php /var/www/html/occ app:remove fulltextsearch || return 1
            fi
            if [ -d "/var/www/html/custom_apps/fulltextsearch_elasticsearch" ]; then
                php /var/www/html/occ app:remove fulltextsearch_elasticsearch || return 1
            fi
            if [ -d "/var/www/html/custom_apps/files_fulltextsearch" ]; then
                php /var/www/html/occ app:remove files_fulltextsearch || return 1
            fi
        fi
    fi
}

startup_harp() {
    # app_api is a shipped app
    if [ -d "/var/www/html/custom_apps/app_api" ]; then
        php /var/www/html/occ app:disable app_api || return 1
        rm -r "/var/www/html/custom_apps/app_api" || return 1
    fi
    if [ "$HARP_ENABLED" = 'yes' ]; then
        local rc=0
        ensure_startup_app app_api || rc=$?
        [ "$rc" -ne 2 ] || return 0
        [ "$rc" -eq 0 ] || return "$rc"
    else
        if [ "$REMOVE_DISABLED_APPS" = yes ]; then
            if [ "$(php /var/www/html/occ config:app:get app_api enabled)" != "no" ]; then
                php /var/www/html/occ app:disable app_api || return 1
            fi
        fi
    fi
}

# Suppress caller debug tracing around credentials, restoring it after the pass.
configure_startup_apps() {
    local traced=0 rc=0 target="${1:-boot}"
    case "$-" in *x*) traced=1; set +x ;; esac
    case "$target" in
        eurooffice) startup_office || rc=$? ;;
        antivirus) startup_clam || rc=$? ;;
        fulltextsearch) startup_fts || rc=$? ;;
        talk) startup_talk || rc=$? ;;
        boot)
            startup_notify && startup_office && startup_talk && startup_recording &&
                startup_clam && startup_fts && startup_harp || rc=$? ;;
        *) echo "app-startup: unknown target: $target" >&2; rc=1 ;;
    esac
    [ "$traced" -eq 0 ] || set -x
    return "$rc"
}

startup_notify() {
    ensure_startup_app notify_push || return 1
    chmod 775 -R /var/www/html/custom_apps/notify_push/bin/ || return 1
    startup_app_set notify_push base_endpoint --value="https://$NC_DOMAIN/push"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    configure_startup_apps "$@"
fi
