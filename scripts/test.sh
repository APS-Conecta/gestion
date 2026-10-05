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
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh dev/*.sh host/*.sh tests/*/*.sh; do
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
# installs a clinic from nothing, its site placed at sites/<DEIS>/site.sh, and linting it is correct — it is
# real shell that a real install sources. Demanding the two lists MATCH failed there and only there,
# which is the worst shape a gate can have: green on every developer's machine, red only in CI.
# What actually matters is that nothing TRACKED escapes the sweep, so subtract and require empty.
check bash -c '
  [ -z "$(comm -23 <(git ls-files "*.sh" | sort) \
                   <(ls scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh dev/*.sh host/*.sh tests/*/*.sh 2>/dev/null | sort))" ]'
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
# --- gate (L5 S4): the vendored map libraries are the pinned bytes ---------------------------------
# The Centro pane's engine is three files copied byte-identical from territorio's node_modules
# (docs/LICENSING.md §3). Vendored bytes are the one diff a reviewer reads as "just assets":
# territorio upgrades, a re-vendor misses a file, an editor "fixes" a minified line — and the
# installer's map changes with no gate the eye can catch. The image-digests pair-pin discipline,
# applied to vendored files: each must exist and hash to its pin. The negative half mutates one
# byte of a copy — a gate that cannot go red is not a gate (A-010).
check python3 -c '
import hashlib, os, sys, tempfile
PINS = {
    "themes/apsconecta/core/mapa/leaflet.js":
        "db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a",
    "themes/apsconecta/core/mapa/leaflet.css":
        "a7837102824184820dfa198d1ebcd109ff6d0ff9a2672a074b9a1b4d147d04c6",
    "themes/apsconecta/core/mapa/protomaps-leaflet.js":
        "26af014f7b1af308ec120b791cff76657bb9c3383633b52033e6edf9e5e4cdb5",
}
def distinta(corpus):   # the first path whose bytes are not its pin, or None
    for ruta, pin in corpus.items():
        with open(ruta, "rb") as fh:
            if hashlib.sha256(fh.read()).hexdigest() != pin:
                return ruta
    return None
real = distinta(PINS)
with tempfile.TemporaryDirectory() as tmp:
    mutada = os.path.join(tmp, "leaflet.css")
    with open("themes/apsconecta/core/mapa/leaflet.css", "rb") as src:
        datos = bytearray(src.read())
    datos[100] ^= 1
    with open(mutada, "wb") as dst:
        dst.write(datos)
    drill = distinta({**PINS, mutada: PINS["themes/apsconecta/core/mapa/leaflet.css"]})
if real is not None:
    print("the vendored map libraries are not the pinned bytes: " + real)
if drill != mutada:
    print("the mutation drill passed — the gate could not see a changed byte")
sys.exit(0 if real is None and drill == mutada else 1)'
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
# Sources env.sh first since the docker-exec port (slice 2): lib.sh's transport now rides
# nc_exec(), and lib.sh's own REQUIRES contract names env.sh — this gate was quietly exempt
# because occ() and docker() were both stubbed, which covered every external call the old
# transport made. The REAL seam running into the stubbed docker() is the stronger gate: a seam
# that misparsed its own options would turn this red, not just the seed.
check bash -c '
  . scripts/env.sh
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
  # `docker cp` fails for the most ordinary reason there is — a container still
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
# R22: the installer's own CA, on an install by IP. Phase 07 imports it into Nextcloud's own bundle
# once; a domain install mounts no such file and gets no call at all; a container or a list that
# cannot be asked is a non-answer (#143), never an absence; and a failed import fails the phase — an install by IP that
# does not trust its own address is broken. Behavioural, through the real seam, under errexit.
installer_ca_cases() (
  grep -qx "ensure_installer_ca" provisioning/phases/07-certs.sh || { echo "installer CA: phase 07 does not call it" >&2; exit 1; }
  log="$(mktemp)"; trap 'rm -f "$log"' EXIT
  ca=/usr/local/share/ca-certificates/aps-conecta-ca.crt
  ca_run() {  # HAS LIST IMP — a fresh bash, so errexit holds (check's `if` suppresses it in here)
    : > "$log"
    out="$(HAS="$1" LIST="$2" IMP="$3" LOG="$log" CA="$ca" bash -e -o pipefail -c '
      . scripts/env.sh; . provisioning/lib.sh
      nc_exec() {   # the probe: words on stdout; "err" is docker exec failing as for a stopped container
        [ "$1 $2 $3 $5 $6" = "-- sh -c _ $CA" ] || return 2
        case "$HAS" in 1) echo yes ;; 0) echo no ;; *) return 1 ;; esac
      }
      occ() {
        printf "%s\n" "$*" >> "$LOG"
        case "$1" in
          security:certificates) [ "$LIST" != fail ] && printf "%s" "$LIST" ;;
          security:certificates:import) return "$IMP" ;;
        esac
      }
      ensure_installer_ca' 2>&1)"; rc=$?
  }
  imports() { grep -cx "security:certificates:import $ca" "$log"; }
  ca_run 0 '[]' 0
  [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$log" ] || { echo "installer CA: a domain install was touched: $out" >&2; exit 1; }
  ca_run err '[]' 0
  [ "$rc" = 0 ] && [[ "$out" == *"could not ask the container for aps-conecta-ca.crt"* ]] && [ ! -s "$log" ] \
    || { echo "installer CA: a container that could not be asked was read as a domain install: $out" >&2; exit 1; }
  ca_run 1 '[{"name":"aps-conecta-ca.crt"}]' 0
  [ "$rc" = 0 ] && [[ "$out" == *"aps-conecta-ca.crt already imported"* ]] && [ "$(imports)" = 0 ] \
    || { echo "installer CA: imported again: $out" >&2; exit 1; }
  for list in fail '{"a":1}' '[1,2]'; do
    ca_run 1 "$list" 0
    [ "$rc" = 0 ] && [[ "$out" == *"could not read the certificate list"* ]] && [ "$(imports)" = 0 ] \
      || { echo "installer CA: a non-answer ($list) was read as absent: $out" >&2; exit 1; }
  done
  ca_run 1 '[]' 1
  [ "$rc" != 0 ] && [[ "$out" == *"import of aps-conecta-ca.crt FAILED"* ]] || { echo "installer CA: a failed import passed: $out" >&2; exit 1; }
  ca_run 1 '[]' 0   # the positive control, last
  [ "$rc" = 0 ] && [[ "$out" == *"certs: imported aps-conecta-ca.crt for this server's own address"* ]] && [ "$(imports)" = 1 ] \
    || { echo "installer CA: an absent CA was not imported: $out" >&2; exit 1; }
)
check installer_ca_cases
# R22: phase 14's install-by-IP block, extracted from the phase and run under its errexit. An
# address in overwrite.cli.url (the entrypoint's, every boot) sends both server-to-server legs
# inside the wizard's network; a domain or the compose stack writes nothing — a domain install keeps
# its public legs (B-019) — and a value that cannot be read is said, never taken for a domain (B-014).
office_by_ip_cases() {
  local block out aio pub want
  block="$(sed -n '/^# --- by IP (R22)/,/^# --- end by IP ---$/p' provisioning/phases/14-office.sh)"
  [ -n "$block" ] || { echo "office by IP: block not found in 14-office.sh" >&2; return 1; }
  while IFS='|' read -r aio pub want; do
    out="$(AIO="$aio" PUB="$pub" bash -e -o pipefail -c '
      aio=$AIO
      conf_load() { :; }
      conf_get() { [ "$PUB" != fail ] && printf "%s\n" "$PUB"; }
      app_config_set() { printf "SET %s %s %s\n" "$@"; }
      log() { printf "LOG %s\n" "$*"; }
      eval "$1"' _ "$block" 2>&1)" || { echo "office by IP: the block failed for $aio|$pub: $out" >&2; return 1; }
    case "$want" in
      internal) [ "$out" = "SET eurooffice DocumentServerInternalUrl http://aps-conecta-eurooffice/
SET eurooffice StorageUrl http://aps-conecta-apache.nextcloud-aio:23973/" ] ;;
      none) [ -z "$out" ] ;;
      said) [ "$out" = "LOG AIO: overwrite.cli.url could not be read — the office's internal URLs left as they are" ] ;;
    esac || { echo "office by IP: $aio|$pub expected $want, got: $out" >&2; return 1; }
  done <<'CASES'
