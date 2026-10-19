#!/usr/bin/env bash
# The instalador quality gate, run locally and by .github/workflows/ci.yml. Ported from gestion's
# scripts/test.sh when the host bundle moved: the checks whose subjects moved with it ride along
# verbatim; the checks whose subjects stayed in gestion (the vendored apps, the theme, the DEIS
# register, the compose files, release-manifest, the comuna reference) stay in gestion's own gate.
# Static checks that need no running stack, then the hermetic self-tests of every mover that
# carries one — including the bootstrap's and the package signer's — then the smoke checks when a
# stack is up. Exits non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
linted=0
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh host/*.sh install.sh; do
  [ -e "$s" ] || continue
  linted=$((linted + 1)); check bash -n "$s"
done
# A glob that matches nothing stays literal, `[ -e ]` skips it, and the gate reports only the checks
# it did run — so a renamed directory would silently lint nothing and still print all-ok.
#
# SUBSET, not equality — and NAMESPACE-SCOPED (unchanged by the hard fork, its rationale re-homed):
# instalador's tree carries UPSTREAM's shell (Containers/*/start.sh and friends), and that shell is
# upstream's own to keep — their shellcheck.yml owns it on every push and PR, so this sweep stays
# out of it. Inside the fork's namespaces the doctrine is unchanged: the sweep legitimately lints
# files git has never heard of (a developer's scratch script under scripts/, a site.sh copied in by
# hand while rehearsing a silent install — real shell someone is about to source), so demanding the
# two lists MATCH would be green on every machine and red only in CI. What matters is that nothing
# TRACKED escapes the sweep, so subtract and require empty.
check bash -c '
  [ -z "$(comm -23 <(git ls-files "*.sh" | grep -E "^scripts/|^provisioning/|^host/|^install\.sh$" | sort) \
                   <(ls scripts/*.sh provisioning/*.sh provisioning/phases/*.sh host/*.sh install.sh 2>/dev/null | sort))" ]'
