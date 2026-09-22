#!/usr/bin/env bash
# Office backend gate — is Euro-Office wired end-to-end, and is it still the OSS build? (Story 0.2,
# AD-5, and the machine-checkable half of Epic 4 / Story 4.3.) Exits non-zero on ANY failure.
#
# This was two scripts. office-formats.sh shared 14 of its 36 lines with this one verbatim — same
# preamble, same connector precondition, same healthcheck — and its unique content was one
# `docker inspect`. Two files meant two chances for the shared half to drift, and the licence half
# ran only when someone remembered `make office-formats`. Now the licence check runs on every smoke.
#
# THE AIO LEGS (S8, slice 20 — the completion the port deferred): the document server is the
# wizard's sibling nextcloud-aio-eurooffice behind apache's /eurooffice, so every leg answers the
# stack an operator actually runs. The healthcheck goes through the PUBLIC path — the exact leg
# that failed in upstream #8433 (the DS's own port can answer while the public route is broken).
# The version assert pins the 9.3.x line: the connector's own floor is only "DS > 6.0"
# (DocumentService.php:415), so a drifted documentserver generation would pass --check silently —
# R3's verified pairing is connector 11.0.5 ↔ DS 9.3.x. The image assert accepts the two
# namespaces this distribution's lifecycle runs — nextcloud-releases (the probe's stock bring-up,
# slice 1's harness) and aps-conecta (the suite's channel; the retag preserves the manifest, D12) —
# and anything else (a stranger's DS, Collabora, OnlyOffice) reds.
#
# The white-label rename grep RETIRED here (slice 13's routing): under the suite nothing can
# revert the rename between builds — the store is off (patch 020) and a published tag's digests
# never move (D12) — so the runtime grep's threat model is empty. scripts/bake.sh owns the pair as
# build-time asserts, and the brand-gate's 030 row pins the mechanism to the fork's own script.

# NOT covered here, because no gate can: in-browser rendering, live convergence, cursor presence,
# and open/save FIDELITY — plus per-format editing, since Euro-Office exposes no WOPI discovery to
# parse. Checked by hand in a browser on 2026-07-24 and passed; the standing runbook retired with
# that run. Outcome and the ODF caveat live in README.md ("Office suite").
set -euo pipefail

# Read .env so this behaves the same run directly as through `make` (cf. scripts/smoke.sh).
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

# The apache surface every smoke curl rides — smoke's own key and default (smoke.sh sets the
# same line; its first curl consumer is check 5, /status.php).
# Under AIO the DS answers behind apache's /eurooffice route, never a publish of its own, so the
# compose-era OFFICE_PORT require retired with the compose legs.
HTTP_PORT="${HTTP_PORT:-8180}"


# Require the eurooffice connector — the sole office backend (AD-5). An app is enabled iff its
# appconfig `enabled` value is "yes".
[ "$(occ config:app:get eurooffice enabled 2>/dev/null || true)" = "yes" ] \
  || { echo "FAIL: eurooffice connector not enabled — run: make install"; exit 1; }

echo "Office backend: Euro-Office (eurooffice)"


# The public-path healthcheck — through apache, never the DS's own port (#8433's exact leg: this
# is the URL that goes dark on hairpin-NAT / split-DNS breakage while the container stays green).
curl -sf "http://localhost:${HTTP_PORT}/eurooffice/healthcheck" >/dev/null \
  || { echo "FAIL: Euro-Office /healthcheck not reachable through the public path (http://localhost:${HTTP_PORT}/eurooffice) — on a clinic, check the reverse-proxy/hairpin route (D10); on the probe, the loopback apache"; exit 1; }


# --check proves the whole wire at once: healthcheck + JWT + the version floor + a real docx
# conversion round-trip via StorageUrl (DocumentService.php:383-425). Under AIO the wizard's
# entrypoint owns the connector's URLs and jwt_secret (rewrites both on every boot), and phase
# 14's AIO arm (slice 16) leaves them alone — so this leg asserts the ENTRYPOINT's values,
# never phase 14's, which is the only posture that can be true on a running instance.
out="$(occ eurooffice:documentserver --check 2>&1)" \
  || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; printf '%s\n' "$out"; exit 1; }

# The version pin, read from --check's own success line ("Document server $url version $v is
# successfully connected" — lib/Command/DocumentServer.php:84). The ANSI strip is belt-and-braces:
# occ strips its own <info> tags when stdout is not a TTY (docker exec), but the parse must not
# depend on that detection. An unreadable version fails CLOSED — a parser that reads nothing
# must never pass (B-014).
ver="$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.* version \([0-9][0-9.]*\) is successfully connected.*/\1/p' | head -1)"
[ -n "$ver" ] || { echo "FAIL: could not read the document server version from --check's output:"; printf '%s\n' "$out"; exit 1; }
case "$ver" in
  9.3.*) echo "  ✓ document server ${ver} (the pinned pairing line, R3)" ;;
  *) echo "FAIL: document server version '${ver}' is outside the pinned 9.3.x line — the suite pairs connector 11.0.5 with DS 9.3.x (R3); check which image the wizard started"; exit 1 ;;
esac

# The DS image: the one this distribution's channel shipped. Resolved through `docker ps` by
# NAME (the transport port's rule — no compose context exists on an AIO host), the same name
# test.sh's office gate matches, so the two cannot drift.
img="$(docker inspect "$(docker ps -q --filter name=nextcloud-aio-eurooffice | head -1)" --format '{{.Config.Image}}' 2>/dev/null || true)"
# (P35, implement-time — measured on the probe) upstream's office image is named aio-eurooffice
# (the aio- prefix, like aio-nextcloud); the fork's retag keeps the name and swaps the namespace.
# The unprefixed eurooffice shapes the fence carried never exist.
case "$img" in
  ghcr.io/nextcloud-releases/aio-eurooffice*|ghcr.io/aps-conecta/aio-eurooffice*) echo "  ✓ DS image: ${img}" ;;
  *) echo "FAIL: unexpected document server image '${img}' (expected ghcr.io/nextcloud-releases/aio-eurooffice or ghcr.io/aps-conecta/aio-eurooffice)"; exit 1 ;;
esac

echo "PASS: Euro-Office — public-path /healthcheck 200, documentserver --check OK (DS ${ver}), connector enabled, ${img}"
echo "      (OOXML edits in place; ODF edits via conversion, lossy — see README)"

