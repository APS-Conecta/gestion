#!/usr/bin/env bash
# Office backend gate — is Euro-Office wired end-to-end, and is it still the OSS build? (Story 0.2,
# AD-5, and the machine-checkable half of Epic 4 / Story 4.3.) Exits non-zero on ANY failure.
#
# This was two scripts. office-formats.sh shared 14 of its 36 lines with this one verbatim — same
# preamble, same connector precondition, same healthcheck — and its unique content was one
# `docker inspect`. Two files meant two chances for the shared half to drift, and the licence half
# ran only when someone remembered `make office-formats`. Now the licence check runs on every smoke.
#
# NOT covered here, because no gate can: in-browser rendering, live convergence, cursor presence,
# and open/save FIDELITY — plus per-format editing, since Euro-Office exposes no WOPI discovery to
# parse. Checked by hand in a browser on 2026-07-24 and passed; the standing runbook retired with
# that run. Outcome and the ODF caveat live in README.md ("Office suite").
set -euo pipefail

# Read .env so this behaves the same run directly as through `make` (cf. scripts/smoke.sh).
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

: "${OFFICE_PORT:?set OFFICE_PORT in .env}"

# Require the eurooffice connector — the sole office backend (AD-5). An app is enabled iff its
# appconfig `enabled` value is "yes".
[ "$(occ config:app:get eurooffice enabled 2>/dev/null || true)" = "yes" ] \
  || { echo "FAIL: eurooffice connector not enabled — run: make install"; exit 1; }

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

# The pairing check: connector 11.0.5 ↔ documentserver 9.3.4, certified as a set — and the AIO
# fork's Dockerfile base rides the same suite release, so one version string must not describe
# two pairings. The version source is the connector's own --check line: it asks the DS itself
# (measured output: "… version 9.3.4.37 is successfully connected"), so this asserts the RUNNING
# version, not the configured image. The BUILD suffix is not the contract — a hotfix rebuild
# moves .37 inside 9.3.4 — the x.y.z is. The pattern lives in one variable so test.sh can extract
# it and red-test both directions.
DS_VERSION_PATTERN='version 9\.3\.4(\.| )'
ds_check="$(occ eurooffice:documentserver --check)" \
  || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; exit 1; }
printf '%s' "$ds_check" | grep -qE "$DS_VERSION_PATTERN" \
  || { echo "FAIL: documentserver is not 9.3.4 — this release pairs the connector with DS 9.3.4:" >&2
       printf '%s\n' "$ds_check" >&2; exit 1; }

# OSS / no-paid-licence. Resolve the container through compose rather than naming it:
# `apsconecta-gestion-eurooffice-1` hardcoded the project name, so this silently found nothing
# under COMPOSE_PROJECT_NAME — which is exactly how the clean-boot rehearsal runs.
img="$(docker inspect "$(docker compose ps -q eurooffice)" --format '{{.Config.Image}}' 2>/dev/null || true)"
case "$img" in
  *euro-office/documentserver*) echo "  ✓ OSS image: ${img} (Euro-Office, AGPL — no paid licence)";;
  *) echo "FAIL: unexpected Euro-Office image '${img}'"; exit 1;;
esac

echo "PASS: Euro-Office — /healthcheck 200, documentserver --check OK (DS 9.3.4), rename intact, OSS image"
echo "      (OOXML edits in place; ODF edits via conversion, lossy — see README)"