1|https://10.0.0.5/|internal
1|https://192.168.1.50/|internal
1|https://clinica.example/|none
1|https://10.0.0.5.example/|none
1|fail|said
0|https://10.0.0.5/|none
CASES
}
check office_by_ip_cases
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
# env.sh sourced in THIS process (not just inside the #143 gate's subshell) because the ported
# vendor-block calls nc_exec directly — without the source every check below fails with
# "command not found" while the stack is up and detected (live-measured on the probe, P5).
. scripts/env.sh
if is_aio; then
  check nc_exec --user www-data -- \
    grep -q 'class="section development-notice"' /var/www/html/apps/settings/templates/settings/personal/development.notice.php
  check nc_exec --user www-data -- \
    grep -q "open-reasons-use-nextcloud-pdf" /var/www/html/apps/settings/templates/settings/personal/development.notice.php
  # The home affordance rests on `<a id="nextcloud">` in the authenticated layout: server.css reserves
  # 68px for the mark, hangs the home icon off ::before and the clinic name off ::after, and the click
  # works only because that element is the home link.
  # It scopes on the ELEMENT TYPE because the PUBLIC SHARE header
  # renders the same id as `<div class="header-appname">` with a share title inside it — an
  # unscoped rule put the 224px padding and a 200px logo on the page external recipients see.
  # So assert both shapes: authenticated is an anchor, public is not. If upstream renames the id,
  # or ever makes the two the same element, every rule stops applying (or starts leaking) with
  # the header still rendering — silently, which is why this is a gate and not a comment.
  check nc_exec --user www-data -- sh -c \
    'grep -B3 -- '"'"'id="nextcloud"'"'"' /var/www/html/core/templates/layout.user.php | grep -q -- "<a "'
  check nc_exec --user www-data -- \
    grep -qE '<div id="nextcloud" class="header-appname"' /var/www/html/core/templates/layout.public.php
  # Same silent-failure shape as B-008: server.css hangs the clinic name off `.login-form__headline`.
  check nc_exec --user www-data -- \
    grep -q "login-form__headline" /var/www/html/dist/core-login.js
  # The two the theme leans on hardest, and neither was asserted until now: `#header` carries 19
  # rules in server.css and `.logo` eight. A rename upstream does not break the page — it silently
  # un-brands it, which is the whole failure class this block exists for. Measured 2026-08-05: of
  # the 14 upstream selectors the theme depends on, these were the two most used and unguarded.
  #
  # All three layouts, because the header is drawn by all three and the theme scopes rules on
  # `:not(.header-guest)` to tell them apart — losing the id in only one of them is the shape that
  # produced B-012, a rule leaking onto the public share page.
  check nc_exec --user www-data -- sh -c \
    'for t in user guest public; do grep -q "id=\"header\"" "/var/www/html/core/templates/layout.$t.php" || exit 1; done'
  check nc_exec --user www-data -- \
    grep -q 'class="logo logo-icon"' /var/www/html/core/templates/layout.user.php
  # NOT core: `.cm-logo` belongs to side_menu, a store app. No image digest pins it and an
  # `occ app:update` from the admin UI replaces it in place — the same route that reverts our
  # patches (ADR-0002, smoke.sh check 10). server.css un-hides and widens that element to put the
  # platform lockup in the side menu (#84/#102); if the class moves, the lockup silently vanishes
  # and nothing else in the suite would notice.
  check nc_exec --user www-data -- \
    grep -rq "cm-logo" /var/www/html/custom_apps/side_menu/js/
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
  check nc_exec --user www-data -- sh -c \
    'test "$(grep -r --include="*.php" -e "->printPage()" /var/www/html/lib /var/www/html/core /var/www/html/index.php | wc -l)" -eq 7'
  # And that core still READS what guest.css declares. Both variables carry a fallback to Nextcloud's
  # own art inside core's guest.css, so an upstream rename does not break the page — it silently
  # restores the vendor logo and backdrop on exactly the screens nobody visits on a good day.
  check nc_exec --user www-data -- sh -c \
    'grep -q -- "var(--image-logo" /var/www/html/core/css/guest.css && grep -q -- "var(--image-background" /var/www/html/core/css/guest.css'
else
  echo "  skipped: upstream vendor-block checks (need the AIO stack — aps-conecta-nextcloud)"
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
          "SITE_COMUNA_CUT": "comuna_codigo", "SITE_LON": "longitud", "SITE_LAT": "latitud"}

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
# The register's coordinates have a WRITER (deis.py --coordenadas) that runs by hand once per
# MINSAL release, so this is where it is proven. On a scratch register of three real rows —
# 201079's quotes and 113314's backtick among them — it must refuse a source that misses an
# establishment and one whose latitude or longitude is not plain degrees, leaving the file untouched;
# then append the two columns as published (text, never re-rounded) with every original line kept
# byte for byte; then rewrite the same bytes when run again.
check python3 -c '
import csv, glob, os, shutil, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
point = {"110485": ("-33.976637", "-71.468749"), "201079": ("-51.728207", "-72.482647"),
         "113314": ("-33.56136", "-70.67469")}
rows = [r for r in csv.DictReader(open(register, encoding="utf-8")) if r["codigo"] in point]
if len(rows) != 3:
    print("the three probe rows are not in the register -- this check measured nothing"); sys.exit(1)
def source(path, codes, bad=None):
    feats = []
    for c in codes:
        lat, lon = point[c]
        if c == "113314" and bad:
            lat, lon = bad
        feats.append("{\"type\":\"Feature\",\"geometry\":null,\"properties\":{\"cod_vig\":" + c
                     + ".0,\"latitud\":" + lat + ",\"longitud\":" + lon + "}}")
    open(path, "w", encoding="utf-8").write("{\"type\":\"FeatureCollection\",\"features\":[" + ",".join(feats) + "]}")
def run(path):
    try:
        deis.coordinates_from(path)
        return None
    except SystemExit as e:
        return str(e)
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE); os.makedirs(os.path.join(tmp, "sites"))
    reg = os.path.join(tmp, "sites", "establecimientos-deis-2099-01-01.csv")
    with open(reg, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh); w.writerow(deis.COLUMNS); w.writerows([r[k] for k in deis.COLUMNS] for r in rows)
    before = open(reg, "rb").read()
    gj = os.path.join(tmp, "src.geojson")
    source(gj, ["110485", "201079"]); short = run(gj)
    source(gj, list(point), bad=("\"-33.5; id\"", "-70.67469")); hostile = run(gj)
    source(gj, list(point), bad=("-33.56136", "-70.6e1")); hostile_lon = run(gj)
    untouched = open(reg, "rb").read() == before
    source(gj, list(point)); full = run(gj)
    after = open(reg, "rb").read()
    again = run(gj) is None and open(reg, "rb").read() == after
    out = list(csv.DictReader(open(reg, encoding="utf-8")))
finally:
    shutil.rmtree(tmp)
old, new = before.split(b"\r\n"), after.split(b"\r\n")
fails = []
if not short or "113314" not in short: fails.append("a source missing 113314 was not refused: " + repr(short))
if not hostile or "113314" not in hostile: fails.append("a latitude that is not plain degrees was not refused: " + repr(hostile))
if not hostile_lon or "113314" not in hostile_lon: fails.append("a longitude that is not plain degrees was not refused: " + repr(hostile_lon))
if not untouched: fails.append("a refused run changed the register")
if full is not None: fails.append("the full source was refused: " + full)
if not out or tuple(out[0]) != deis.COLUMNS + deis.COORDS: fails.append("the header is not the ten columns, then latitud,longitud")
if any((r["latitud"], r["longitud"]) != point[r["codigo"]] for r in out): fails.append("coordinates not written as published")
if len(old) != len(new) or not all(n.startswith(o + b",") for o, n in zip(old, new) if o): fails.append("an original line changed")
if not again: fails.append("a second run did not rewrite the same bytes")
if fails:
    print("\n".join(fails)); sys.exit(1)'
# Every establishment the installer offers carries its official point, inside the box the basemap
# covers (a21): the point is where the Centro map starts and what SITE_LON/SITE_LAT copy. The box is
# read from scripts/refresh-basemap.sh, the file that decides what the basemap holds, so a point the
# map could not show reds here and not at a clinic. A --snapshot that skipped --coordenadas is the
# realistic way to get here — snapshot_from writes the ten columns only.
check python3 -c '
import csv, glob, re, sys
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))
m = re.search(r"^BBOX=\"\$\{BBOX:-([-0-9.,]+)\}\"$", open("scripts/refresh-basemap.sh", encoding="utf-8").read(), re.M)
if len(rows) < 100 or not m:
    print("register truncated, or no BBOX default in scripts/refresh-basemap.sh -- this check measured nothing"); sys.exit(1)
