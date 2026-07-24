#!/usr/bin/env bash
# Office OSS-licence audit (Story 4.3) — the machine-checkable half of Epic 4.
# For the Euro-Office backend it asserts the backend is OSS / self-hosted with NO paid licence.
#
# NOT covered here (no gate can): in-browser rendering, live convergence, cursor presence, and open/save
# FIDELITY — and, for Euro-Office, per-format editing (it exposes no WOPI discovery to parse). Those were
# checked by hand in a browser on 2026-07-24 and passed; the standing runbook was retired with that run.
# Outcome and the ODF caveat live in README.md ("Office suite").
set -euo pipefail

. "$(dirname "$0")/office-lib.sh"

office_detect  # require the eurooffice connector (AD-5)

echo "Office backend: Euro-Office (eurooffice)"
curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
  || { echo "FAIL: Euro-Office /healthcheck not reachable"; exit 1; }
img="$(docker inspect apsconecta-gestion-eurooffice-1 --format '{{.Config.Image}}' 2>/dev/null || true)"
case "$img" in
  *euro-office/documentserver*) echo "  ✓ OSS image: ${img} (Euro-Office, AGPL — no paid licence)";;
  *) echo "FAIL: unexpected Euro-Office image '${img}'"; exit 1;;
esac
echo "PASS: Euro-Office — server healthy + OSS image (OOXML edits in place; ODF is view-only — see README)"
