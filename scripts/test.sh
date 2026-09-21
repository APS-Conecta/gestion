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
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh dev/*.sh; do
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
# SUBSET, not equality. The sweep legitimately lints files git has never heard of: cleanboot.yml
# generates sites/ci/site.sh to install a clinic from nothing, and linting it is correct — it is
# real shell that a real install sources. Demanding the two lists MATCH failed there and only there,
# which is the worst shape a gate can have: green on every developer's machine, red only in CI.
# What actually matters is that nothing TRACKED escapes the sweep, so subtract and require empty.
check bash -c '
  [ -z "$(comm -23 <(git ls-files "*.sh" | sort) \
                   <(ls scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh dev/*.sh 2>/dev/null | sort))" ]'
check test -f dev/xdebug.ini
# Same three assertions `ensure_vendored_app` already makes (lib.sh:211-222), moved from seed time to
# PR time. At seed time they run on a CLINIC, during `make install` — the worst place to learn that a
# tarball and its manifest stopped describing each other, because the operator is mid-install and the
# failure reads as the install being broken. Here it needs no stack, no .env, no clock and no network,
# so it runs in any pull request, including a hotfix opened from a clinic.
# NOT a replacement for the seed-time check: that one guards the bytes that actually get unpacked.
# B-012's other half. That bug was two defects sharing a row: a CSS rule leaking onto share pages
# (guarded below, in the running-stack block) and `ensure_groupfolder … >/dev/null`, which swallowed
# the very lines `seed-idempotent.sh` greps for — so the idempotency gate could not fail on any group
# folder. Only the CSS half was ever gated. A phase's STDOUT IS its contract with that gate.
# Redirecting `occ` is fine and common (the helper logs afterwards, via `&&`); redirecting a HELPER
# is what blinds it. The function list is read out of lib.sh rather than typed here, so it cannot
# drift the way a second hand-maintained list would.
# When this one goes red, `check` has already swallowed the offending line (see its definition at the
# top of this file): re-run the grep below by hand to see which phase and which line number.
check bash -c '
  fns=$(grep -oE "^[a-z_]+\(\)" provisioning/lib.sh | tr -d "()" | sort -u | paste -sd"|" -)
  bad=$(grep -rnE "(^|[;&[:space:]])($fns)([[:space:]][^|]*)?>[[:space:]]*/dev/null" \
          provisioning/phases/*.sh provisioning/seed.sh 2>/dev/null || true)
  [ -z "$bad" ] || { printf "%s\n" "$bad" >&2; exit 1; }'
check bash -c '
  rc=0
  for v in provisioning/apps/*/VENDOR; do
    d=$(dirname "$v"); id=$(basename "$d")
    n=$(ls "$d"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$n" -ne 1 ]; then echo "$id: expected exactly one *.tar.gz, found $n" >&2; rc=1; continue; fi
    t=$(ls "$d"/*.tar.gz)
    ver=$(sed -n "s/^version=//p" "$v"); sha=$(sed -n "s/^sha256=//p" "$v")
    if [ -z "$ver" ] || [ -z "$sha" ]; then echo "$id: VENDOR lacks version= or sha256=" >&2; rc=1; continue; fi
    [ "$(basename "$t")" = "$id-$ver.tar.gz" ] || { echo "$id: $(basename "$t") is not $id-$ver.tar.gz" >&2; rc=1; }
    echo "$sha  $t" | sha256sum --check --status || { echo "$id: bytes do not match sha256= in VENDOR" >&2; rc=1; }
  done
  exit $rc'
# docs/LICENSING.md claims a licence per app and says it was read "from each app'"'"'s appinfo/info.xml
# inside the shipped tarball". Nothing checked that it still was. `eurooffice` is AGPL-3.0-ONLY and
# the table said -or-later -- materially different grants -- through two documentation audits (#87,
# #88) and a version bump (#167) that edited that very row without looking one cell to the left
# (#171). Reading is what failed; so this reads the tarball, which is tracked and needs no network.
# `agpl` is Nextcloud'"'"'s legacy bare string for AGPL v3 or later -- calendar, side_menu and
# epidemiologia still declare it -- so it normalises rather than failing.
# The empty case FAILS: a table that describes no app, or a glob that matches nothing, is not a pass.
check python3 -c '
import glob, re, sys, tarfile, xml.etree.ElementTree as ET
NORM = {"agpl": "AGPL-3.0-or-later", "agpl3": "AGPL-3.0-or-later", "AGPL3": "AGPL-3.0-or-later"}
declarado = {}
for d in sorted(glob.glob("provisioning/apps/*/")):
    app = d.rstrip("/").split("/")[-1]
    tars = glob.glob(d + "*.tar.gz")
    if not tars:
        print(f"{app}: no tarball to read a licence from"); sys.exit(1)
    with tarfile.open(tars[0]) as t:
        info = [n for n in t.getnames() if n.endswith("appinfo/info.xml")]
        if not info:
            print(f"{app}: {tars[0]} carries no appinfo/info.xml"); sys.exit(1)
        x = ET.fromstring(t.extractfile(info[0]).read())
    lic = (x.findtext("licence") or x.findtext("license") or "").strip()
    declarado[app] = NORM.get(lic, lic)