w, s, e, n = map(float, m.group(1).split(","))
bad = [r["codigo"] for r in rows
       if not all(deis.DEGREES.fullmatch(r.get(k) or "") for k in deis.COORDS)
       or not (w <= float(r["longitud"]) <= e and s <= float(r["latitud"]) <= n)]
if bad:
    print(str(len(bad)) + " register rows without a plain-degree point inside the basemap box "
          + m.group(1) + ": " + ", ".join(bad[:5])); sys.exit(1)'
# A --snapshot whose points never came is the newest file, so every reader would take it and
# block() would die on a KeyError inside the installer. load() stops instead, naming both ways
# out, and a refused --coordenadas on it says how to step back to the register before it. On a
# scratch tree: an older register with points, then a fresh ten-column snapshot of the same rows.
check python3 -c '
import csv, glob, os, shutil, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))[:3]
if len(rows) != 3 or not all(r.get("latitud") for r in rows):
    print("no register rows with points to build the scratch tree -- this check measured nothing"); sys.exit(1)
def stop(fn, *a):
    try:
        fn(*a); return None
    except SystemExit as e:
        return str(e)
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE); os.makedirs(os.path.join(tmp, "sites"))
    for name, cols in (("2099-01-01", deis.COLUMNS + deis.COORDS), ("2099-02-01", deis.COLUMNS)):
        with open(os.path.join(tmp, "sites", "establecimientos-deis-" + name + ".csv"), "w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh); w.writerow(cols); w.writerows([r[k] for k in cols] for r in rows)
    loaded = stop(deis.load)
    gj = os.path.join(tmp, "empty.geojson")
    open(gj, "w", encoding="utf-8").write("{\"type\":\"FeatureCollection\",\"features\":[]}")
    refused = stop(deis.coordinates_from, gj)
    os.remove(os.path.join(tmp, "sites", "establecimientos-deis-2099-02-01.csv"))
    back = deis.load()
    os.remove(os.path.join(tmp, "sites", "establecimientos-deis-2099-01-01.csv"))
    with open(os.path.join(tmp, "sites", "establecimientos-deis-2099-03-01.csv"), "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh); w.writerow(deis.COLUMNS); w.writerows([r[k] for k in deis.COLUMNS] for r in rows)
    alone = stop(deis.load)
finally:
    shutil.rmtree(tmp)
fails = []
if not loaded or "--coordenadas" not in loaded or "fall back to establecimientos-deis-2099-01-01.csv" not in loaded:
    fails.append("load() on a snapshot without points did not stop with both ways out: " + repr(loaded))
if not refused or "remove establecimientos-deis-2099-02-01.csv to fall back" not in refused:
    fails.append("a refused --coordenadas on a fresh snapshot did not say how to step back: " + repr(refused))
if back[0] != "2099-01-01" or len(back[1]) != 3:
    fails.append("removing the snapshot did not hand the register back: " + repr(back[0]))
if not alone or "fall back" in alone:
    fails.append("with no register before it, the fix hint must not offer a fallback: " + repr(alone))
if fails:
    print("\n".join(fails)); sys.exit(1)'
# The provisionador self-test's fixture rows end with their official points, copied by hand from
# the source (B-035). Tied to the register here, so a transposed digit — or a register refresh
# that moves one of the four — reds instead of leaving the fixture quietly elsewhere.
check python3 -c '
import ast, csv, glob, io, re, sys
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
point = {r["codigo"]: (r["latitud"], r["longitud"]) for r in csv.DictReader(open(register, encoding="utf-8"))}
m = re.search(r"\n    fixture_rows = (\[.*?\n    \])\n", open("scripts/provisionador.py", encoding="utf-8").read(), re.S)
fixture = [next(csv.reader(io.StringIO(s))) for s in ast.literal_eval(m.group(1))] if m else []
if len(fixture) < 4:
    print("no fixture_rows found in scripts/provisionador.py -- this check measured nothing"); sys.exit(1)
bad = [f[0] + " " + repr(tuple(f[-2:])) + " vs " + repr(point.get(f[0])) for f in fixture if tuple(f[-2:]) != point.get(f[0])]
if bad:
    print("fixture points that are not the register s: " + "; ".join(bad)); sys.exit(1)'
# The welcome declaration has a WRITER (deis.py) and a READER (seed.sh's guard + phase 41). This
# proves the writer's output is what the reader expects: written to a scratch tree (write_site
# refuses an existing sites/<name>/), sourced by a real bash, the rows read back — and `equipos`
# absent, because that is the product decision the default carries (review L0-01).
check python3 -c '
import csv, glob, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
row = next(csv.DictReader(open(register, encoding="utf-8")))
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE)
    deis.write_site(row, "gate", "probe", sectors=[], programs=[])
    out = subprocess.run(["bash", "-c", "set -u; . sites/probe/site.sh; printf \"%s\\n\" \"${SITE_WELCOME[@]}\""],
                         cwd=tmp, capture_output=True, text=True)
finally:
    shutil.rmtree(tmp)
if out.returncode != 0:
    print("sourcing the written site file failed: " + out.stderr.strip()[:300]); sys.exit(1)
rows = out.stdout.split()
if rows != ["noticias|wall", "vida-cesfam|", "documentos|wall"]:
    print("SITE_WELCOME default is not the three declared rows: " + repr(rows)); sys.exit(1)'
# The reporter's welcome arm lists live sections with a fragment that runs INSIDE the container
# (`sh -c` under nc_exec) — the parser class divergence.sh's header warns turns a report silently
# green when it rots. Read out of the script (not restated) and run against a scratch groupfolder
# tree: a folder that owns its JSON is a section, images/ and a JSON-less folder are not.
check python3 -c '
import os, re, subprocess, sys, tempfile
src = open("scripts/divergence.sh", encoding="utf-8").read()
m = re.search(r"# --- welcome sections.*?nc_exec --user www-data -- sh -c \x27(.*?)\x27 sh ", src, re.S)
if not m:
    print("welcome arm listing fragment not found in scripts/divergence.sh"); sys.exit(1)
frag = m.group(1)
root = tempfile.mkdtemp(); es = os.path.join(root, "__groupfolders", "20", "files", "es")
for d in ("noticias", "images", "_resources", "campanas"): os.makedirs(os.path.join(es, d))
open(os.path.join(es, "noticias", "noticias.json"), "w").write("{}")
open(os.path.join(es, "images", "x.svg"), "w").write("<svg/>")
out = subprocess.run(["sh", "-c", frag, "sh", root, "20"], capture_output=True, text=True)
if out.returncode != 0 or out.stdout.split() != ["noticias"]:
    print("welcome arm listing fragment answered " + repr(out.stdout) + " (want exactly noticias): " + out.stderr[:200]); sys.exit(1)
out = subprocess.run(["sh", "-c", frag, "sh", root, "99"], capture_output=True, text=True)
if out.returncode != 0 or out.stdout.strip() != "":
    print("welcome arm listing fragment must answer nothing, exit 0, when the folder is absent"); sys.exit(1)'
# The renderer is the seam's whole "declare, don't hard-code" (review M3) in one file, so it is
# gated the way the identity round-trip is: real values in, the produced tree inspected, and the
# refusals SEEDED — a renderer that cannot go red is not a gate. The register holds names with
# quotes and backslashes (the deis round trip above), so one identity value carries both.
check python3 -c '
import json, os, shlex, subprocess, sys, tempfile
R = "provisioning/intravox/render.py"; L = "provisioning/intravox/es"
base = {"SITE_NOMBRE": "Centro de Salud Familiar Prueba", "SITE_NOMBRE_CORTO": "CESFAM Prueba",
        "SITE_DIRECCION": "Calle 1", "SITE_COMUNA": "Comuna", "SITE_SERVICIO_SALUD": "SS Prueba", "IV_MOUNT": "Intranet",
        "SITE_FOLDERS": "Transversal\nSectores/Sector 1\nProgramas/X\nUnidades/OIRS", "SITE_SUBFOLDERS": "Protocolos\nFlujogramas",
        "SITE_TEAMS": "sector-1|Sector 1\nprog-x|Programa X", "SITE_WELCOME": "noticias|wall\nvida-cesfam|\ndocumentos|wall"}
def run(env):
    # The values sit in bash as PLAIN shell variables (what seed.sh has after sourcing the site
    # file — nothing exported) and only the phase-shaped `env NAME="$NAME" …` line hands them to
    # python. A name that line forgets is invisible to render.py, exactly as on a real seed; a
    # gate that filled os.environ directly could never see that.
    stage = tempfile.mkdtemp() + "/s"
    shell = "; ".join(k + "=" + shlex.quote(v) for k, v in env.items())
    forward = " ".join(k + "=\"$" + k + "\"" for k in env)
    p = subprocess.run(["bash", "-c", shell + "; env " + forward + " python3 " + R + " " + L + " " + stage],
                       env={k: v for k, v in os.environ.items() if not k.startswith("SITE_")}, capture_output=True, text=True)
    return p, stage
p, stage = run(base)
if p.returncode != 0: print("default render failed: " + p.stderr.strip()); sys.exit(1)
if os.path.isdir(stage + "/equipos"): print("default renders equipos — L0-01 says it ships without"); sys.exit(1)
nav = json.load(open(stage + "/navigation.json"))
if [i["id"] for i in nav["items"]] != ["nav_inicio", "nav_noticias", "nav_vida_cesfam", "nav_documentos"]:
    print("nav is not Inicio + the declared sections in order: " + str([i["id"] for i in nav["items"]])); sys.exit(1)
docs = open(stage + "/documentos/documentos.json").read()
if "/Transversal/Protocolos" not in docs or "/Transversal/Documentación" in docs:
    print("Documentos links are not the declared SITE_SUBFOLDERS"); sys.exit(1)
if "__" in open(stage + "/home.json").read(): print("home.json shipped a raw placeholder"); sys.exit(1)
p, stage = run({**base, "IV_MOUNT": "Sitio Web"})
for rel in ["noticias/bienvenida/bienvenida.json", "noticias/como-publicar/como-publicar.json"]:
    page = open(stage + "/" + rel, encoding="utf-8").read()
    if "__IV_MOUNT__" in page or "Sitio Web" not in page or "Intranet" in page:
        print(rel + " does not name the storage folder IV_MOUNT names (ADR-0020)"); sys.exit(1)
p, stage = run({**base, "SITE_WELCOME": base["SITE_WELCOME"] + "\nequipos|wall"})
if p.returncode != 0: print("equipos render failed: " + p.stderr.strip()); sys.exit(1)
hub = json.load(open(stage + "/equipos/equipos.json"))
links = [w for r in hub["layout"]["rows"] for w in r["widgets"] if w["type"] == "links"][0]["items"]
if len(links) != 2 or not os.path.isfile(stage + "/equipos/sector-1/sector-1.json"):
    print("equipos hub is not exactly the two declared teams"); sys.exit(1)
if "/Sectores/Sector 1" not in open(stage + "/equipos/sector-1/sector-1.json").read():
    print("team page does not link its own declared folder"); sys.exit(1)
p, stage = run({**base, "SITE_WELCOME": base["SITE_WELCOME"] + "\nequipos|wall", "SITE_TEAMS": "role-oirs|OIRS",
                "SITE_NOMBRE_CORTO": "CESFAM \"Dr. X\" \\ Sur"})
if p.returncode != 0: print("role row / hostile identity render failed: " + p.stderr.strip()[-300:]); sys.exit(1)
if "?dir=/Unidades/OIRS" not in json.dumps(json.load(open(stage + "/equipos/role-oirs/role-oirs.json")), ensure_ascii=False):
    print("a role row does not link the declared folder named after it (Unidades/OIRS)"); sys.exit(1)
hero = json.load(open(stage + "/home.json"))["layout"]["rows"][0]["widgets"][1]["content"]
if hero != "CESFAM \"Dr. X\" \\ Sur": print("an identity value with a quote and a backslash did not round-trip: " + repr(hero)); sys.exit(1)
for bad, why in [({"SITE_WELCOME": "noticias|fortress"}, "unknown flag"),
                 ({"SITE_WELCOME": "campanas|"}, "undeclared library section"),
                 ({"SITE_FOLDERS": "Sectores/Sector 1"}, "Files link to an undeclared root"),
                 ({"IV_MOUNT": "a/b"}, "a storage folder name with a slash"),
                 ({"SITE_WELCOME": base["SITE_WELCOME"] + "\nequipos|wall", "SITE_TEAMS": "sector-9|Sector 9"},
                  "a team whose folder the site does not declare")]:
    p, _ = run({**base, **bad})
    if p.returncode == 0 or "FATAL:" not in p.stderr:
        print("render.py accepted " + why); sys.exit(1)'
# The wall flag is the only thing the seam hands the engine about protection (review L4-01):
# per page, from the declaration, never a folder rule. Rendered and inspected, both ways. A wall
# is the section's STRUCTURE (owner decision 2026-09-28): the hub, a seeded page with sub-pages
# (noticias/avisos), every team page; the seeded example posts stay ordinary, deletable pages.
check python3 -c '
import json, os, shlex, subprocess, sys, tempfile
R = "provisioning/intravox/render.py"; L = "provisioning/intravox/es"
base = {"SITE_NOMBRE": "Centro de Salud Familiar Prueba", "SITE_NOMBRE_CORTO": "CESFAM Prueba",
        "SITE_DIRECCION": "Calle 1", "SITE_COMUNA": "Comuna", "SITE_SERVICIO_SALUD": "SS Prueba", "IV_MOUNT": "Intranet",
        "SITE_FOLDERS": "Transversal\nSectores/Sector 1\nProgramas/X", "SITE_SUBFOLDERS": "Protocolos\nFlujogramas",
        "SITE_TEAMS": "sector-1|Sector 1\nprog-x|Programa X",
        "SITE_WELCOME": "noticias|wall\nvida-cesfam|\ndocumentos|wall\nequipos|wall"}
def run(env):
    stage = tempfile.mkdtemp() + "/s"
    shell = "; ".join(k + "=" + shlex.quote(v) for k, v in env.items())
    forward = " ".join(k + "=\"$" + k + "\"" for k in env)
    p = subprocess.run(["bash", "-c", shell + "; env " + forward + " python3 " + R + " " + L + " " + stage],
                       env={k: v for k, v in os.environ.items() if not k.startswith("SITE_")}, capture_output=True, text=True)
    return p, stage
def walled(stage, rel):
    return json.load(open(stage + "/" + rel)).get("protected") is True
p, stage = run(base)
if p.returncode != 0: print("render failed: " + p.stderr.strip()); sys.exit(1)
for rel in ["noticias/noticias.json", "noticias/avisos/avisos.json", "documentos/documentos.json",
            "equipos/equipos.json", "equipos/sector-1/sector-1.json", "equipos/prog-x/prog-x.json"]:
    if not walled(stage, rel): print("wall page not stamped: " + rel); sys.exit(1)
for rel in ["vida-cesfam/vida-cesfam.json", "home.json", "noticias/bienvenida/bienvenida.json",
            "noticias/como-publicar/como-publicar.json", "noticias/avisos/aviso-ejemplo/aviso-ejemplo.json"]:
    if walled(stage, rel): print("editable page stamped as a wall: " + rel); sys.exit(1)
p, stage = run({**base, "SITE_WELCOME": "noticias|\nvida-cesfam|wall\ndocumentos|wall"})
if p.returncode != 0: print("render failed: " + p.stderr.strip()); sys.exit(1)
if walled(stage, "noticias/noticias.json") or not walled(stage, "vida-cesfam/vida-cesfam.json"):
    print("the wall follows the library, not the declaration"); sys.exit(1)'
# The mount name has ONE seam-side home (env.sh) and ONE engine-side reader (appconfig
# groupfolder_name, ADR-0020). Both readers here take it from env.sh; the sandbox stub derives the
# folder row from the appconfig row — so a rename is one line, and a literal left behind is a mount
# the seed cannot find. Seeded: the stub arm is exercised with no row, one row, and a re-set (the
# config:app:set arm appends, so the LAST write must win, as it does in Nextcloud).
check python3 -c '
import re, sys
env = open("scripts/env.sh", encoding="utf-8").read()
if len(re.findall(r"^IV_MOUNT=", env, re.M)) != 1:
    print("scripts/env.sh must define IV_MOUNT exactly once"); sys.exit(1)
for f in ["provisioning/phases/41-intravox.sh", "scripts/divergence.sh"]:
    src = open(f, encoding="utf-8").read()
    if "$IV_MOUNT" not in src:
        print(f + " does not read IV_MOUNT"); sys.exit(1)
    if re.search(r"==\s*\"IntraVox\"|\"IntraVox\"\)", src):
        print(f + " still looks a mount up by the literal"); sys.exit(1)
stub = open("scripts/provisionador.py", encoding="utf-8").read()
m = re.search(r"elif \"intravox:setup\" in args:\n(.*?)\nelif ", stub, re.S)
if not m or "groupfolder_name" not in m.group(1):
    print("provisionador: the intravox:setup arm does not derive the folder name from the appconfig row"); sys.exit(1)
arm = "\n".join(l[4:] if l.startswith("    ") else l for l in m.group(1).splitlines())
cfg = lambda v: ["appconfig", "intravox", "groupfolder_name", v]
for rows, want in (([cfg("Intranet")], "Intranet"), ([], "IntraVox"), ([cfg("Intranet"), cfg("Sitio")], "Sitio")):
    ns = {"rows": list(rows), "args": ["occ", "intravox:setup"], "save": lambda r: None}
    exec(arm, ns)
    if [r[1] for r in ns["rows"] if r[0] == "folder"] != [want]:
        print("provisionador setup arm: expected one folder row named " + want + ", got " + repr(ns["rows"])); sys.exit(1)'
# Phase 41's refusal is the only thing between an install whose folder carries another name and
# a second, empty mount (ADR-0020). Extracted from the phase's own bytes (a named function: the
# stub needs quotes the bash -c wrapper cannot nest) and run against a stubbed occ, both ways:
# a fresh install, the runbook's end state and an explicit override pass; the lab's unrenamed
# folder, a half-done runbook, a later IV_MOUNT change, a dict-shaped listing and a name the
# engine refuses all FATAL.
iv_mount_guard_cases() {
  local guard want mounts told iv out rc
  guard="$(sed -n '/^case "\$IV_MOUNT" in$/,/^occ config:app:set intravox groupfolder_name/p' provisioning/phases/41-intravox.sh | sed '$d')"
  [ -n "$guard" ] || { echo "iv mount guard: block not found in 41-intravox.sh" >&2; return 1; }
  while IFS='|' read -r want mounts told iv; do
    out="$(MOUNTS_JSON="$mounts" TOLD="$told" IV_MOUNT="$iv" bash -c '
      occ() { case "$1" in
        groupfolders:list) printf "%s" "$MOUNTS_JSON" ;;
        config:app:get) [ -n "$TOLD" ] && printf "%s\n" "$TOLD" ;;
      esac; }
      eval "$1"; echo PASSED' _ "$guard" 2>&1)"; rc=$?
    case "$want" in
      pass) [ "$rc" = 0 ] && [ "${out##*$'\n'}" = PASSED ] || { echo "iv mount guard: expected pass for mounts=$mounts told=$told IV_MOUNT=$iv, got: $out" >&2; return 1; } ;;
      fatal) [ "$rc" != 0 ] && [[ "$out" == FATAL:* ]] || { echo "iv mount guard: expected FATAL for mounts=$mounts told=$told IV_MOUNT=$iv, got: $out" >&2; return 1; } ;;
    esac
  done <<'CASES'
