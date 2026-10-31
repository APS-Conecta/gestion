#!/usr/bin/env bash
# Office backend gate — is Euro-Office wired end-to-end, and is it still the OSS build? (Story 0.2,
# AD-5, and the machine-checkable half of Epic 4 / Story 4.3.) Exits non-zero on ANY failure.
#
# This was two scripts. office-formats.sh shared 14 of its 36 lines with this one verbatim — same
# preamble, same connector precondition, same healthcheck — and its unique content was one
# `docker inspect`. Two files meant two chances for the shared half to drift, and the licence half
# ran only when someone remembered it. Now the licence check runs on every smoke.
#
# THE AIO LEGS (S8, slice 20 — the completion the port deferred): the document server is the
# wizard's sibling aps-conecta-eurooffice behind apache's /eurooffice, so every leg answers the
# stack an operator actually runs. The healthcheck goes through the PUBLIC path — the exact leg
# that failed in upstream #8433 (the DS's own port can answer while the public route is broken).
# The version assert is the Dockerfile's pin: the connector's own floor is only "DS > 6.0"
# (DocumentService.php:415), so a drifted documentserver would pass --check silently.
# The connector is installed unchanged from the official store. The image assert accepts the two
# namespaces this distribution's lifecycle runs — nextcloud-releases (the probe's stock bring-up,
# slice 1's harness) and aps-conecta (the suite's own source build) —
# and anything else (a different DocumentServer image) reds.
#
# Browser editing and format fidelity are verified separately through real clients.
set -euo pipefail

# Read .env so this behaves the same from any cwd (cf. scripts/smoke.sh).
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"


# Require the eurooffice connector — the sole office backend (AD-5). An app is enabled iff its
# appconfig `enabled` value is "yes".
[ "$(occ config:app:get eurooffice enabled 2>/dev/null || true)" = "yes" ] \
  || { echo "FAIL: eurooffice connector not enabled — run: sudo aps-conecta provision --reponer"; exit 1; }

require_store_app_integrity eurooffice || exit 1

echo "Office backend: Euro-Office (eurooffice)"
# the suite's public URL, the base smoke rides too (env.sh, #163)
suite_url_resolve || exit 1


# The public-path healthcheck — through apache, never the DS's own port (#8433's exact leg: this
# is the URL that goes dark on hairpin-NAT / split-DNS breakage while the container stays green).
health="$(suite_curl -sf "$SUITE_URL/eurooffice/healthcheck")" \
  || { echo "FAIL: Euro-Office /healthcheck not reachable through the public path ($SUITE_URL/eurooffice)$SUITE_D10"; exit 1; }
[ "$health" = true ] \
  || { echo "FAIL: Euro-Office /healthcheck did not report true through the public path ($SUITE_URL/eurooffice)$SUITE_D10"; exit 1; }


# --check proves the whole wire at once: healthcheck + JWT + the version floor + a real docx
# conversion round-trip via StorageUrl (DocumentService.php:383-425). Under AIO the wizard's
# entrypoint owns the connector's public URL and jwt_secret (rewrites both on every boot), and
# phase 14 writes only the internal URLs, for an install by IP (R22) — so this leg asserts the
# values the running instance actually carries, whoever wrote them.
out="$(occ eurooffice:documentserver --check 2>&1)" \
  || { echo "FAIL: 'occ eurooffice:documentserver --check' reported the server unreachable"; printf '%s\n' "$out"; exit 1; }

# The version, read from --check's own success line ("Document server $url version $v is
# successfully connected" — lib/Command/DocumentServer.php:84). The ANSI strip is belt-and-braces:
# occ strips its own <info> tags when stdout is not a TTY (docker exec), but the parse must not
# depend on that detection. The DS answers <pin>.<build>, so the pin matches whole or before a
# dot; the pin is read from the Dockerfile the image is built from (env.sh cds to the repo
# root), never a second literal. An unreadable version or pin fails CLOSED — a parser that reads
# nothing must never pass (B-014).
ver="$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.* version \([0-9][0-9.]*\) is successfully connected.*/\1/p' | head -1)"
[ -n "$ver" ] || { echo "FAIL: could not read the document server version from --check's output:"; printf '%s\n' "$out"; exit 1; }
# Official -N tags revise the package; the native API still reports the core version.
pin="$(sed -nE 's|^FROM ghcr\.io/euro-office/documentserver:v([0-9]+\.[0-9]+\.[0-9]+)(-[1-9][0-9]*)?$|\1|p' Containers/eurooffice/Dockerfile 2>/dev/null || true)"
[ -n "$pin" ] || { echo "FAIL: could not read the document server pin from Containers/eurooffice/Dockerfile"; exit 1; }
case "$ver" in
  "$pin"|"$pin".*) echo "  ✓ document server ${ver} (the pin, ${pin})" ;;
  *) echo "FAIL: document server version '${ver}' is not the pinned ${pin} (Containers/eurooffice/Dockerfile) — aio-eurooffice is built from that pin; check which image the wizard started"; exit 1 ;;
esac

# The DS image: the one this distribution's channel shipped. Resolved through `docker ps` by
# NAME (the transport port's rule), the same name
# test.sh's office gate matches, so the two cannot drift.
img="$(docker inspect "$(docker ps -q --filter name=^aps-conecta-eurooffice$ | head -1)" --format '{{.Config.Image}}' 2>/dev/null || true)"
# (P35, implement-time — measured on the probe) upstream's office image is named aio-eurooffice
# (the aio- prefix, like aio-nextcloud); the fork builds it in its own namespace.
# The unprefixed eurooffice shapes the fence carried never exist.
case "$img" in
  ghcr.io/nextcloud-releases/aio-eurooffice*|ghcr.io/aps-conecta/aio-eurooffice*) echo "  ✓ DS image: ${img}" ;;
  *) echo "FAIL: unexpected document server image '${img}' (expected ghcr.io/nextcloud-releases/aio-eurooffice or ghcr.io/aps-conecta/aio-eurooffice)"; exit 1 ;;
esac

echo "PASS: Euro-Office — public-path /healthcheck 200, documentserver --check OK (DS ${ver}), connector enabled, ${img}"
echo "      (OOXML edits in place; ODF edits via conversion, lossy — see README)"