if not declarado:
    print("no vendored app found under provisioning/apps/ -- this check measured nothing"); sys.exit(1)
tabla, col = {}, None
for linea in open("docs/LICENSING.md", encoding="utf-8"):
    celdas = [c.strip() for c in linea.strip().strip("|").split("|")]
    # The column is read from the header, never hard-coded: the Source column also holds
    # backticks, so "the last backticked cell" picks the wrong one, and a column inserted
    # later would silently shift a fixed index onto its neighbour.
    if "SPDX" in celdas: col = celdas.index("SPDX"); continue
    m = re.search(r"NC app `([a-z_]+)`", linea)
    if not m or col is None: continue
    tabla[m.group(1)] = celdas[col].strip("`") if col < len(celdas) else None
if col is None:
    print("docs/LICENSING.md has no SPDX column -- this check measured nothing"); sys.exit(1)
mal = []
for app, lic in sorted(declarado.items()):
    if app not in tabla:
        mal.append(f"{app}: vendored, but docs/LICENSING.md has no row for it")
    elif tabla[app] != lic:
        mal.append(f"{app}: info.xml says {lic}, docs/LICENSING.md says {tabla[app]}")
if mal:
    print("\n".join(mal)); sys.exit(1)'
# Every service must come back after the host reboots. Read from the RESOLVED config rather than
# grepped: two of them take the policy from the shared anchor, and a service added later must not
# be able to arrive without one — the person who would notice a stack that stayed down is a CESFAM
# administrator with no reason to know `make up`.
check python3 -c '
import json, subprocess, sys
config = json.loads(subprocess.run(["docker", "compose", "config", "--format", "json"],
                                   capture_output=True, text=True, check=True).stdout)
missing = sorted(name for name, service in config["services"].items() if not service.get("restart"))
if missing:
    print("no restart policy: " + ", ".join(missing))
    sys.exit(1)'
# A clinic must never be installed with the secrets this repository publishes. env-init.sh generates
# all four, so a placeholder survives only a hand-copy of the template — which is what somebody does
# when `make setup` refuses because .env is already there. Behavioural, and driven from
# .env.example: the template is what defines a placeholder, so this cannot rot when one is reworded.
check bash -c '
  . scripts/env.sh
  require_real_secrets || exit 1
  shipped() { grep "^$1=" .env.example | cut -d= -f2-; }
  for key in NEXTCLOUD_ADMIN_PASSWORD POSTGRES_PASSWORD OFFICE_JWT_SECRET FIXTURE_USER_PASSWORD; do
    ( export "$key=$(shipped "$key")"; require_real_secrets 2>/dev/null ) && exit 1
  done
  # And a value that CARRIES the marker without EQUALING the template byte for byte. That is
  # what a quoted placeholder becomes once the loader in env.sh strips its quotes, and what a
  # `$$` one becomes once it undoes the escape — both conventions .env.example already uses,
  # at line 21 and lines 5-6. The equality test this replaced let exactly this through: the
  # gate failed OPEN, silently, and a clinic would install with a published secret.
  ( export NEXTCLOUD_ADMIN_PASSWORD="\"$(shipped NEXTCLOUD_ADMIN_PASSWORD)\""; require_real_secrets 2>/dev/null ) && exit 1
  exit 0'