# Same three assertions `ensure_vendored_app` already makes (lib.sh:211-222), moved from seed time to
# PR time. At seed time they run on a CLINIC, during the install — the worst place to learn that a
# tarball and its manifest stopped describing each other, because the operator is mid-install and
# the failure reads as the install being broken. Here it needs no stack, no .env, no clock and no
# network, so it runs in any pull request, including a hotfix opened from a clinic.
# NOT a replacement for the seed-time check: that one guards the bytes that actually get unpacked.
# B-012's other half. A phase's STDOUT IS its contract with the seed-idempotency gate. Redirecting
# `occ` is fine and common (the helper logs afterwards, via `&&`); redirecting a HELPER is what
# blinds it. The function list is read out of lib.sh rather than typed here, so it cannot drift.
check bash -c '
  fns=$(grep -oE "^[a-z_]+\(\)" provisioning/lib.sh | tr -d "()" | sort -u | paste -sd"|" -)
  bad=$(grep -rnE "(^|[;&[:space:]])(\$fns)([[:space:]][^|]*)?>[[:space:]]*/dev/null" \
          provisioning/phases/*.sh provisioning/seed.sh 2>/dev/null || true)
  [ -z "$bad" ] || { printf "%s\n" "$bad" >&2; exit 1; }'

# --- gate: the channel's identity — instalador is the only home the operator is sent to ---------
# The move re-keyed every operator pointer (D13): the bootstrap, the CLI's remedies, the wizard's
# help arms, the units' Documentation lines. Three shapes pin that no gestion-era pointer came
# back:
#   - no gestion repo URL survives in the two operator entry files (the clone era's channel);
#   - the signing key has exactly two committed readers, and they agree (the env.sh lesson):
#     installer.pub's key line and install.sh's embedded SIGNIFY_PUBKEY — package-release.sh reds
#     on a disagreement at tag time; this is the PR-time half, before a tag is ever cut;
#   - no runbook pointer survives with the old docs/ prefix: the runbooks moved to aps/ (D13;
#     gestion's docs/ copies are deleted at the retirement slice), so such a remedy would be a
#     dead pointer in the package an operator actually holds. aps/CHANGELOG.md is dated history
#     and keeps what it said when it said it.
check bash -c '
  for f in host/aps-conecta install.sh; do
    [ "$(grep -c "APS-Conecta/gestion" "$f")" = 0 ] || { echo "$f still names the gestion repo" >&2; exit 1; }
  done'
check bash -c '
  pub="$(sed -n 2p installer.pub)"
  emb="$(sed -n "s/^SIGNIFY_PUBKEY=\"\([^\"]*\)\".*/\1/p" install.sh | head -1)"
  { [ -n "$emb" ] && [ "$pub" = "$emb" ]; } || { echo "installer.pub and install.sh carry different keys" >&2; exit 1; }'
check bash -c '
  hits="$(git grep -nE "docs/(INSTALLER|GUIA-CLINICA)\.md" -- . ":!aps/CHANGELOG.md" 2>/dev/null || true)"
  [ -z "$hits" ] || { printf "runbook pointers still on the old docs/ home:\n%s\n" "$hits" >&2; exit 1; }'

# #143: ensure_aia_intermediate must not read "could not ask" as "not imported" — that re-imports a
# certificate already in the bundle, which is a write on a provisioned instance and reddens
# seed-idempotent intermittently, here and in cleanboot. Behavioural, not a grep for the fix: occ is
# stubbed to fail the way a busy container fails, and the assertion is which branch the guard takes.
# Two cases, and the second exists because the first fix broke a clean install: phases run under
# `set -e`, so "certificate absent" — a legitimate non-zero — must not kill the phase. Only cleanboot
# saw it, because a machine that already holds both certificates never takes the absent branch.
# Sources env.sh first since the docker-exec port: lib.sh's transport now rides nc_exec(), and
# lib.sh's own REQUIRES contract names env.sh. The REAL seam running into the stubbed docker() is
# the stronger gate: a seam that misparsed its own options would turn this red, not just the seed.
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
    [[ "$*" == *s_client* ]] && { echo "http://secure.globalsign.com/cacert/ca.crt"; echo; printf "%*s" 200000 ""; }
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
#     guard and is not one, and two assertions in gestion's file were written that way and
#     asserted nothing across three audit rounds. Which is why the sweep reads the whole tree:
#     the original guard looked only at seed.sh, and the defect moved.
# Comments are stripped first, since seed.sh documents the wrong shape on purpose.
# Over `git ls-files`, not a hand-written list of directories: a third copy of that list is a
# third thing to forget, and a sweep that matches nothing passes — which is the very hole the
# lint sweep above was rewritten to close. Python rather than grep because the subshell and the
# `||` that tests it are not always on one line. The file set is namespace-scoped like the lint
# sweep's: upstream's shell stays out of it — their shellcheck.yml owns those bytes on every push
# and PR.
check python3 -c '
import re, subprocess, sys

ERREXIT = r"set\s+(-[a-z]*e|-o[ \t]+errexit)"
FROM_THE_LEFT = re.compile(r"\S[ \t]*\(\s*" + ERREXIT)
FROM_THE_RIGHT = re.compile(r"\(\s*" + ERREXIT + r"[^()]*\)[ \t]*(\|\||&&)")

tracked = subprocess.run(["git", "ls-files", "-z", "*.sh"],
                         capture_output=True, text=True, check=True).stdout.split("\0")
files = [f for f in tracked if re.match(r"^(scripts|provisioning|host)/", f) or f == "install.sh"]
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
# quotes and backslashes (the deis round trip in gestion's gate), so one identity value carries both.
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

# Territorio's basemap is OpenStreetMap's own tile service (ADR-0021 in that repo), loaded by each
# user's browser: nothing about it is provisioned. Phase 16 used to write a tile_url (the suite's
# /tiles/ archive); it writes none now, and the two keys the app derives its map extent from —
# the comuna's CUT and name — must still land. Behavioural, not a grep: the WHOLE phase runs under
# errexit with its helpers stubbed, once as AIO and once not (the old block branched on that), and
# the assertions are on what it writes. is_aio / conf_load / conf_get are stubbed to a marker so a
# phase that went back to asking how the instance is reached is caught too.
territorio_phase16_cases() {
  local aio out
  for aio in 1 0; do
    out="$(AIO="$aio" SITE=lab SITE_DEIS=999001 SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 SITE_COMUNA="Comuna Prueba" \
      SEED_CTX=1 bash -e -o pipefail -c '
      phase_begin() { :; }; phase_end() { :; }
      app_restrict_to_groups() { :; }; app_disable() { :; }
      is_aio() { echo "ASKED is_aio"; [ "$AIO" = 1 ]; }
      conf_load() { echo "ASKED conf_load"; }
      conf_get() { echo "ASKED conf_get $*"; }
      log() { :; }
      app_config_set() { printf "SET %s %s %s\n" "$@"; }
      . provisioning/phases/16-app-policy.sh' 2>&1)" \
      || { echo "phase 16: failed under errexit for aio=$aio: $out" >&2; return 1; }
    printf '%s\n' "$out" | grep -qx "SET territorio comuna_cut 09999" \
      && printf '%s\n' "$out" | grep -qx "SET territorio comuna_name Comuna Prueba" \
      || { echo "phase 16: territorio's comuna_cut / comuna_name were not written for aio=$aio: $out" >&2; return 1; }
    ! printf '%s\n' "$out" | grep -q "tile_url" \
      || { echo "phase 16: a tile_url was written or mentioned for aio=$aio — nothing provisions the basemap any more: $out" >&2; return 1; }
    ! printf '%s\n' "$out" | grep -q "^ASKED" \
      || { echo "phase 16: asked how the instance is reached (aio=$aio) — only the tile_url needed that: $out" >&2; return 1; }
  done
}
check territorio_phase16_cases

# I0 — gestion 3b62c24, ported: the session posture of phase 05 and the helper it calls. Three
# extracted-block cases in the shape above. Phase 05 is sourced with its three helpers stubbed to
# print what they were asked, so the assertion is the call itself (key, value, type), not a grep
# for a spelling. The last line is a NEGATIVE pin: `encryption.enabled` /
# `encryption.key_storage_migrated` were deliberately NOT ported (not verified as config.php keys;
# server-side encryption is `occ encryption:enable` plus a key-management decision with backup,
# group-folder and Office consequences) — a later edit that adds them must be a decision, not drift.
session_hardening_cases() {
  local out
  out="$(bash -e -o pipefail -c '
    phase_begin() { :; }
    phase_end() { :; }
    config_system_set() { printf "SET %s %s %s\n" "$@"; }
    app_enable() { printf "ENABLE %s\n" "$@"; }
    . provisioning/phases/05-security.sh' 2>&1)" \
    || { echo "session hardening: phase 05 failed under errexit: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -qxF "SET session_lifetime 900 integer" \
    || { echo "session hardening: session_lifetime 900 (integer) not set: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -qxF "SET session_keepalive false boolean" \
    || { echo "session hardening: session_keepalive false (boolean) not set: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -qxF "ENABLE admin_audit" \
    || { echo "session hardening: admin_audit not enabled: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "encryption" \
    && { echo "session hardening: phase 05 touches encryption.* — deliberately not ported: $out" >&2; return 1; }
  return 0
}
check session_hardening_cases
# The break-glass role is a role/group only — no permissions, no override mechanism. What is pinned
# is its presence in the registry both readers parse (registry_groups, role_categories) and its
# category, which 50-users and the roster frame read to decide the cat-* its holder also joins.
check python3 -c '
import sys
sys.path.insert(0, "scripts")
import provisionador as p
f = "provisioning/phases/20-groups.sh"
rid = "role-emergencia-breakglass"
assert rid in p.registry_groups(f), "registry_groups does not know " + rid
assert p.role_categories(f, [])[rid] == "cat-clinicos", "wrong category for " + rid
assert [rid, "Acceso de Emergencia (Break-Glass)"] in p.role_names(f), "role_names lacks " + rid'
# app_enable: query-before-enable, like app_disable beside it. Already enabled -> no occ call at all
# (a second seed must write nothing, or seed-idempotent reddens), twice in a row; absent -> one
# `app:enable`; a failing enable is reported and returned, never swallowed.
app_enable_cases() {
  local out
  # The helper sends occ's own output to /dev/null, so the stub records its calls in a file.
  out="$(CALLS="$(mktemp)" bash -c '
    . scripts/env.sh; . provisioning/lib.sh
    conf_load() { :; }
    conf_get() { printf "yes\n"; }
    occ() { printf "OCC %s\n" "$*" >> "$CALLS"; }
    log() { printf "LOG %s\n" "$*"; }
    app_enable admin_audit && app_enable admin_audit; cat "$CALLS"; rm -f "$CALLS"' 2>&1)" \
    || { echo "app_enable: an already-enabled app failed: $out" >&2; return 1; }
  [ "$out" = "LOG app admin_audit already enabled
LOG app admin_audit already enabled" ] \
    || { echo "app_enable: not idempotent when already enabled: $out" >&2; return 1; }
  out="$(CALLS="$(mktemp)" bash -c '
    . scripts/env.sh; . provisioning/lib.sh
    conf_load() { :; }
    conf_get() { return 1; }
    occ() { printf "OCC %s\n" "$*" >> "$CALLS"; }
    log() { printf "LOG %s\n" "$*"; }
    app_enable admin_audit; cat "$CALLS"; rm -f "$CALLS"' 2>&1)" \
    || { echo "app_enable: enabling an absent app failed: $out" >&2; return 1; }
  [ "$out" = "LOG app admin_audit -> enabled
OCC app:enable admin_audit" ] \
    || { echo "app_enable: an absent app was not enabled once: $out" >&2; return 1; }
  out="$(bash -c '
    . scripts/env.sh; . provisioning/lib.sh
    conf_load() { :; }
    conf_get() { printf "no\n"; }
    occ() { return 1; }
    log() { printf "LOG %s\n" "$*"; }
    app_enable admin_audit' 2>&1)" \
    && { echo "app_enable: a failing enable returned 0: $out" >&2; return 1; }
  [ "$out" = "LOG FAILED to enable admin_audit" ] \
    || { echo "app_enable: a failing enable was not said: $out" >&2; return 1; }
}
check app_enable_cases

# The café case above is behavioural, and load-bearing only under a COLLATING locale — which a
# Chilean dev has and GitHub's runners do not, defaulting to C.UTF-8 where that range refuses `é`
# anyway. So CI stays green on a revert, and CI is the only mechanical gate (AGENTS.md). This is
# the half CI can see. A grep for the fix, deliberately: where it runs, the behaviour is not
# observable at all, and a check that cannot fail there is worse than one that admits what it is.
check grep -q "local LC_ALL=C" provisioning/lib.sh

# --- gate: the tree stays establishment-agnostic (ADR-0013, generalized from the one-code grep) ---
# Shape-based, not literal: the pilot's residue was a hardcoded `deis.py` call in CI's fixture and steering
# examples in docs. A literal grep on one clinic's code is the pilot's number all over again — the
# next clinic's code passes it. The SHAPE is the contract: no tracked file may hand deis.py a DEIS
# code. Only the register CSVs are excluded — they ARE the codes, by design — and dated history
# is scrubbed, so nothing else gets a pass. git grep, not grep -r: tracked files only,
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

# --- gate: a21 (L5): the map is the suite's own route — the separate tiles server is gone -------------
# The grep is a21's own clause, with the pattern assembled without its literals
# ("nginx:alp""ine|TILES_""PORT|:80""84"): a21 covers scripts/ too, and a gate that spelled its
# own banned tokens would be its own hit. tiles.nginx.conf gone, no nginx pin, port or knob left
# anywhere the map used to need one. (Phase 16 no longer points territorio at /tiles/ — its own
# case above asserts the absence.) The gestion-era scope also
# named .env.example and compose.yaml — both stayed in gestion with the dev lifecycle, so the
# scope here is the fork's own trees.
check bash -c '
  test ! -e tiles.nginx.conf \
    && ! git grep -qE "nginx:alp""ine|TILES_""PORT|:80""84" -- host scripts provisioning'

# --- gate (org review L5-S3, I7): the map-folder default — five literals that must agree ---------
# /srv/aps-conecta is spelled in five places because each site legitimately owns its own fallback
# SHAPE: the host CLI's TILES_ARCHIVE, tiles.sh's standalone TILES_HOME, the testbed's
# APS_TILES_DIR env, env.sh's dotenv fixture, and refresh-basemap's DEST (the serving directory
# S3 gave it — a literal this pack itself introduced is exactly the drift site the gate exists to
# pin). Single-sourcing was weighed and rejected (tiles.sh's standalone fallback survives it), so
# the discipline is image-digests' pair-pin generalized to five: each site's default read out of
# the file, and they must all say the same path. Shape-anchored, not line-numbered. EXACTLY ONE
# match per site is required: a renamed variable or a deleted fixture is the
# empty-glob-goes-green class, red here by name. The negative half runs the same validator over
# fabricated corpora — one drifted site, one missing site — because a gate that cannot go red is
# not a gate.
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

# Clean boot (by IP) reads the suite tag out of scripts/aio-testbed.sh's one pin and refuses anything but a
# published form: the rehearsal's ci-YYYYMMDD-N, a release vX.Y.Z, or the pipeline's rehearsal vX.Y.Z-ci.N.
# The two lines are extracted from the workflow and run here over a fixture testbed: each accepted form
# yields its tag, and no pin, two pins, a floating tag or a smuggled shell word each fail.
cleanboot_suite_tag_cases() {
  local lines tmp got kind val want
  lines="$(grep -E '^ +(tag="\$\(sed -nE? .s/\^IMAGE=|\[\[ "\$tag" =~ )' .github/workflows/cleanboot.yml | sed 's/^ *//')"
  [ "$(printf '%s\n' "$lines" | wc -l)" -eq 2 ] || { echo "cleanboot: the suite-tag pin check was not found exactly once" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir "$tmp/scripts"
  pin() { printf 'IMAGE="${AIO_TEST_IMAGE:-ghcr.io/aps-conecta/all-in-one:%s}"\n' "$1"; }
  while IFS='|' read -r kind val want; do
    case "$kind" in
      one)  pin "$val" > "$tmp/scripts/aio-testbed.sh" ;;
      two)  { pin "$val"; pin ci-20261004-2; } > "$tmp/scripts/aio-testbed.sh" ;;
      none) printf 'IMAGE="${AIO_TEST_IMAGE:-nginx}"\n' > "$tmp/scripts/aio-testbed.sh" ;;
    esac
    got="$( cd "$tmp" && eval "$lines" 2>/dev/null && printf %s "$tag" )"
    case "$want" in
      fail) [ -z "$got" ] || { echo "cleanboot: $kind '$val' should be refused, got '$got'" >&2; rm -rf "$tmp"; return 1; } ;;
      *)    [ "$got" = "$want" ] || { echo "cleanboot: $kind '$val' expected '$want', got '$got'" >&2; rm -rf "$tmp"; return 1; } ;;
    esac
  done <<'CASES'
one|ci-20261004-2|ci-20261004-2
one|v0.4.0|v0.4.0
one|v10.20.30|v10.20.30
one|v0.0.0-ci.6|v0.0.0-ci.6
one|v0.5.0-ci.12|v0.5.0-ci.12
two|v0.4.0|fail
none|x|fail
one|latest|fail
one|v0.4|fail
one|v0.4.0-|fail
one|ci-2026-1|fail
one|v0.4.0;touch x|fail
CASES
  rm -rf "$tmp"
}
check cleanboot_suite_tag_cases

# The testbed brands the probe with the suite's theme, which lives in gestion — cleanboot.yml checks it
# out at ./gestion — and, in an older layout, at themes/ in this tree. theme_source picks the first
# that has a core/ directory (gestion's first) and fails when neither does; the function is extracted
# from the script (which runs its command on load) and run over fixture trees.
testbed_theme_source_cases() {
  local fn tmp got
  fn="$(awk '/^theme_source\(\) \{/ {f=1} f {print} f && /^}/ {exit}' scripts/aio-testbed.sh)"
  [ -n "$fn" ] || { echo "testbed: theme_source() was not found in scripts/aio-testbed.sh" >&2; return 1; }
  tmp="$(mktemp -d)"
  while IFS='|' read -r dirs want; do
    rm -rf "${tmp:?}/root"; mkdir -p "$tmp/root"
    for d in ${dirs//,/ }; do mkdir -p "$tmp/root/$d"; done
    got="$( eval "$fn"; theme_source "$tmp/root" )" || got=""
    [ "$got" = "${want:+$tmp/root/}$want" ] \
      || { echo "testbed: tree [$dirs] expected '${want:-none}', got '$got'" >&2; rm -rf "$tmp"; return 1; }
  done <<'CASES'
gestion/themes/apsconecta/core|gestion/themes/apsconecta
themes/apsconecta/core|themes/apsconecta
gestion/themes/apsconecta/core,themes/apsconecta/core|gestion/themes/apsconecta
gestion/themes/apsconecta,themes/apsconecta/core|themes/apsconecta
gestion/themes/apsconecta|
x|
CASES
  rm -rf "$tmp"
  grep -q 'no gestion/themes/apsconecta/core nor themes/apsconecta/core' scripts/aio-testbed.sh \
    || { echo "testbed: the FATAL message must name both locations" >&2; return 1; }
}
check testbed_theme_source_cases

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

# --- gate: the anchors the wizard links into these docs still resolve ---------------------
# The wizard (patch 140's and 170's bytes, committed since the hard fork) links six sections of
# the runbooks by their GitHub anchors. A renamed or renumbered heading breaks those links in
# every published suite image without a word, so the six are a contract: a heading keeps its
# slug, or an explicit <a id=\"…\"></a> carries it. GitHub's slug: lower-case, every character but
# letters, digits, spaces, hyphens and underscores dropped, spaces to hyphens. Same validator on
# a fabricated doc.
check python3 -c '
import re, sys
ANCLAS = {"aps/INSTALLER.md": ["3-preflight", "7-dns-the-host-must-reach-its-own-domain-d10", "11-backups", "12-troubleshooting"],
          "aps/GUIA-CLINICA.md": ["3-el-asistente-8080", "7-tras-actualizar"]}
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
en = section(open("aps/INSTALLER.md", encoding="utf-8").read(), "\n## 14. Without a domain: this server\x27s IP\n")
es = section(open("aps/GUIA-CLINICA.md", encoding="utf-8").read(), "\n## 11. Sin dominio: la dirección IP del servidor\n")
if not twins(en, es): print("INSTALLER §14 and GUIA §11 are missing or carry different commands"); sys.exit(1)
if "aps/GUIA-CLINICA.md §11" not in open("host/aps-conecta", encoding="utf-8").read(): print("the console does not point at GUIA §11"); sys.exit(1)
if "(guía, §11)" not in open("scripts/provisionador.py", encoding="utf-8").read(): print("step 7 does not point at GUIA §11"); sys.exit(1)
if twins("## 14. x\n```\na\n```\n", "## 11. y\n```\nb\n```\n"): print("a drifted pair passed"); sys.exit(1)
if twins("## 14. x\n- **A**\n```\na\n```\n", "## 11. y\n```\na\n```\n"): print("a pair missing a bullet passed"); sys.exit(1)
print("ok")'

# --- org L5-11/L5-05/L5-12: the provisioning self-tests (hermetic) ----------------------------
# standings.sh: the one uid derivation's fixture parity; env.sh: the loader/compose
# round-trip (its compose-parity arm self-skips — no compose.yaml moved — and the container arms
# run on a stub docker); usuarios.sh: the frame guards.
check bash provisioning/standings.sh --self-test
check bash scripts/env.sh --self-test
# #197: no caller restates the container default or guards it (`:-` `-` `:?` `?`) — env.sh
# section 3 is the one place it is decided. The .env.example half of the gestion-era gate stayed
# with the template (gestion's own gate — the template did not move); this half guards
# instalador's tree. git grep exits 1 on no match and 128 on error, so only a real "none found"
# passes (a tree without git is red, not green).
check bash -c '{ git grep -qE "NC_CONTAINE[R]:?[?-]" -- . ":!scripts/env.sh"; [ $? -eq 1 ]; }'
check bash provisioning/usuarios.sh --self-test

echo "== self-tests (hermetic — no docker, no stack) =="
# The Provisionador's own --self-test (its stub oracle rides --self-test, so the runner needs no
# docker), the host bundle's, tiles', and the migration tool's run everywhere test.sh runs — every
# PR, any box — because none needs a stack. The bootstrap's joins them (fixture packages and PATH
# shims only), and so does the signer's — the one self-test that needs signify installed, because
# it is real crypto over a throwaway keypair; CI apt-installs the same package the clinic verifies
# with, and a box without it gets the honest skip. Output is captured, not drowned: a green arm
# prints its own last line, a red one its tail — the #96 lesson, a red log must carry its diagnosis.
st_out="$(python3 scripts/provisionador.py --self-test 2>&1)" \
  && echo "  ok:   provisionador --self-test ($(printf '%s\n' "$st_out" | tail -1))" \
  || { echo "  FAIL: provisionador --self-test"; printf '%s\n' "$st_out" | tail -25; fail=1; }
hb_out="$(bash host/aps-conecta --self-test 2>&1)" \
  && echo "  ok:   host bundle --self-test ($(printf '%s\n' "$hb_out" | tail -1))" \
  || { echo "  FAIL: host bundle --self-test"; printf '%s\n' "$hb_out" | tail -25; fail=1; }
tl_out="$(bash host/tiles.sh --self-test 2>&1)" \
  && echo "  ok:   tiles --self-test ($(printf '%s\n' "$tl_out" | tail -1))" \
  || { echo "  FAIL: tiles --self-test"; printf '%s\n' "$tl_out" | tail -25; fail=1; }
ib_out="$(bash install.sh --self-test 2>&1)" \
  && echo "  ok:   bootstrap --self-test ($(printf '%s\n' "$ib_out" | tail -1))" \
  || { echo "  FAIL: bootstrap --self-test"; printf '%s\n' "$ib_out" | tail -25; fail=1; }
if command -v signify >/dev/null 2>&1; then
  pr_out="$(bash scripts/package-release.sh --self-test 2>&1)" \
    && echo "  ok:   package-release --self-test ($(printf '%s\n' "$pr_out" | tail -1))" \
    || { echo "  FAIL: package-release --self-test"; printf '%s\n' "$pr_out" | tail -25; fail=1; }
else
  echo "  skipped: package-release --self-test (no signify — sudo apt-get install signify-openbsd)"
fi
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
# The retag self-test rides the same capture-and-tail idiom: hermetic (a PATH-shim docker over
# a fixture registry, local git repos as the discovery catalogue — no network, no daemon), so
# it runs everywhere test.sh runs. A green arm prints its verdict line; a red one its tail.
rt_out="$(bash scripts/retag.sh --self-test 2>&1)" \
  && echo "  ok:   retag --self-test ($(printf '%s\n' "$rt_out" | tail -1))" \
  || { echo "  FAIL: retag --self-test"; printf '%s\n' "$rt_out" | tail -25; fail=1; }

echo "== smoke (only if a stack is running) =="
. scripts/env.sh
if is_aio; then
  # SMOKE_ADMIN_PROBE: check 15, the developer-only admin-settings probe (B-031)
  if SMOKE_ADMIN_PROBE=1 bash scripts/smoke.sh; then echo "  ok:   smoke"; else echo "  FAIL: smoke"; fail=1; fi
else
  echo "  skipped: no running AIO stack (static-only gate)"
fi

# Euro-Office joined the standard gate in #81, because it joined the stack: office-smoke was
# separate only because it needed a service that might not be running. Its rename assertions moved
# to build time (office-smoke.sh's header): under the suite the store is off and a published tag's
# digests never move, so scripts/bake.sh asserts the rename once per image build.
#
# Still guarded on the service, not assumed: this script runs in the static CI gate with no stack
# at all, and stopping the office backend is a documented way to reclaim the RAM. `--wait` is what
# makes this deterministic when the stack IS up — without it the gate raced the 120s start_period.
echo "== office smoke (only if the document server is running) =="
# The gate and office-smoke's own inspect match the SAME name — the AIO sibling AIO's own
# containers.json pins (aps-conecta-eurooffice), deterministic on every AIO host the way the
# compose project name was on compose — so the two cannot drift. A compose dev
# stack reads as skipped here BY DESIGN — the skip is visible, never silent.
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