pass|[]||Intranet
pass|[{"id":1,"mount_point":"Intranet"}]|Intranet|Intranet
pass|[{"id":1,"mount_point":"IntraVox"}]||IntraVox
pass|[{"id":1,"mount_point":"Transversal"}]||Intranet
fatal|[{"id":1,"mount_point":"IntraVox"}]||Intranet
fatal|[{"id":1,"mount_point":"IntraVox"}]|Intranet|Intranet
fatal|[{"id":1,"mount_point":"Intranet"}]|Intranet|Sitio Web
fatal|{"1":{"id":1,"mount_point":"IntraVox"}}||Intranet
fatal|[]||a/b
fatal|[]||   
CASES
}
check iv_mount_guard_cases
# divergence.sh's side of the same rule: a live storage root under another name (the default, or
# the name the engine was last told) is reported as a rename, never with the generic delete
# advice; an unrelated undeclared folder still gets that advice. Extracted from the script.
iv_mount_divergence_cases() {
  local loop out
  loop="$(sed -n '/^iv_told="\$(occ config:app:get intravox groupfolder_name/,/^done <<< "\$live_folders"$/p' scripts/divergence.sh)"
  [ -n "$loop" ] || { echo "divergence mount loop not found" >&2; return 1; }
  out="$(IV_MOUNT="Sitio Web" TOLD=Intranet bash -c '
    occ() { [ "$1" = config:app:get ] && [ -n "$TOLD" ] && printf "%s\n" "$TOLD"; }
    note() { printf "NOTE %s\n" "$*"; }
    declared_folders="$(printf "%s\n" Transversal "$IV_MOUNT")"
    live_folders="$(printf "1\tIntranet\n2\tIntraVox\n3\tViejo\n4\tTransversal\n")"
    eval "$1"' _ "$loop" 2>&1)"
  printf '%s\n' "$out" | grep -q "^NOTE la carpeta compartida 'Intranet' guarda la portada.*cámbiele el nombre una vez" \
    || { echo "divergence: the told name is not reported as a rename: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "^NOTE la carpeta compartida 'IntraVox' guarda la portada" \
    || { echo "divergence: the default name is not reported as a rename: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "^NOTE la carpeta compartida 'Viejo' existe pero no está en SITE_FOLDERS" \
    || { echo "divergence: an unrelated folder lost the generic note: $out" >&2; return 1; }
  [ "$(printf '%s\n' "$out" | grep -c "groupfolders:delete [12]\b")" = 0 ] \
    || { echo "divergence: a storage root was offered for deletion: $out" >&2; return 1; }
}
check iv_mount_divergence_cases
# Estadística's establishment, both halves, extracted from the scripts: phase 16 writes the three
# keys only behind a six-digit SITE_DEIS (anything else the app reads as no establishment, in
# silence), and divergence.sh names each key that differs from the site file — and an occ that
# cannot answer, never as a clean pass.
estadistica_identity_cases() {
  local guard section out rc want deis
  guard="$(sed -n '/^case "\${SITE_DEIS:-}" in$/,/^app_config_set estadistica comuna_cut/p' provisioning/phases/16-app-policy.sh)"
  [ -n "$guard" ] || { echo "estadistica guard: block not found in 16-app-policy.sh" >&2; return 1; }
  while IFS='|' read -r want deis; do
    out="$(SITE=lab SITE_DEIS="$deis" SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 bash -c '
      app_config_set() { printf "SET %s %s %s\n" "$@"; }
      eval "$1"' _ "$guard" 2>&1)"; rc=$?
    case "$want" in
      pass) [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^SET estadistica ')" = 3 ] \
        && printf '%s\n' "$out" | grep -qx "SET estadistica deis_code $deis" \
        || { echo "estadistica guard: expected three writes for SITE_DEIS='$deis', got: $out" >&2; return 1; } ;;
      fatal) [ "$rc" != 0 ] && [[ "$out" == FATAL:* ]] && ! printf '%s\n' "$out" | grep -q '^SET ' \
        || { echo "estadistica guard: expected FATAL and no write for SITE_DEIS='$deis', got: $out" >&2; return 1; } ;;
    esac
  done <<'CASES'
pass|999001
fatal|
fatal|99900
fatal|9990011
fatal|99900a
fatal| 999001
CASES
  section="$(sed -n "/^# --- estadistica's establishment/,/^fi$/p" scripts/divergence.sh)"
  [ -n "$section" ] || { echo "estadistica divergence: section not found in divergence.sh" >&2; return 1; }
  out="$(SITE=lab SITE_DEIS=999001 SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 bash -c '
    occ() { case "$1" in status) return 0 ;; config:app:get) case "$3" in deis_code) echo 999001 ;; establishment_type) echo CESFAM ;; comuna_cut) echo 09999 ;; esac ;; esac; }
    note() { printf "NOTE %s\n" "$*"; }
    eval "$1"' _ "$section" 2>&1)"
  [ -z "$out" ] || { echo "estadistica divergence: matching keys were reported: $out" >&2; return 1; }
  out="$(SITE=lab SITE_DEIS=999001 SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 bash -c '
    occ() { case "$1" in status) return 0 ;; config:app:get) [ "$3" = deis_code ] && echo 999002; return 0 ;; esac; }
    note() { printf "NOTE %s\n" "$*"; }
    eval "$1"' _ "$section" 2>&1)"
  printf '%s\n' "$out" | grep -q "^NOTE estadistica deis_code es '999002' pero sites/lab/site.sh dice '999001'" \
    && printf '%s\n' "$out" | grep -q "^NOTE estadistica establishment_type es '<sin valor>' pero sites/lab/site.sh dice 'CESFAM'" \
    && [ "$(printf '%s\n' "$out" | grep -c '^NOTE ')" = 3 ] \
    || { echo "estadistica divergence: a wrong and two unset keys were not each reported: $out" >&2; return 1; }
  out="$(SITE=lab SITE_DEIS=999001 bash -c '
    occ() { return 1; }
    note() { printf "NOTE %s\n" "$*"; }
    eval "$1"' _ "$section" 2>&1)"
  printf '%s\n' "$out" | grep -q "^NOTE no se pudieron leer las claves del establecimiento en estadistica" \
    || { echo "estadistica divergence: an occ that did not answer passed: $out" >&2; return 1; }
}
check estadistica_identity_cases

