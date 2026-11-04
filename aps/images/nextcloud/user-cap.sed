# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# AIO's one-click-instance user cap (#176) out of upstream's Nextcloud image, applied to the image's aio.config.php,
# /entrypoint.sh and /run-exec-commands.sh; each part matches lines of one of them only.
#
# aio.config.php sets no cap.
/^  'one-click-instance/d
# The block between upstream's one-click markers in /entrypoint.sh sets no cap; every start removes the cap an
# instance still carries instead: its aio.config.php takes the image's, and the keys go from its config.php.
/^# AIO one-click settings start/,/^# AIO one-click settings end/{
/^# AIO one-click settings end/!d
}
/^# AIO one-click settings end/c\
cp "$SOURCE_LOCATION/config/aio.config.php" /var/www/html/config/aio.config.php\
php /var/www/html/occ config:system:delete one-click-instance\
php /var/www/html/occ config:system:delete one-click-instance.user-limit\
php /var/www/html/occ config:system:delete one-click-instance.link
# /run-exec-commands.sh runs exec commands that name the setting like any others.
/^    if ! grep "one-click-instance" \/tmp\/nextcloud-exec-commands; then$/,/^    fi$/{
/^    if ! grep/d
/^    fi$/d
}
