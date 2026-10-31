#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

network_prefix() {
    local address prefix octet value=0 mask
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    address="${1%/*}"
    prefix="${1#*/}"
    local -a octets
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ "$octet" = 0 || "$octet" != 0* ]] && (( 10#$octet <= 255 )) || return 1
        value=$(( (value << 8) | 10#$octet ))
    done
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    value=$(( value & mask ))
    printf '%d.%d.%d.%d/%d\n' "$((value >> 24))" "$(((value >> 16) & 255))" \
        "$(((value >> 8) & 255))" "$((value & 255))" "$prefix"
}

if [ "$#" = 1 ]; then
    network_prefix "$1" && exit 0
elif [ "$#" = 2 ] && [ "$1" = --host ]; then
    addresses="$(dig "$2" A +short +search +time=2 +tries=1)" || exit 1
    interfaces="$(ip -o -4 addr show scope global)" || exit 1
    cidrs="$(awk 'NR == FNR { addresses[$1] = 1; next }
        $3 == "inet" { split($4, parts, "/"); if (parts[1] in addresses) print $4 }' \
        <(printf '%s\n' "$addresses") <(printf '%s\n' "$interfaces"))"
    if [ -n "$cidrs" ] && [[ "$cidrs" != *$'\n'* ]]; then
        network_prefix "$cidrs" && exit 0
    fi
fi
echo 'Cannot determine one IPv4 suite network prefix; refusing forwarded-header trust.' >&2
exit 1