# Territorio's tile_url — the third extracted-block test over this phase (office by IP at
# 14-office, estadistica's establishment above, now this — Q17, org review L5-S3). Phase 16's
# three branches carried ONE string grep of coverage (a21's `/tiles/` clause below): the
# unreadable-ocu arm — leave-as-is, and Q9 makes it SAY the stale value it leaves — and the
# non-AIO arm (the blank write that falls territorio back to the OSM raster) were exercised by
# nothing anywhere. Same shape as office_by_ip: the block between the phase's own markers, run
# under errexit with the five helpers stubbed. The exact-string arms make the LOG line's wording
# a contract: the stale value is in the message («…»), never implied.
territorio_tile_url_cases() {
  local block out
  block="$(sed -n "/^# --- territorio's tile_url (L5-S3)/,/^# --- end territorio's tile_url ---$/p" provisioning/phases/16-app-policy.sh)"
  [ -n "$block" ] || { echo "tile_url: block not found in 16-app-policy.sh" >&2; return 1; }
  while IFS='|' read -r aio ocu stale want; do
    out="$(AIO="$aio" OCU="$ocu" STALE="$stale" bash -e -o pipefail -c '
      is_aio() { [ "$AIO" = 1 ]; }
      conf_load() { :; }
      conf_get() { case "$1" in system) printf "%s\n" "$OCU" ;; app) printf "%s\n" "$STALE" ;; esac; }
      app_config_set() { printf "SET %s %s %s\n" "$@"; }
      log() { printf "LOG %s\n" "$*"; }
      eval "$1"' _ "$block" 2>&1)" || { echo "tile_url: the block failed under errexit for aio=$aio ocu='$ocu': $out" >&2; return 1; }
    case "$want" in
      derived)     [ "$out" = "SET territorio tile_url https://10.0.0.5/tiles/chile.pmtiles" ] ;;
      left)        [ "$out" = "LOG AIO: overwrite.cli.url could not be read — territorio's tile_url left as it is («https://vieja.example/tiles/chile.pmtiles»)" ] ;;
      left-empty)  [ "$out" = "LOG AIO: overwrite.cli.url could not be read — territorio's tile_url left as it is («sin valor»)" ] ;;
      blank)       [ "$out" = "SET territorio tile_url " ] ;;  # trailing space: the empty VALUE — the write itself is the assertion
    esac || { echo "tile_url: aio=$aio ocu='$ocu' stale='$stale' expected $want, got: $out" >&2; return 1; }
  done <<'CASES'
