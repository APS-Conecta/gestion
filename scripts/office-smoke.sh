#!/usr/bin/env bash
# Office editing smoke — verifies the Euro-Office backend is wired end-to-end (Story 0.2, AD-5).
# Checks server health (host + server-side) via the eurooffice connector.
# Exits non-zero on ANY failure (so it fails loudly on a connector/host/round-trip error).
set -euo pipefail

. "$(dirname "$0")/office-lib.sh"
office_detect  # require the eurooffice connector (AD-5)

echo "Office backend: Euro-Office (eurooffice)"
curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
  || { echo "FAIL: Euro-Office /healthcheck not reachable from host"; exit 1; }
$OCC eurooffice:documentserver --check \
  || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; exit 1; }
echo "PASS: Euro-Office smoke — /healthcheck 200 + documentserver --check OK"
