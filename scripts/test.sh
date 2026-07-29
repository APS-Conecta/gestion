#!/usr/bin/env bash
# Local quality gate, run locally and by .github/workflows/ci.yml (Story 0.4). Runs the STATIC checks that need no running
# stack, then the smoke check when a stack is up. Exits non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
if [ ! -f .env ]; then
  echo "  note: .env absent — compose interpolation will fail; run 'cp .env.example .env' first"
fi
# Two parses, not three: `--profile eurooffice` reads the same compose.yaml and adds a service, so
# a bare `-f compose.yaml config -q` could only fail where this one already does.
check docker compose -f compose.yaml -f compose.dev.yaml config -q
check docker compose --profile eurooffice config -q
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh; do
  [ -e "$s" ] && check bash -n "$s"
done
check test -f dev/xdebug.ini
# Regression guard (#39): the phase runner must not wrap its `set -e` subshell in an `if` condition —
# bash suppresses errexit there, so a failing phase would run on and report success. Comment lines are
# stripped first: seed.sh documents the wrong shape on purpose, and the guard must not match that.
check bash -c '! grep -vE "^[[:space:]]*#" provisioning/seed.sh | grep -qE "if +! +\( *set -e"'
# Regression guard (ADR-0001): every asset server.css references must exist on disk. server.css
# shipped for months declaring four .woff2 files that were never generated — the TTF fallback
# swallowed the 404s, so nothing surfaced it. The fallback is gone; this is what replaces it.
check bash -c 'grep -oE "/themes/apsconecta[^)]+" themes/apsconecta/core/css/server.css | tr -d "\"" | sed "s|^/||" | while read -r f; do [ -f "$f" ] || exit 1; done'
# Regression guard: every brand SVG must PARSE, not merely exist. Nextcloud serves a malformed
# SVG with a 200 and the browser then renders nothing — silent, and the existence check above
# cannot see it. Cost us a debugging round on 2026-07-27: a double hyphen inside an XML comment
# in logo-header.svg (it quoted CSS variable names) made the whole file unparseable, so the
# header logo vanished while every gate stayed green.
check python3 -c 'import glob,sys,xml.etree.ElementTree as ET
bad=[]
for f in sorted(glob.glob("themes/apsconecta/core/img/**/*.svg", recursive=True)):
    try: ET.parse(f)
    except Exception as e: bad.append(f"{f}: {e}")
if bad: print("\n".join(bad)); sys.exit(1)'

# Regression guard (B-008 / #48): server.css hides Nextcloud's vendor-marketing block in personal
# settings — the "Reasons to use Nextcloud" PDF link, the "developed by the Nextcloud community"
# credit, and follow buttons for their Facebook/Bluesky/Mastodon/blog/newsletter. A CSS selector
# that stops matching fails SILENTLY: the rule does nothing and the whole block reappears on every
# staff member's settings page. So assert the CONTRACT against the shipped template — both the
# container class we hide AND the link id, because an upstream restructure could move either.
# Reads the running container's copy, which is the code actually serving pages.
if docker compose ps --status running --services 2>/dev/null | grep -qx nextcloud; then
  check docker compose exec -T --user www-data nextcloud \
    grep -q 'class="section development-notice"' apps/settings/templates/settings/personal/development.notice.php
  check docker compose exec -T --user www-data nextcloud \
    grep -q "open-reasons-use-nextcloud-pdf" apps/settings/templates/settings/personal/development.notice.php
else
  echo "  skipped: upstream vendor-block checks (need a running stack)"
fi

echo "== smoke (only if a stack is running) =="
if docker compose ps --status running --services 2>/dev/null | grep -qx nextcloud; then
  if bash scripts/smoke.sh; then echo "  ok:   smoke"; else echo "  FAIL: smoke"; fail=1; fi
else
  echo "  skipped: no running stack (static-only gate)"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: local gate green"
  exit 0
else
  echo "FAIL: local gate has failures"
  exit 1
fi