1|https://10.0.0.5/|https://vieja.example/tiles/chile.pmtiles|derived
1||https://vieja.example/tiles/chile.pmtiles|left
1|||left-empty
0|||blank
CASES
}
check territorio_tile_url_cases

# The café case above is behavioural, and load-bearing only under a COLLATING locale — which a
# Chilean dev has and GitHub's runners do not, defaulting to C.UTF-8 where that range refuses `é`
# anyway. So CI stays green on a revert, and CI is the only mechanical gate (AGENTS.md). This is
# the half CI can see. A grep for the fix, deliberately: where it runs, the behaviour is not
# observable at all, and a check that cannot fail there is worse than one that admits what it is.
check grep -q "local LC_ALL=C" provisioning/lib.sh

# --- gate: the tree stays establishment-agnostic (ADR-0013, generalized from the one-code grep) ---
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

# --- a21 (L5): the map is the suite's own route — the separate tiles server is gone -------------
# The grep is a21's own clause, with the pattern assembled without its literals
# ("nginx:alp""ine|TILES_""PORT|:80""84"): a21 covers scripts/ too, and a gate that spelled its
# own banned tokens would be its own hit. tiles.nginx.conf gone, no nginx pin, port or knob left
# anywhere the map used to need one, and phase 16 pointing at /tiles/.
check bash -c '
  test ! -e tiles.nginx.conf \
    && ! git grep -qE "nginx:alp""ine|TILES_""PORT|:80""84" -- .env.example compose.yaml host scripts provisioning \
    && grep -q "/tiles/" provisioning/phases/16-app-policy.sh'

# --- gate (org review L5-S3, I7): the map-folder default — five literals that must agree ---------
# /srv/aps-conecta is spelled in five places because each site legitimately owns its own fallback
# SHAPE: the installer's TILES_ARCHIVE, tiles.sh's standalone TILES_HOME, the testbed's
# APS_TILES_DIR env, env.sh's dotenv fixture, and refresh-basemap's DEST (the serving directory
# S3 gave it — a literal this pack itself introduced is exactly the drift site the gate exists to
# pin). Single-sourcing was weighed and rejected (tiles.sh's standalone fallback survives it), so
# the discipline is image-digests' pair-pin generalized to five: each site's default read out of
# the file, and they must all say the same path. Shape-anchored, not line-numbered — the dd8a1db
# hermeticity pin (host/aps-conecta's self-test literals at :1411 and the grep -qF cross-check at
# :2342) are pins ON PURPOSE and do not match; the emitters they pin do. EXACTLY ONE match per
# site is required: a renamed variable or a deleted fixture is the empty-glob-goes-green class,
# red here by name. The negative half runs the same validator over fabricated corpora — one
# drifted site, one missing site — because a gate that cannot go red is not a gate. (On a tree
# where Slice 1's DEST has not landed, this reds by name on refresh-basemap — by design; this
# slice commits after that one.)
check python3 -c '
import re, sys
SITES = [
    ("host/tiles.sh",              r"^TILES_HOME=\"\$\{TILES_HOME:-([^\"}\n]+)\}\"$"),
    ("host/aps-conecta",           r"^TILES_ARCHIVE=\"\$\{TILES_HOME:-([^\"}\n]+)\}/tiles/chile\.pmtiles\"$"),
    ("scripts/aio-testbed.sh",     r"--env \"APS_TILES_DIR=\$\(dirname \"\$\{TILES_HOME:-([^\"}\n]+)\}/tiles/chile\.pmtiles\"\)\""),
    ("scripts/env.sh",             r"^TILES_HOME=(/[^\"=\s]+)$"),
    ("scripts/refresh-basemap.sh", r"^DEST=\"\$\{DEST:-([^\"}\n]+)/tiles/chile\.pmtiles\}\"$"),
]
def defaults(corpus):
    got, errs = {}, []
    for site, pat in SITES:
        hits = re.findall(pat, corpus.get(site, ""), re.M)
        if len(hits) != 1:
            errs.append(site + ": " + str(len(hits)) + " matches for its map-folder default (need exactly 1)")
        else:
            got[site] = hits[0]
    return got, errs
def broken(got, errs):
    return bool(errs) or len(set(got.values())) != 1
real = {s: open(s, encoding="utf-8").read() for s, _ in SITES}
got, errs = defaults(real)
if broken(got, errs):
    print("the map-folder default is not one value across the five sites that spell it:")
    for e in errs: print("  " + e)
    for s, v in sorted(got.items()): print("  " + s + " = " + v)
    sys.exit(1)
fab = {
    "host/tiles.sh":              "TILES_HOME=\"${TILES_HOME:-/srv/prueba}\"\n",
    "host/aps-conecta":           "TILES_ARCHIVE=\"${TILES_HOME:-/srv/prueba}/tiles/chile.pmtiles\"\n",
    "scripts/aio-testbed.sh":     "    --env \"APS_TILES_DIR=$(dirname \"${TILES_HOME:-/srv/prueba}/tiles/chile.pmtiles\")\" \\\n",
    "scripts/env.sh":             "TILES_HOME=/srv/prueba\n",
    "scripts/refresh-basemap.sh": "DEST=\"${DEST:-/srv/prueba/tiles/chile.pmtiles}\"\n",
}
if broken(*defaults(fab)):
    print("the fabricated agreeing corpus failed"); sys.exit(1)
