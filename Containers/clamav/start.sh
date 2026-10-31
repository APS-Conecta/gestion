#!/bin/bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

if [ "${AIO_LOG_LEVEL:-warn}" = 'debug' ]; then
	set -x
fi

limit="$(bash "$(dirname "${BASH_SOURCE[0]}")/../antivirus-limit.sh" "${MAX_SIZE:-}")"
awk '$1 !~ /^(MaxScanSize|MaxFileSize|PCREMaxFileSize|StreamMaxLength|ScanArchive|AlertExceedsMax|AlertEncrypted)$/ { print }' \
    /etc/clamav/clamd.conf > /tmp/clamd.conf
for setting in MaxScanSize MaxFileSize PCREMaxFileSize StreamMaxLength; do
    printf '%s %s\n' "$setting" "$limit" >> /tmp/clamd.conf
done
printf 'ScanArchive yes\nAlertExceedsMax yes\nAlertEncrypted yes\n' >> /tmp/clamd.conf

# Print out clamav version for compliance reasons
clamscan --version

echo "Clamav started"

exec "$@"
