#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail
deadline=$((SECONDS + 90))
until [ "$(printf 'PING\n' | timeout 2 nc 127.0.0.1 3310)" = PONG ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo 'ClamAV did not become ready for the ICAP frontend.' >&2
        exit 1
    fi
    sleep 2
done
exec c-icap -N -f /etc/c-icap/c-icap.conf