# #143: ensure_aia_intermediate must not read "could not ask" as "not imported" — that re-imports a
# certificate already in the bundle, which is a write on a provisioned instance and reddens
# seed-idempotent intermittently, here and in cleanboot. Behavioural, not a grep for the fix: occ is
# stubbed to fail the way a busy container fails, and the assertion is which branch the guard takes.
# Two cases, and the second exists because the first fix broke a clean install: phases run under
# `set -e`, so "certificate absent" — a legitimate non-zero — must not kill the phase. Only cleanboot
# saw it, because a machine that already holds both certificates never takes the absent branch.
check bash -c '
  . provisioning/lib.sh
  # Every "the phase must survive this" assertion goes through here, and none of them may
  # be written `( set -e … ) || exit 1`: bash propagates the tested-context of a `||` into
  # the subshell, so errexit is suppressed inside it and the assertion tests nothing.
  # Two of these guards were written that way and were silently inert. Capture the status.
  survives() {
    ( set -e -o pipefail; ensure_aia_intermediate example.test >/dev/null 2>&1 )
    [ $? -eq 0 ] || exit 1
  }
  docker() { [[ "$*" == *s_client* ]] && echo "http://secure.globalsign.com/cacert/ca.crt"; return 0; }
  occ() { return 1; }                     # cannot answer -> skip, never import
  ensure_aia_intermediate example.test 2>&1 | grep -q "could not read the certificate list" || exit 1
  occ() { echo "[]"; }                    # answers "absent", under errexit -> must survive
  survives
  # Offline: the handshake itself fails. The stub used to return 0 for everything, so this
  # branch was invisible to the gate — and a change that made the phase FATAL without a
  # network passed it. Every failure in this helper is a warning by design (lib.sh:579).
  docker() { [[ "$*" == *s_client* ]] && return 1; return 0; }
  ensure_aia_intermediate example.test 2>&1 | grep -q "no CA-Issuers pointer" || exit 1
  survives
  # A leaf past the pipe buffer. Splitting the handshake with `head -1` closed the pipe on line
  # two, so the writer took SIGPIPE and the assignment returned 141 — fatal under pipefail. The
  # leaf is as big as the remote host cares to make it, and every stub above emits a few bytes,
  # which is exactly why the gate could not see it.
  docker() {
    [[ "$*" == *s_client* ]] && { echo "http://secure.globalsign.com/cacert/ca.crt"; echo; printf "%*s" 200000 ""; echo; }
    return 0
  }
  survives
  # `docker compose cp` fails for the most ordinary reason there is — a container still
  # starting — and it was the one unguarded command left on the path. Fatal, and it took
  # the second host with it, since the phase never got there.
  docker() {
    case "$*" in
      *s_client*) echo "http://secure.globalsign.com/cacert/ca.crt"; echo; echo LEAF ;;
      *cp*) return 1 ;;
      *) echo PEM ;;
    esac
    return 0
  }
  survives
  # Valid JSON of the wrong shape raises on `.get`, not on `load`. Uncaught that exits 1,
  # which this function reads as "absent" and answers with the re-import #143 exists to
  # prevent — a WRITE on a provisioned instance. It must read as unreadable instead, and
  # an empty list must still mean absent or the guard has swallowed the real answer too.
  docker() { case "$*" in *s_client*) echo "http://x.test/ca.crt"; echo; echo LEAF ;; *) echo PEM ;; esac; return 0; }
  for shape in "{\"a\":1}" "\"x\"" "[1,2]"; do
    occ() { echo "$shape"; }
    ensure_aia_intermediate example.test 2>&1 | grep -q "unreadable" || exit 1
  done
  # And every status that is not 0 or 1 is a non-answer too. The case listed only 0 and 2,
  # so a python3 the kernel kills — 137 — fell through to "absent" and re-imported.
  python3() { return 137; }
  occ() { echo "[]"; }
  ensure_aia_intermediate example.test 2>&1 | grep -q "unreadable" || exit 1
  unset -f python3
  # The positive control, last: an empty list really does mean absent, and if the guards
  # above have swallowed that too they have swallowed the answer along with the non-answers.
  ensure_aia_intermediate example.test 2>&1 | grep -q "imported ca.pem" || exit 1'
