#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

if [ "$#" != 1 ] || [[ ! "$1" =~ ^([0-9]+)([KkMmGg]?)$ ]]; then
    echo 'El límite antivirus es inválido. Revise NEXTCLOUD_UPLOAD_LIMIT.' >&2
    exit 1
fi
amount="${BASH_REMATCH[1]}"
unit="${BASH_REMATCH[2]}"
while [ "${#amount}" -gt 1 ] && [ "${amount:0:1}" = 0 ]; do
    amount="${amount:1}"
done
if [ "$amount" = 0 ]; then
    echo 'El límite antivirus debe ser mayor que cero.' >&2
    exit 1
fi
case "$unit" in
    K|k) multiplier=1024 ;;
    M|m) multiplier=1048576 ;;
    G|g) multiplier=1073741824 ;;
    *) multiplier=1 ;;
esac
# ClamAV caps MaxFileSize at INT_MAX - 2 on the supported platform.
maximum=2147483645
if [ "${#amount}" -gt 10 ] || (( 10#$amount > maximum / multiplier )); then
    printf '%s\n' "$maximum"
else
    printf '%s\n' "$((10#$amount * multiplier))"
fi
