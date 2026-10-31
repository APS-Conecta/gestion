#!/bin/bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

if [ -d "/usr/local/share/ca-certificates" ]; then
    cp "/etc/ssl/certs/ca-certificates.crt" "/tmp/ca-certificates.crt"
    for certificate in "/usr/local/share/ca-certificates"/*; do
        [ -f "$certificate" ] || continue
        cat "$certificate" >> "/tmp/ca-certificates.crt"
    done
    export SSL_CERT_FILE="/tmp/ca-certificates.crt"
fi

exec "/usr/local/bin/start.sh" "$@"