# The other half of the WRITES meta-gate, and the half it cannot express: an alternative must match
# the WRITE line of a helper and NOT its noop line. `certs:` is the pair that proves it — the write
# says "certs: imported X for Y", the noop says "certs: X already imported", and an unanchored
# ` imported` matches both, which would fail a second seed that did nothing. Asserted rather than
# commented because the anchor is one character away from being deleted as noise.
check python3 -c '
import re, sys
src = ""
for line in open("scripts/seed-idempotent.sh", encoding="utf-8"):
    if line.startswith("WRITES="):
        src = line.split("=", 1)[1].strip().strip("\x27\"")
write = "    certs: imported gsgccr6 for www.ispch.gob.cl"
noop  = "    certs: gsgccr6 already imported"
hit = lambda s: any(re.search(a, s) for a in src.split("|"))
if not hit(write):
    print("WRITES no longer matches the cert import — a re-import would report PASS"); sys.exit(1)
if hit(noop):
    print("WRITES matches the cert NOOP line — every second seed would fail"); sys.exit(1)'
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
# Regression guard (#39): a `set -e` subshell's status must not be consumed in a conditional
# context — bash suppresses errexit inside it, so what reads as a guard runs on and reports
# success. Two shapes, because the second is the one that shipped:
#   - something TESTS it from the left: `if (`, `while (`, `&& (`. Matched on what PRECEDES
#     the `(` rather than by listing keywords — nothing but whitespace may.
#   - something tests it from the right: `( set -e … ) || exit 1`. This reads exactly like a
#     guard and is not one, and two assertions in THIS file were written that way and
#     asserted nothing across three audit rounds. Which is why the sweep now reads
#     scripts/ too: the original guard looked only at seed.sh, and the defect moved.
# Comments are stripped first, since seed.sh documents the wrong shape on purpose.
# Over `git ls-files`, not a hand-written list of directories: a third copy of that list is a
# third thing to forget, and a sweep that matches nothing passes — which is the very hole the
# lint sweep above was rewritten to close. Python rather than grep because the subshell and the
# `||` that tests it are not always on one line.
check python3 -c '
import re, subprocess, sys

ERREXIT = r"set\s+(-[a-z]*e|-o[ \t]+errexit)"
FROM_THE_LEFT = re.compile(r"\S[ \t]*\(\s*" + ERREXIT)
FROM_THE_RIGHT = re.compile(r"\(\s*" + ERREXIT + r"[^()]*\)[ \t]*(\|\||&&)")

files = subprocess.run(["git", "ls-files", "-z", "*.sh"],
                       capture_output=True, text=True, check=True).stdout.split("\0")
bad = []
for name in filter(None, files):
    with open(name, encoding="utf-8") as handle:
        # Comments are stripped first: seed.sh documents the wrong shape on purpose.
        body = "".join(l for l in handle if not l.lstrip().startswith("#"))
    for hit in FROM_THE_LEFT.finditer(body):
        bad.append(f"{name}: tested from the left — {hit.group(0).strip()!r}")
    for hit in FROM_THE_RIGHT.finditer(body):
        bad.append(f"{name}: tested from the right — the {hit.group(2)} after the subshell")

if bad:
    print("errexit is suppressed in a tested context, so these guard nothing:")
    for line in bad:
        print("  " + line)
    sys.exit(1)'