fab["scripts/env.sh"] = "TILES_HOME=/srv/otro\n"
if not broken(*defaults(fab)):
    print("a drifted literal passed — the disagreement the gate exists for went unseen"); sys.exit(1)
del fab["scripts/aio-testbed.sh"]
if not broken(*defaults(fab)):
    print("a missing site passed — the empty-glob-goes-green class is back"); sys.exit(1)
print("ok")'

# --- the dump + uninstall detectors red-test themselves (docker daemon, no stack) -------------
if docker info >/dev/null 2>&1; then
  check bash scripts/db-dump.sh --self-test
  check bash scripts/uninstall.sh --self-test
else
  echo "  skipped: dump/uninstall self-tests (no docker daemon)"
fi

# --- office-smoke's DS pairing pattern: extracted from its source, proven both directions -------
# (the LC_ALL precedent — where a static gate cannot observe the behaviour, assert the fix's
# presence; here the extracted regex can also be behaviorally tested, so both.)
# (P36, implement-time) slice 20 replaced office-smoke's DS_VERSION_PATTERN variable with the
# ver-parse + 9.3.* case pin; the detector below extracts the parse from the script's own bytes
# (a named function — the extraction needs quotes the bash -c wrapper cannot nest) and proves
# BOTH directions through the same case arm the script carries.
ds_pairing_detect() {
  local parse v v2
  parse="$(grep -m1 -oF "sed -n 's/.* version \([0-9][0-9.]*\) is successfully connected.*/\1/p'" scripts/office-smoke.sh \
    | sed 's/^sed -n .//; s/.$//')"
  [ -n "$parse" ] || { echo "DS version parse not found in office-smoke.sh" >&2; return 1; }
  v="$(printf 'Document server https://x/ version 9.3.4.37 is successfully connected\n' | sed -n "$parse")"
  [ "$v" = "9.3.4.37" ] || { echo "DS pairing detector: missed the right version" >&2; return 1; }
  case "$v" in 9.3.*) ;; *) echo "DS pairing detector: the case rejects the right version" >&2; return 1;; esac
  v2="$(printf 'Document server https://x/ version 9.2.1.5 is successfully connected\n' | sed -n "$parse")"
  case "$v2" in 9.3.*) echo "DS pairing detector: the case accepts the wrong version" >&2; return 1;; *) :;; esac
}
check ds_pairing_detect

# --- gate: the data manifest and the comuna reference describe each other ---------------------
# packages.json pins the masters; comunas-deis.csv is the coding authority the recipes validate
# against. One python block holds the validator ONCE and runs it on the real corpus AND on three
# fabricated defect corpora (single-sourced: the self-test exercises the same bytes the real check
# runs — slice 4's locked lesson). The row-count expectation is READ FROM THE MANIFEST, not
# restated: a future ODS refresh (a 347th comuna) is one manifest edit + one CSV regen, and this
# gate follows — never three uncoordinated literals.
check python3 -c '
import json, re, sys
def validate(rows, why, expect):
    if len(rows) != expect: print(why + ": " + str(len(rows)) + " rows, expected " + str(expect)); sys.exit(1)
    for cut, glosa in rows:
        if not re.fullmatch(r"[0-9]{5}", cut): print(why + ": CUT " + repr(cut) + " is not 5 digits"); sys.exit(1)
        if "\xa0" in glosa: print(why + ": glosa of " + cut + " carries a non-breaking space"); sys.exit(1)
    if not any(c == "99999" for c, _ in rows): print(why + ": the 99999/Ignorada sentinel row is gone"); sys.exit(1)
m = json.load(open("provisioning/data/packages.json"))
assert m["masters"], "no masters in the data manifest"
for x in m["masters"]:
    for k in ("id", "origin", "sha256", "records"):
        if not x.get(k): print("master " + x.get("id", "?") + ": missing " + k); sys.exit(1)
expect = m["comuna_reference"]["records"]
real = [l.rstrip("\n").split(",", 1) for l in open("provisioning/data/comunas-deis.csv", encoding="utf-8")][1:]
validate(real, "comunas-deis.csv", expect)
# The negative half — three corpora, one defect each, through the SAME validator:
try:
    validate([("1234", "Cuatro"), ("99999", "Ignorada"), ("12345", "Santiago")], "4-digit CUT", expect)
except SystemExit: pass
else: print("fabricated 4-digit corpus passed"); sys.exit(1)
try:
    validate([("99999", "Ignorada"), ("12345", "NBSP\xa0glosa")], "NBSP glosa", 2)
except SystemExit: pass
else: print("fabricated NBSP corpus passed"); sys.exit(1)
try:
    validate([("12345", "Santiago"), ("13101", "Providencia")], "missing sentinel", 2)
except SystemExit: pass
else: print("fabricated sentinel-less corpus passed"); sys.exit(1)
print("ok")'
check bash scripts/comuna-package.sh --self-test

# --- gate: the anchors the AIO wizard links into these docs still resolve ---------------------
# The fork's templates (APS-Conecta/AIO patches 140 and 170) link six sections of the install docs
# by their GitHub anchors. A renamed or renumbered heading breaks those links in every published
# suite image without a word, so the six are a contract: a heading keeps its slug, or an explicit
# <a id="…"></a> carries it. GitHub's slug: lower-case, every character but letters, digits,
# spaces, hyphens and underscores dropped, spaces to hyphens. Same validator on a fabricated doc.
check python3 -c '
import re, sys
ANCLAS = {"docs/INSTALLER.md": ["3-preflight", "7-dns-the-host-must-reach-its-own-domain-d10", "11-backups", "12-troubleshooting"],
          "docs/GUIA-CLINICA.md": ["3-el-asistente-8080", "7-tras-actualizar"]}
