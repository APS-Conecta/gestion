#!/usr/bin/env bash
# Office editing smoke — verifies the Euro-Office backend is wired end-to-end (Story 0.2, AD-5).
# Checks server health (host + server-side) via the eurooffice connector.
# Exits non-zero on ANY failure (so it fails loudly on a connector/host/round-trip error).
set -euo pipefail

# Read .env so this behaves the same run directly as through `make` (cf. scripts/smoke.sh).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

OCC="docker compose exec -T --user www-data nextcloud php occ"
OFFICE_PORT="${OFFICE_PORT:-80}"

# Require the eurooffice connector — the sole office backend (AD-5). An app is enabled iff its
# appconfig `enabled` value is "yes".
[ "$($OCC config:app:get eurooffice enabled 2>/dev/null || true)" = "yes" ] \
  || { echo "FAIL: eurooffice connector not enabled — run: make office-eurooffice"; exit 1; }

echo "Office backend: Euro-Office (eurooffice)"

# The white-label rename is no longer checked here: it moved to .patch files applied by phase
# 12-apps, and `patch` — unlike the `sed` it replaced — fails when its context stops matching, so
# `make seed` is now the gate (ADR-0002).
curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
  || { echo "FAIL: Euro-Office /healthcheck not reachable from host"; exit 1; }
$OCC eurooffice:documentserver --check \
  || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; exit 1; }
echo "PASS: Euro-Office smoke — /healthcheck 200 + documentserver --check OK"
