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
linted=0
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh; do
  [ -e "$s" ] || continue
  linted=$((linted + 1)); check bash -n "$s"
done
# A glob that matches nothing stays literal, `[ -e ]` skips it, and the gate reports only the checks
# it did run — so a renamed directory would silently lint nothing and still print all-ok. Floor, not
# an exact count, so adding a script does not break the gate.
check test "$linted" -ge 15
check test -f dev/xdebug.ini
# Regression guard (#39): the phase runner must not consume its `set -e` subshell's status in a
# conditional context — bash suppresses errexit there, so a failing phase runs on and reports
# success. Matches on what PRECEDES the subshell rather than listing bad forms, because `if`,
# `while`, `until`, `&&` and `||` all do it: nothing but whitespace may precede the `(`.
# Comments are stripped first, since seed.sh documents the wrong shape on purpose.
check bash -c '! grep -vE "^[[:space:]]*#" provisioning/seed.sh | grep -qE "[^[:space:]][[:space:]]*\([[:space:]]*set[[:space:]]+-e"'
# Regression guard (ADR-0001): every asset server.css references must exist on disk. It shipped for
# months declaring four .woff2 files that were never generated, and the TTF fallback swallowed the
# 404s. The COUNT is asserted before the existence loop, and that is the point: `grep | while read`
# runs zero times when grep matches nothing and exits 0, so the guard passed on a file with no themed
# reference at all. Requiring every reference to be a themed absolute path also catches one of four
# drifting, which "at least one" would not.
check bash -c '
  css=themes/apsconecta/core/css/server.css
  total=$(grep -oE "url\(\"" "$css" | wc -l)   # the quote matters: server.css says "url()" in prose
  themed=$(grep -oE "url\(\"/themes/apsconecta[^\"]+\"" "$css" | wc -l)
  [ "$total" -ge 1 ] && [ "$total" -eq "$themed" ] || exit 1
  grep -oE "/themes/apsconecta[^\")]+" "$css" | sed "s|^/||" | while read -r f; do [ -f "$f" ] || exit 1; done'
# Regression guard: every brand SVG must PARSE, not merely exist. Nextcloud serves a malformed SVG
# with a 200 and the browser renders nothing — silent, and the existence check above cannot see it.
# A double hyphen inside an XML comment once made logo-header.svg unparseable and the header logo
# vanished while every gate stayed green.
check python3 -c 'import glob,sys,xml.etree.ElementTree as ET
bad=[]
for f in sorted(glob.glob("themes/apsconecta/core/img/**/*.svg", recursive=True)):
    try: ET.parse(f)
    except Exception as e: bad.append(f"{f}: {e}")
if bad: print("\n".join(bad)); sys.exit(1)'
# Regression guard (B-011): a lockup that draws text must carry the font that text is set in. An SVG
# served as an image is an isolated document and cannot see server.css's @font-face, so the wordmark
# still renders — just in the OS fallback, which nobody reports as a bug.
# themes/apsconecta/tools/embed-fonts.py puts the subset in; this asserts it was run.
check python3 -c 'import glob,sys,re
bad=[]
for f in sorted(glob.glob("themes/apsconecta/core/img/**/*.svg", recursive=True)):
    s = open(f, encoding="utf-8").read()
    if not re.search(r"<text[ >]", s): continue
    if "@font-face" not in s or "data:font/woff2;base64," not in s:
        bad.append(f"{f}: draws <text> with no embedded @font-face — run themes/apsconecta/tools/embed-fonts.py")
    for fam in set(re.findall(r"font-family=\"([^\"]+)\"", s)):
        if "," in fam:
            bad.append(f"{f}: font-family=\"{fam}\" keeps an OS fallback; the embedded face must be the only option")
if bad: print("\n".join(bad)); sys.exit(1)'

# Regression guard (B-008 / #48): server.css hides Nextcloud's vendor-marketing block in personal
# settings. A CSS selector that stops matching fails SILENTLY — the rule does nothing and the block
# reappears for every staff member — so assert the CONTRACT against the shipped template: both the
# container class and the link id, since an upstream restructure could move either.
# Everything below reads the running container's copy, the code actually serving pages.
if docker compose ps --status running --services 2>/dev/null | grep -qx nextcloud; then
  check docker compose exec -T --user www-data nextcloud \
    grep -q 'class="section development-notice"' apps/settings/templates/settings/personal/development.notice.php
  check docker compose exec -T --user www-data nextcloud \
    grep -q "open-reasons-use-nextcloud-pdf" apps/settings/templates/settings/personal/development.notice.php
  # The home affordance rests on `<a id="nextcloud">` in the authenticated layout: server.css
  # widens it to 224px and hangs INICIO off its ::after, and the click works only because that
  # element is the home link. It scopes on the ELEMENT TYPE because the PUBLIC SHARE header
  # renders the same id as `<div class="header-appname">` with a share title inside it — an
  # unscoped rule put the 224px padding and a 200px logo on the page external recipients see.
  # So assert both shapes: authenticated is an anchor, public is not. If upstream renames the id,
  # or ever makes the two the same element, every rule stops applying (or starts leaking) with
  # the header still rendering — silently, which is why this is a gate and not a comment.
  check docker compose exec -T --user www-data nextcloud sh -c \
    'grep -B3 -- '"'"'id="nextcloud"'"'"' core/templates/layout.user.php | grep -q -- "<a "'
  check docker compose exec -T --user www-data nextcloud \
    grep -qE '<div id="nextcloud" class="header-appname"' core/templates/layout.public.php
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