def slugs(text):
    text = re.sub(r"^[ \t]*```.*?^[ \t]*```[^\n]*", "", text, flags=re.M | re.S)   # a heading inside a code block is not one
    out = {re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-") for h in re.findall(r"^#{1,6} (.+)$", text, re.M)}
    return out | set(re.findall(r"<a (?:id|name)=\"([^\"]+)\"", text))
def missing(text, want):
    return [a for a in want if a not in slugs(text)]
for doc, want in ANCLAS.items():
    gone = missing(open(doc, encoding="utf-8").read(), want)
    if gone: print(doc + ": the wizard links #" + ", #".join(gone) + " — no heading or <a id> carries it"); sys.exit(1)
if missing("## 3. Preflight checks\n", ["3-preflight"]) != ["3-preflight"]: print("a renamed heading passed"); sys.exit(1)
if missing("```bash\n# 3. Preflight\n```\n", ["3-preflight"]) != ["3-preflight"]: print("a heading inside a code block passed"); sys.exit(1)
if missing("<a id=\"3-preflight\"></a>\n## 2. Preflight\n", ["3-preflight"]): print("an explicit anchor was not read"); sys.exit(1)
print("ok")'

# --- gate: the install by IP's CA guide (R22) — one walkthrough, pointed at where it is -------------
# The console's last lines and step 7 send staff to GUIA §11; the English twin is INSTALLER §14. The
# pointers name the headings that hold the guide, and the two sections carry the same commands, byte
# for byte, and as many bullets — the one walkthrough in two languages. Same validator on drifted pairs.
check python3 -c '
import re, sys
def section(text, head):
    if head not in text: return None
    s = text[text.index(head):]
    end = s.find("\n## ", 1)
    return s if end < 0 else s[:end]
def blocks(text):
    return re.findall(r"^ *```[a-z]*\n(.*?)^ *```", text, re.M | re.S)
def twins(en, es):
    return (en is not None and es is not None and blocks(en) and blocks(en) == blocks(es)
            and len(re.findall(r"^- \*\*", en, re.M)) == len(re.findall(r"^- \*\*", es, re.M)))
en = section(open("docs/INSTALLER.md", encoding="utf-8").read(), "\n## 14. Without a domain: this server\x27s IP\n")
es = section(open("docs/GUIA-CLINICA.md", encoding="utf-8").read(), "\n## 11. Sin dominio: la dirección IP del servidor\n")
if not twins(en, es): print("INSTALLER §14 and GUIA §11 are missing or carry different commands"); sys.exit(1)
if "docs/GUIA-CLINICA.md §11" not in open("host/aps-conecta", encoding="utf-8").read(): print("the console does not point at GUIA §11"); sys.exit(1)
if "(guía, §11)" not in open("scripts/provisionador.py", encoding="utf-8").read(): print("step 7 does not point at GUIA §11"); sys.exit(1)
if twins("## 14. x\n```\na\n```\n", "## 11. y\n```\nb\n```\n"): print("a drifted pair passed"); sys.exit(1)
if twins("## 14. x\n- **A**\n```\na\n```\n", "## 11. y\n```\na\n```\n"): print("a pair missing a bullet passed"); sys.exit(1)
print("ok")'

# --- gate: the suite's containers are aps-conecta-* (the AIO fork's patch 240) ----------------
# The fork renames its 19 sibling containers; the mastercontainer, the nextcloud-aio network and
# compose project and the nextcloud_aio_* volumes keep upstream's names. A sibling spelled the old way
# anywhere gestion talks to the suite misses it without a word: a `docker ps` filter that matches
# nothing reads as «not running», a prefix filter sees only the wizard. So no name, no prefix with the
# old hyphen and no glob of the old prefix survives but the mastercontainer's. git grep exits 1 on no
# match and 128 on error, so only a real search passes; [-*] keeps this line from matching itself.
# CHANGELOG and BUGS are history; the vendored tarballs are not text.
check bash -c 'out="$(git grep -nE "nextcloud-aio[-*]" -- . ":!CHANGELOG.md" ":!BUGS.md" ":!provisioning/apps")"; rc=$?; [ "$rc" -le 1 ] && ! printf "%s\n" "$out" | sed "s/nextcloud-aio-mastercontainer//g" | grep -E "nextcloud-aio[-*]"'

# --- gate: the release manifest's form — every pin present, every category counted -------------
check bash scripts/release-manifest.sh --validate
check bash scripts/release-manifest.sh --self-test

# --- org L5-11/L5-05/L5-12: the provisioning self-tests (hermetic) ----------------------------
# standings.sh: the one uid derivation's fixture parity; env.sh: the loader/compose
# round-trip (skips its docker arm when compose is absent) + the container arms (stub docker);
# usuarios.sh: the frame guards.
check bash provisioning/standings.sh --self-test
check bash scripts/env.sh --self-test
# #197: the template ships no Nextcloud container and no caller restates its default or guards it
# (`:-` `-` `:?` `?`) — env.sh section 3 is the one place it is decided. git grep exits 1 on no
# match and 128 on error, so only a real "none found" passes (a tree without git is red, not green).
# The [R] keeps the pattern from matching this line itself.
check bash -c '! grep -q "^NC_CONTAINER=" .env.example && { git grep -qE "NC_CONTAINE[R]:?[?-]" -- . ":!scripts/env.sh"; [ $? -eq 1 ]; }'
check bash provisioning/usuarios.sh --self-test

echo "== desktop_workspace pin seat (hermetic — unpacks the vendored tarball + applies its patches) =="
# D2 (org plan Phase 8): the vendored app's pins live in gestion, not in upstream's
# absent CI. Needs node always; the PHP arm rides php when present (CI installs it).
if command -v node >/dev/null 2>&1; then
  if bash tests/desktop_workspace/run.sh; then echo "  ok:   desktop_workspace pins"; else echo "  FAIL: desktop_workspace pins"; fail=1; fi
else
  echo "  skipped: desktop_workspace pins (no node on this box)"
fi
echo "== self-tests (hermetic — no docker, no stack) =="
# The Provisionador's own --self-test (slices 14-17: 100 named checks over its stub oracle)
# and the host bundle's (slice 19: 34 — this slice adds the revalidate arm's 2) run everywhere
# test.sh runs — every PR, any box — because neither needs a stack (the slice-14 routing: the
# stub oracle rides --self-test, so the runner needs no docker; cleanboot inherits both through
# its make test). Output is captured, not drowned: a green arm prints its own last line, a red
# one its tail — the #96 lesson, a red log must carry its diagnosis.
st_out="$(python3 scripts/provisionador.py --self-test 2>&1)" \
  && echo "  ok:   provisionador --self-test ($(printf '%s\n' "$st_out" | tail -1))" \
  || { echo "  FAIL: provisionador --self-test"; printf '%s\n' "$st_out" | tail -25; fail=1; }
hb_out="$(bash host/aps-conecta --self-test 2>&1)" \
  && echo "  ok:   host bundle --self-test ($(printf '%s\n' "$hb_out" | tail -1))" \
  || { echo "  FAIL: host bundle --self-test"; printf '%s\n' "$hb_out" | tail -25; fail=1; }
tl_out="$(bash host/tiles.sh --self-test 2>&1)" \
  && echo "  ok:   tiles --self-test ($(printf '%s\n' "$tl_out" | tail -1))" \
  || { echo "  FAIL: tiles --self-test"; printf '%s\n' "$tl_out" | tail -25; fail=1; }
# The basemap builds with nothing of the install around it — no .env, no site, no suite (R47): step 4
# runs before anyone chooses a centre. A stub pmtiles writes a sparse 600 MB archive and reports its
# header, a stub curl finds today's build; every check of the script runs for real, under the
# strictest umask root may have — the archive must still be world-readable, since apache reads it as
# uid 33. A header whose bounds miss Isla de Pascua is refused, and the served archive stays as it was.
check bash -c '
  repo=$PWD; tmp=$(mktemp -d); trap "rm -rf $tmp" EXIT; mkdir -p "$tmp/bin" "$tmp/srv"
  cat > "$tmp/bin/pmtiles" <<"STUB"
#!/usr/bin/env bash
case "$1" in
  extract) printf PMTiles > "$3"; truncate -s 600000000 "$3" ;;
  show) printf "max zoom: 15\nbounds: (long: %s, lat: -56.000000) (long: -66.400000, lat: -17.500000)\n" "${WEST:--110.000000}" ;;
  tile) head -c 2000 /dev/zero ;;
esac
STUB
  printf "#!/usr/bin/env bash\nexit 0\n" > "$tmp/bin/curl"; chmod +x "$tmp/bin/pmtiles" "$tmp/bin/curl"
  build() { (umask 077; cd "$tmp" && env -i PATH="$tmp/bin:/usr/bin:/bin" DEST="$tmp/srv/chile.pmtiles" "$@" bash "$repo/scripts/refresh-basemap.sh"); }
  build >/dev/null 2>&1 && [ "$(stat -c %a "$tmp/srv/chile.pmtiles")" = 644 ] || exit 1
  echo served > "$tmp/srv/chile.pmtiles"
  ! build WEST=-80.000000 >/dev/null 2>&1 && [ "$(cat "$tmp/srv/chile.pmtiles")" = served ]'
mg_out="$(bash scripts/migrate-to-aio.sh --self-test 2>&1)" \
  && echo "  ok:   migrate-to-aio --self-test ($(printf '%s\n' "$mg_out" | tail -1))" \
  || { echo "  FAIL: migrate-to-aio --self-test"; printf '%s\n' "$mg_out" | tail -25; fail=1; }

echo "== smoke (only if a stack is running) =="
if is_aio; then
  # SMOKE_ADMIN_PROBE: check 15, the developer-only admin-settings probe (B-031)
  if SMOKE_ADMIN_PROBE=1 bash scripts/smoke.sh; then echo "  ok:   smoke"; else echo "  FAIL: smoke"; fail=1; fi
else
  echo "  skipped: no running AIO stack (static-only gate)"
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
# The gate and office-smoke's own inspect match the SAME name — the AIO sibling AIO's own
# containers.json pins (aps-conecta-eurooffice), deterministic on every AIO host the way the
# compose project name was on compose — so the two cannot drift. The AIO legs landed with S8
# (slice 20): public-path healthcheck, the DS 9.3.x pin, the image namespaces. A compose dev
# stack reads as skipped here BY DESIGN (the D5 interim: its install and seed stay green through
# NC_CONTAINER; office answers the AIO stack) — the skip is visible, never silent.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aps-conecta-eurooffice; then
  if bash scripts/office-smoke.sh; then echo "  ok:   office-smoke"; else echo "  FAIL: office-smoke"; fail=1; fi
else
  echo "  skipped: no AIO document server (aps-conecta-eurooffice)"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: local gate green"
  exit 0
else
  echo "FAIL: local gate has failures"
  exit 1
fi