# Regression guard (ADR-0001): every STATIC asset server.css references must exist on disk. It shipped
# for months declaring four .woff2 files that were never generated, and the TTF fallback swallowed the
# 404s. The COUNT is asserted before the existence loop, and that is the point: `grep | while read`
# runs zero times when grep matches nothing and exits 0, so the guard passed on a file with no themed
# reference at all. Requiring every reference to be a themed absolute path also catches one of four
# drifting, which "at least one" would not.
#
# ONE path is excluded, by exact name and never by pattern: site.css is @import-ed by server.css but
# is GENERATED per install by phase 15 and is not tracked, so a checkout that has never been
# provisioned legitimately does not have it — and server.css declares the fallback that renders the
# product's own name until it does. A `*.css` or directory-wide exclusion here would silently stop
# checking assets added later, which is the exact shape of the bug this guard exists for.
check bash -c '
  css=themes/apsconecta/core/css/server.css
  total=$(grep -oE "url\(\"" "$css" | wc -l)   # the quote matters: server.css says "url()" in prose
  themed=$(grep -oE "url\(\"/themes/apsconecta[^\"]+\"" "$css" | wc -l)
  [ "$total" -ge 1 ] && [ "$total" -eq "$themed" ] || exit 1
  grep -oE "/themes/apsconecta[^\")]+" "$css" | sed "s|^/||" \
    | grep -vFx "themes/apsconecta/core/css/site.css" \
    | while read -r f; do [ -f "$f" ] || exit 1; done'
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
  # The two the theme leans on hardest, and neither was asserted until now: `#header` carries 19
  # rules in server.css and `.logo` eight. A rename upstream does not break the page — it silently
  # un-brands it, which is the whole failure class this block exists for. Measured 2026-08-05: of
  # the 14 upstream selectors the theme depends on, these were the two most used and unguarded.
  #
  # All three layouts, because the header is drawn by all three and the theme scopes rules on
  # `:not(.header-guest)` to tell them apart — losing the id in only one of them is the shape that
  # produced B-012, a rule leaking onto the public share page.
  check docker compose exec -T --user www-data nextcloud sh -c \
    'for t in user guest public; do grep -q "id=\"header\"" "core/templates/layout.$t.php" || exit 1; done'
  check docker compose exec -T --user www-data nextcloud \
    grep -q 'class="logo logo-icon"' core/templates/layout.user.php
  # NOT core: `.cm-logo` belongs to side_menu, a store app. No image digest pins it and an
  # `occ app:update` from the admin UI replaces it in place — the same route that reverts our
  # patches (ADR-0002, smoke.sh check 10). server.css un-hides and widens that element to put the
  # platform lockup in the side menu (#84/#102); if the class moves, the lockup silently vanishes
  # and nothing else in the suite would notice.
  check docker compose exec -T --user www-data nextcloud \
    grep -rq "cm-logo" custom_apps/side_menu/js/
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

# The AIA URI is read out of a REMOTE certificate over an unverified handshake, so it is
# attacker-chosen input that used to be interpolated into a `sh -c` string. The strip that
# looked like a mitigation (`tr -d '[:space:]'`) is not one: a payload needs no whitespace.
check bash -c '
  source provisioning/lib.sh
  q=$(printf "\047")
  aia_is_safe "https://ca.example.org/int.crt"   || exit 1
  aia_is_safe "http://ca.example.org/int.crt"    || exit 1
  aia_is_safe ""                                 && exit 1
  aia_is_safe "file:///etc/passwd"               && exit 1
  aia_is_safe "https://x.org/a;id>/tmp/pwned;"   && exit 1
  aia_is_safe "https://x.org/a${q}b"             && exit 1
  aia_is_safe "https://x.org/\$(id)"             && exit 1
  aia_is_safe "https://x.org/a b"                && exit 1
  # A LINE-anchored match would let this through: the first line is clean.
  aia_is_safe "$(printf "https://ok.example.org/a\n;id")" && exit 1
  # The two pointers this actually follows in production. Nothing else pins them, and
  # refusing a legal one silently kills the feeds the whole function exists to keep.
  aia_is_safe "http://secure.globalsign.com/cacert/gsgccr6alphasslca2025.crt" || exit 1
  aia_is_safe "http://secure.globalsign.com/cacert/gsrsaovsslca2018.crt"      || exit 1
  # Legal AIA forms a tighter set would have refused (AD CS emits %20).
  aia_is_safe "http://ca.example.org/a%20b.crt" || exit 1
  aia_is_safe "http://ca.example.org/a+b.crt"   || exit 1
  aia_is_safe "HTTP://ca.example.org/a.crt"     || exit 1
  aia_is_safe "http://ca.example.org/a.crt?id=7" || exit 1
  # Length is a safety property here, not tidiness: every character is legal, and the
  # value goes on to be an argv entry and a path component. At 128KB `basename` cannot
  # exec at all, which under the phase errexit is fatal — measured rc 126.
  aia_is_safe "http://ca.example.org/$(printf "a%.0s" $(seq 1 200000)).crt" && exit 1
  # `[A-Za-z]` is a range, and a range collates: under es_CL.UTF-8 — the locale a Chilean
  # dev runs — an accented byte falls inside it, so the allowlist read narrower than it was.
  aia_is_safe "http://ca.example.org/café.crt" && exit 1
  exit 0'
