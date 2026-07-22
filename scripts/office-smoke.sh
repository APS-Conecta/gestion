#!/usr/bin/env bash
# Office editing smoke — verifies the ACTIVE office backend is wired end-to-end (Story 0.2, AD-5/AD-11).
# Detects the active connector, checks server health (host + server-side) and connector reachability.
# Exits non-zero on ANY failure (so it fails loudly on a connector/host/round-trip error).
set -euo pipefail

. "$(dirname "$0")/office-lib.sh"
office_detect  # sets $rich/$euro, enforces AD-11 (exactly one active)

if [ "$rich" = on ]; then
  echo "Active office backend: Collabora (richdocuments)"
  # Collabora CODE serves HTTPS (self-signed) — use -k. Browser path (host) then server-side (NC container).
  curl -skf "https://localhost:${OFFICE_PORT}/hosting/discovery" >/dev/null \
    || { echo "FAIL: Collabora /hosting/discovery not reachable from host (browser path)"; exit 1; }
  docker compose exec -T nextcloud curl -skf "https://collabora:9980/hosting/discovery" >/dev/null \
    || { echo "FAIL: Collabora not reachable from the nextcloud container (server-side WOPI path)"; exit 1; }
  wopi=$($OCC config:app:get richdocuments wopi_url 2>/dev/null || true)
  [ -n "$wopi" ] || { echo "FAIL: richdocuments wopi_url is not configured"; exit 1; }
  echo "PASS: Collabora smoke — discovery reachable (host + nextcloud), wopi_url=${wopi}"

else
  echo "Active office backend: Euro-Office (eurooffice)"
  curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
    || { echo "FAIL: Euro-Office /healthcheck not reachable from host"; exit 1; }
  $OCC eurooffice:documentserver --check \
    || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; exit 1; }
  echo "PASS: Euro-Office smoke — /healthcheck 200 + documentserver --check OK"
fi
