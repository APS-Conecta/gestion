#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copies stdin to stdout without the link's secret: the QR code, which encodes the link, is left out by the full block
# qrencode -t ANSIUTF8 puts on each of its lines, and the secret after the link's # reads [secret].
set -euo pipefail
{ grep -v -F '█' || true; } | sed -E 's/(https:[^[:space:]]*#)[A-Za-z0-9_-]+/\1[secret]/g'