# scripts/deis.py writes sites/<slug>/site.sh and provisioning/seed.sh SOURCES it, so every value
# it emits is shell syntax unless it is quoted. It was not: five register fields went into the file
# inside double quotes, raw. Six values in the shipped register carry a `"` or a backtick, and the
# two failure modes are different sizes of bad — DEIS 113314's address holds a backtick, which is a
# syntax error that kills the phase loop, while DEIS 201079's name holds quotes, which parses CLEAN,
# runs `Juan` as a command and leaves SITE_NOMBRE EMPTY. A clinic provisioned with no name, silently.
#
# Behavioural, and over the WHOLE register rather than the six known-bad rows: the register is
# regenerated from DEIS by `--snapshot`, so tomorrow's hostile value is one nobody has seen. Every
# row is emitted, sourced by a real bash, and compared byte-for-byte with what the CSV holds — one
# bash process for all of them, because 2655 forks is a gate nobody would keep.
#
# `bash -n` alone would not catch it: the DEIS 201079 shape passes a syntax check and still loses
# the value. The round trip is the assertion.
check python3 -c '
import csv, glob, re, subprocess, sys, os
sys.path.insert(0, "scripts")
import deis

register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))
if len(rows) < 100:
    print("register looks truncated: " + str(len(rows)) + " rows"); sys.exit(1)

FIELDS = {"SITE_NOMBRE": "nombre", "SITE_DIRECCION": "direccion",
          "SITE_COMUNA": "comuna", "SITE_SERVICIO_SALUD": "servicio_salud",
          "SITE_COMUNA_CUT": "comuna_codigo"}

script = ["set -u"]
for row in rows:
    script.append(deis.block(row, "gate"))
    for var in FIELDS:
        script.append("printf \"%s\\n\" \"$" + var + "\"")
# On stdin, not argv: 2655 blocks is past ARG_MAX and bash never starts.
out = subprocess.run(["bash"], input="\n".join(script), capture_output=True, text=True)
if out.returncode != 0:
    print("sourcing the generated identity blocks failed: " + out.stderr.strip()[:300]); sys.exit(1)

got = out.stdout.split("\n")
bad = []
for i, row in enumerate(rows):
    for j, (var, field) in enumerate(FIELDS.items()):
        want, have = row[field], got[i * len(FIELDS) + j]
        if want != have:
            bad.append("DEIS " + row["codigo"] + " " + var + ": wrote " + repr(want) + ", bash read " + repr(have))
if bad:
    print("values the generated site.sh does not round-trip (" + str(len(bad)) + "):")
    for line in bad[:5]:
        print("  " + line)
    sys.exit(1)
# The CUT parity half: territorio'"'"'s Comuna::of() accepts exactly five digits, and a register
# value that missed that shape would disarm the import door silently on every install — the
# phase writes whatever the register says. Wrong-shaped CUTs are a register defect, and this
# is where it goes red instead.
bad_cut = [r["codigo"] for r in rows if not re.fullmatch(r"[0-9]{5}", r["comuna_codigo"])]
if bad_cut:
    print("comuna_codigo values Comuna::of() would refuse (not 5 digits) — a phase 16 write"
          " of any of these silently disarms the import door: " + ", ".join(bad_cut[:5]))
    sys.exit(1)'

# The café case above is behavioural, and load-bearing only under a COLLATING locale — which a
# Chilean dev has and GitHub's runners do not, defaulting to C.UTF-8 where that range refuses `é`
# anyway. So CI stays green on a revert, and CI is the only mechanical gate (AGENTS.md). This is
# the half CI can see. A grep for the fix, deliberately: where it runs, the behaviour is not
# observable at all, and a check that cannot fail there is worse than one that admits what it is.
check grep -q "local LC_ALL=C" provisioning/lib.sh

