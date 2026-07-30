#!/usr/bin/env bash
# Office editing smoke — verifies the Euro-Office backend is wired end-to-end (Story 0.2, AD-5).
# Checks server health (host + server-side) via the eurooffice connector.
# Exits non-zero on ANY failure (so it fails loudly on a connector/host/round-trip error).
set -euo pipefail

# Read .env so this behaves the same run directly as through `make` (cf. scripts/smoke.sh).
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

OCC="docker compose exec -T --user www-data nextcloud php occ"
OFFICE_PORT="${OFFICE_PORT:-80}"

# Require the eurooffice connector — the sole office backend (AD-5). An app is enabled iff its
# appconfig `enabled` value is "yes".
[ "$($OCC config:app:get eurooffice enabled 2>/dev/null || true)" = "yes" ] \
  || { echo "FAIL: eurooffice connector not enabled — run: make office-eurooffice"; exit 1; }

echo "Office backend: Euro-Office (eurooffice)"

# The white-label rename, asserted on the files actually being served.
#
# This check was deleted when the rename moved from `sed` to .patch files, on the reasoning that
# `patch` fails loudly when its context stops matching and so `make seed` is the gate. True, but it
# only gates the moment the patch is applied. apps/ is gitignored, so any `occ app:update` — or an
# admin updating from Settings > Apps — replaces these files and reverts the rename, and nothing
# runs `make seed` afterwards. Between those two events every gate stayed green while the admin
# section and app list said "Nextcloud Office" (B-008, ADR-0002).
for f_want in "lib/AdminSection.php:Euro-Office" "appinfo/info.xml:<name>Euro-Office</name>"; do
  f="${f_want%%:*}"; want="${f_want#*:}"
  docker compose exec -T --user www-data nextcloud grep -qF "$want" "custom_apps/eurooffice/$f" \
    || { echo "FAIL: white-label rename missing from eurooffice/$f — was the app updated? run 'make seed'"; exit 1; }
done

curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
  || { echo "FAIL: Euro-Office /healthcheck not reachable from host"; exit 1; }
$OCC eurooffice:documentserver --check \
  || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; exit 1; }
echo "PASS: Euro-Office smoke — /healthcheck 200 + documentserver --check OK"
