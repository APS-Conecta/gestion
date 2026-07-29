#!/usr/bin/env bash
# Office OSS-licence audit (Story 4.3) — the machine-checkable half of Epic 4.
# For the Euro-Office backend it asserts the backend is OSS / self-hosted with NO paid licence.
#
# NOT covered here (no gate can): in-browser rendering, live convergence, cursor presence, and open/save
# FIDELITY — and, for Euro-Office, per-format editing (it exposes no WOPI discovery to parse). Those were
# checked by hand in a browser on 2026-07-24 and passed; the standing runbook was retired with that run.
# Outcome and the ODF caveat live in README.md ("Office suite").
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
curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
  || { echo "FAIL: Euro-Office /healthcheck not reachable"; exit 1; }
# Resolve the container through compose rather than naming it: `apsconecta-gestion-eurooffice-1`
# hardcoded the project name, so this check silently found nothing under COMPOSE_PROJECT_NAME —
# which is exactly how the clean-boot rehearsal runs.
img="$(docker inspect "$(docker compose ps -q eurooffice)" --format '{{.Config.Image}}' 2>/dev/null || true)"
case "$img" in
  *euro-office/documentserver*) echo "  ✓ OSS image: ${img} (Euro-Office, AGPL — no paid licence)";;
  *) echo "FAIL: unexpected Euro-Office image '${img}'"; exit 1;;
esac
# "ODF is view-only" until #45 shipped lossy ODF editing via OOXML conversion (`editFormats` +
# `defFormats` in `make office-eurooffice`). The gate was still printing the old claim on every run.
echo "PASS: Euro-Office — server healthy + OSS image (OOXML edits in place; ODF edits via conversion, lossy — see README)"