# --- gate: the tree stays establishment-agnostic (ADR-0013, generalized from the 114302 grep) ---
# Shape-based, not literal: the pilot's residue was a hardcoded `deis.py` call in CI's fixture and steering
# examples in docs. A literal grep on one clinic's code is the pilot's number all over again — the next
# clinic's code passes it. The SHAPE is the contract: no tracked file may hand deis.py a DEIS
# code. Only the register CSVs are excluded — they ARE the codes, by design — and dated history
# is scrubbed (slice 5), so nothing else gets a pass. git grep, not grep -r: tracked files only,
# so a developer's sites/<slug>/site.sh (untracked, generated) never trips it. The shape lives in
# ONE exported variable so the self-test below red-tests the same bytes this check runs — and the
# planted literal is ASSEMBLED at run time (%s + a fabricated code), because a literal here would
# itself be a tracked hit and the gate would trip on its own detector test forever.
AGNOSTIC_SHAPE='deis\.py [0-9]{4,6}'
export AGNOSTIC_SHAPE
check bash -c '
  hits=$(git grep -nE "$AGNOSTIC_SHAPE" -- . ":(exclude)sites/establecimientos-deis-*.csv" 2>/dev/null || true)
  [ -z "$hits" ] || { printf "establishment-agnostic gate — tracked files naming a DEIS code:\n%s\n" "$hits" >&2; exit 1; }'
# The negative half: the detector must detect, and must not fire on a clean line. Same shape
# variable, fabricated corpus, run-time-assembled plant.
check bash -c '
  tmp=$(mktemp); trap "rm -f $tmp" EXIT
  printf "run: scripts/deis.py %s --new x\nclean line, no code\n" 999999 > "$tmp"
  grep -nE "$AGNOSTIC_SHAPE" "$tmp" >/dev/null || { echo "agnostic detector: planted literal went undetected" >&2; exit 1; }
  printf "nothing here at all\n" | grep -nE "$AGNOSTIC_SHAPE" >/dev/null && { echo "agnostic detector: false positive on a clean line" >&2; exit 1; }
  exit 0'

# --- gate: sites/ ships the register and NOTHING else ------------------------------------
# The register CSVs are tracked under sites/ beside generated site trees that .gitignore keeps
# out by DIRECTORY — which stops nothing from `git add -f sites/x/site.sh` landing a real site
# record (identity, teams, folders, ACL — a clinic's whole shape) in the public repo. The list
# comes from git ls-files (sites/-PREFIXED paths), piped; the filter is a function so the
# self-test exercises the same bytes. The register is a FLOOR, not an option: an empty listing
# (register deleted, glob renamed) is the empty-glob-goes-green class — red, not green.
sites_register_only() {  # sites/-prefixed file list on stdin; exit 0 = only register CSVs, >=1
  local list n bad
  # Captured ONCE: two greps over one stdin would race — the first consumes the stream and the
  # second reads an exhausted pipe, outputs nothing, and the intruder check goes green vacuously
  # (caught by sanity-running the fence against the real repo, not by review).
  list=$(cat)
  n=$(printf "%s\n" "$list" | grep -cE "^sites/establecimientos-deis-[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv$" || true)
  [ "$n" -ge 1 ] || { printf "no register CSV tracked under sites/ — the register is the floor\n" >&2; return 1; }
  bad=$(printf "%s\n" "$list" | grep -vE "^sites/establecimientos-deis-[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv$" || true)
  [ -z "$bad" ] || { printf "unexpected tracked files under sites/:\n%s\n" "$bad" >&2; return 1; }
}
export -f sites_register_only
check bash -c 'git ls-files sites/ | sites_register_only'
# Negative half, fabricated lists through the same function: a site.sh must be flagged, an
# empty listing must be flagged, the register alone must pass.
check bash -c '
  printf "sites/establecimientos-deis-2026-07-23.csv\nsites/x/site.sh\n" | sites_register_only \
    && { echo "sites gate: a tracked site.sh was not flagged" >&2; exit 1; }
  printf "" | sites_register_only && { echo "sites gate: an empty listing went green" >&2; exit 1; }
  printf "sites/establecimientos-deis-2026-07-23.csv\n" | sites_register_only'

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
