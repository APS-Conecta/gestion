#!/usr/bin/env bash
# Office editing smoke — verifies the Euro-Office backend is wired end-to-end (Story 0.2, AD-5).
# Checks server health (host + server-side) via the eurooffice connector.
# Exits non-zero on ANY failure (so it fails loudly on a connector/host/round-trip error).
set -euo pipefail

. "$(dirname "$0")/office-lib.sh"
office_detect  # require the eurooffice connector (AD-5)

echo "Office backend: Euro-Office (eurooffice)"

# The connector white-labels its own name via two `sed`s in `make office-eurooffice` — the admin
# section name is a bare PHP literal with no `t()` call, so l10n cannot reach it. `sed` exits 0 when
# its pattern matches nothing, so an upstream change to either line turns the rename into a SILENT
# no-op; this is the gate that makes it loud. Assert the desired state rather than the absence of
# "Nextcloud Office": that string legitimately stays in info.xml's <summary>/<description>, and a
# positive check also catches an upstream restructure where the old pattern is gone and the new
# value never got written. Unconditional by design — office_detect above already required the app,
# so there is no "skip if absent" branch for a failure to hide in.
$NCEXEC grep -q 'return "Euro-Office";' custom_apps/eurooffice/lib/AdminSection.php \
  || { echo "FAIL: eurooffice admin section is not renamed — the sed in 'make office-eurooffice' stopped matching lib/AdminSection.php"; exit 1; }
$NCEXEC grep -q '<name>Euro-Office</name>' custom_apps/eurooffice/appinfo/info.xml \
  || { echo "FAIL: eurooffice app name is not renamed — the sed in 'make office-eurooffice' stopped matching appinfo/info.xml"; exit 1; }
echo "PASS: eurooffice white-labeled as Euro-Office (admin section + app name)"
curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
  || { echo "FAIL: Euro-Office /healthcheck not reachable from host"; exit 1; }
$OCC eurooffice:documentserver --check \
  || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; exit 1; }
echo "PASS: Euro-Office smoke — /healthcheck 200 + documentserver --check OK"
