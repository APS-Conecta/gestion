#!/usr/bin/env bash
# Local quality gate, run locally and by .github/workflows/ci.yml (Story 0.4). Runs the STATIC checks that need no running
# stack, then the smoke check when a stack is up. Exits non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
if [ ! -f .env ]; then
  echo "  note: .env absent — compose interpolation will fail; run 'make setup' first"
fi
# One parse, not two: the `--profile eurooffice` run went with the profile in #81 — Euro-Office is
# an ordinary service now, so this parse already covers it. The dev overlay is included because it
# is the only other file that can change what compose resolves.
check docker compose -f compose.yaml -f compose.dev.yaml config -q
linted=0
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh; do
  [ -e "$s" ] || continue
  linted=$((linted + 1)); check bash -n "$s"
done
# A glob that matches nothing stays literal, `[ -e ]` skips it, and the gate reports only the checks
# it did run — so a renamed directory would silently lint nothing and still print all-ok.
#
# The floor this replaced (`-ge 15`) could not see the case it was written for. It counted what the
# globs matched, and the globs are what define that set: a script added in a NEW directory is absent
# from both sides, so the count never moves and the floor stays green. Compare the sweep against
# `git ls-files` instead — the one list that grows when a script is added anywhere. Adding a script
# to an existing directory still costs nothing; adding a directory now fails loudly, which is the
# whole point.
check bash -c '
  diff <(git ls-files "*.sh" | sort) \
       <(ls scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh 2>/dev/null | sort)'
check test -f dev/xdebug.ini
# THE GATE'S OWN GATE. scripts/seed-idempotent.sh decides whether a second seed wrote anything by
# grepping the log for write verbs. Every alternative in that regex is a claim about vocabulary
# lib.sh's log() actually emits — and when one stops being true the gate does not fail, it silently
# stops looking. That is not hypothetical: `installed/enabled` sat in WRITES matching nothing that
# any phase emits, so on `main` the idempotency gate was structurally incapable of failing on an app
# enable (found 2026-08-02, fixed in #121).
#
# So: assert every alternative still matches something the code can print. The corpus is every
# log()/printf literal under provisioning/, with ${...} and $(...) blanked — a write verb is a
# constant, the values around it are not. This is the direction that catches the real bug; the
# reverse (a write verb no alternative covers) needs a judgement about which log lines ARE writes,
# and a heuristic for that flags correct code, which is why the 2026-08-02 sweep rejected it.
check python3 -c '
import re, glob, sys
corpus = []
for f in glob.glob("provisioning/**/*.sh", recursive=True):
    for line in open(f, encoding="utf-8"):
        for m in re.finditer(r"(?:log|printf)\s+([\"\x27])(.*?)\1", line):
            corpus.append("    " + re.sub(r"\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_]\w*", "X", m.group(2)))
src = ""
for line in open("scripts/seed-idempotent.sh", encoding="utf-8"):
    if line.startswith("WRITES="):
        src = line.split("=", 1)[1].strip().strip("\x27\"")
dead = [a for a in src.split("|") if not any(re.search(a, c) for c in corpus)]
if dead:
    print("WRITES alternatives that match nothing provisioning/ can emit: " + repr(dead))
    print("seed-idempotent.sh cannot fail on these. Fix the regex or the log line.")
    sys.exit(1)
if not src:
    print("could not read WRITES= from scripts/seed-idempotent.sh"); sys.exit(1)'
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
  # The home affordance rests on `<a id="nextcloud">` in the authenticated layout: server.css reserves
  # 68px for the mark, hangs the home icon off ::before and the clinic name off ::after, and the click
  # works only because that element is the home link.
  # It scopes on the ELEMENT TYPE because the PUBLIC SHARE header
  # renders the same id as `<div class="header-appname">` with a share title inside it — an
  # unscoped rule put the 224px padding and a 200px logo on the page external recipients see.
  # So assert both shapes: authenticated is an anchor, public is not. If upstream renames the id,
  # or ever makes the two the same element, every rule stops applying (or starts leaking) with
  # the header still rendering — silently, which is why this is a gate and not a comment.
  check docker compose exec -T --user www-data nextcloud sh -c \
    'grep -B3 -- '"'"'id="nextcloud"'"'"' core/templates/layout.user.php | grep -q -- "<a "'
  check docker compose exec -T --user www-data nextcloud \
    grep -qE '<div id="nextcloud" class="header-appname"' core/templates/layout.public.php
  # Same silent-failure shape as B-008: server.css hangs the clinic name off `.login-form__headline`.
  check docker compose exec -T --user www-data nextcloud \
    grep -q "login-form__headline" dist/core-login.js
  # ENUMERATION GATE (ADR-0004). guest.css brands the screens Nextcloud draws through the legacy
  # Template::printPage(), which dispatches no event and so gets no themed CSS. There are SEVEN such
  # call sites in TWO files on NC34 — four in lib/base.php, three in TemplateManager. Every screen in
  # the class routes through one of them, so the COUNT is the whole contract: an NC35 that adds an
  # eighth site has added a screen nobody has looked at, and no other check here can see that. This
  # is the only assertion that delivers "every Nextcloud major"; the rest verify today's instance.
  # When it fails, read the new site, decide whether guest.css already covers it, then move the 7.
  # -e for the pattern, NOT `--`: `--` ends option parsing, so a --include after it is read as a
  # FILENAME. The count came out right anyway (the call appears only in .php files) while grep
  # errored on every run into check's discarded stderr — a gate passing for the wrong reason.
  check docker compose exec -T --user www-data nextcloud sh -c \
    'test "$(grep -r --include="*.php" -e "->printPage()" lib core index.php | wc -l)" -eq 7'
  # And that core still READS what guest.css declares. Both variables carry a fallback to Nextcloud's
  # own art inside core's guest.css, so an upstream rename does not break the page — it silently
  # restores the vendor logo and backdrop on exactly the screens nobody visits on a good day.
  check docker compose exec -T --user www-data nextcloud sh -c \
    'grep -q -- "var(--image-logo" core/css/guest.css && grep -q -- "var(--image-background" core/css/guest.css'
else
  echo "  skipped: upstream vendor-block checks (need a running stack)"
fi

echo "== smoke (only if a stack is running) =="
if docker compose ps --status running --services 2>/dev/null | grep -qx nextcloud; then
  if bash scripts/smoke.sh; then echo "  ok:   smoke"; else echo "  FAIL: smoke"; fail=1; fi
else
  echo "  skipped: no running stack (static-only gate)"
fi

# Euro-Office joined the standard gate in #81, because it joined the stack: office-smoke was
# separate only because it needed a service that might not be running. Its rename assertions are
# load-bearing (ADR-0002 amendment) — an `occ app:update` from the admin UI reverts our patches with
# nothing running `make seed` — so folding them in widens their coverage rather than duplicating it.
#
# Still guarded on the service, not assumed: this script runs in the static CI gate with no stack at
# all, and `make office-down` is a documented way to reclaim the RAM. `make up --wait` is what makes
# this deterministic when the stack IS up — without it the gate raced the 120s start_period.
echo "== office smoke (only if the document server is running) =="
if docker compose ps --status running --services 2>/dev/null | grep -qx eurooffice; then
  if bash scripts/office-smoke.sh; then echo "  ok:   office-smoke"; else echo "  FAIL: office-smoke"; fail=1; fi
else
  echo "  skipped: eurooffice not running"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: local gate green"
  exit 0
else
  echo "FAIL: local gate has failures"
  exit 1
fi
