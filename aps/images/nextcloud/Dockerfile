# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The thin Nextcloud image: upstream's Nextcloud image without AIO's one-click-instance user cap (#176), so an
# establishment has as many accounts as it has staff. user-cap.sed takes the cap out of the image's aio.config.php
# and /entrypoint.sh, removes it at every start from an instance that still carries it, and runs exec commands that
# name it; the build fails if any of upstream's cap is left. Its start keeps the support app off, which the theme step
# (aps/provisionador/steps/theme.py) turns off, and rebuilds the browser's texts of the apps the theme overrides texts
# of (browser-texts.php) once upstream's start installed and updated the apps. aps/release/pins.sh re-pins the base.
FROM ghcr.io/nextcloud-releases/aio-nextcloud:20261029_150718@sha256:4e955a9bd3e34d66dd2cd7a30ad0c21559848fa3b9d6304b065c5a1253dbd2ac

COPY user-cap.sed /tmp/
RUN set -eux; \
    for file in /usr/src/nextcloud/config/aio.config.php /entrypoint.sh /run-exec-commands.sh; do \
        sed -i -f /tmp/user-cap.sed "$file"; \
    done; \
    if grep -n one-click-instance /usr/src/nextcloud/config/aio.config.php \
        || grep -n -e 'config:system:set one-click-instance' -e 'grep "one-click-instance"' /entrypoint.sh /run-exec-commands.sh; \
    then exit 1; fi; \
    grep -q '^php /var/www/html/occ config:system:delete one-click-instance.user-limit$' /entrypoint.sh; \
    rm /tmp/user-cap.sed

# The build fails if the start still turns the support app on, or if the texts' rebuild does not follow its last app
# install or update.
COPY browser-texts.php /
RUN set -eux; \
    sed -i -e '/^php \/var\/www\/html\/occ app:enable support$/d' \
        -e 's|^# Remove the update skip file always$|php /browser-texts.php\n&|' /entrypoint.sh; \
    if grep -n 'app:enable support' /entrypoint.sh; then exit 1; fi; \
    last="$(grep -e 'occ app:update' -e 'occ app:install' -e '^php /browser-texts.php$' /entrypoint.sh | tail -n 1)"; \
    [ "$last" = 'php /browser-texts.php' ]
