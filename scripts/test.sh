#!/usr/bin/env bash
# The suite's quality gate, run locally and by .github/workflows/ci.yml.
# Static checks that need no running stack, then the hermetic self-tests of every mover that
# carries one — including the bootstrap's and the package signer's — then the smoke checks when a
# stack is up. Exits non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
# The fork's shell namespace, spelled once for every row that walks it (the sweep below, the
# dirname gate at #60's row). Unquoted on purpose: the words re-glob where they are used. The
# comm tripwire a few lines down keeps its own literal copy deliberately — it is the alarm
# that reds when this list and the tree drift apart.
SHELL_NAMESPACE='scripts/*.sh provisioning/*.sh provisioning/phases/*.sh host/*.sh install.sh'
linted=0
for s in $SHELL_NAMESPACE; do
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
# --- gate (#60): dirname-of-self only where the caller's cwd still governs ----------------------
# env.sh's first job is `cd "$(dirname "${BASH_SOURCE[0]}")/.."` — the repo root (env.sh §1).
# A dirname of $0 evaluated on any LATER line resolves against the NEW cwd whenever the
# script was started by a relative path, so it names a directory that is not the script's.
# #30's first draft shipped exactly that twice (the smoke test and the divergence gate) and a
# reviewer caught both; this row is the retro's ask — the gate reds on the class, not the
# spelling. Position is the contract, and it is exact in both directions:
#   - the sourcing line itself expands BEFORE env.sh runs;
#   - lines before the first source still see the caller's cwd — the pre-computed HERE idiom
#     (seed.sh:8) is absolute by the time env.sh moves, and usuarios.sh:36's
#     own cd is pre-source by construction;
#   - everything after the first source line must not self-locate by dirname. $BASH_SOURCE
#     rides the same rule: launched relatively, it is exactly as relative as $0.
# Subjects are discovered by the source line itself, over the lint sweep's namespace, so a
# script that starts sourcing env.sh is covered the day it lands. The fixtures live as real
# bytes under tests/gate-fixtures/ (never executed) — not as heredocs here, whose bytes would
# be this file's own post-source lines and red the gate on itself. And per org L7-2 the row
# proves it can red: the #30 shape must be flagged, while every legal idiom above — and a
# script that never sources env.sh — must stay green.
ENV_SH_SOURCE_RE='^[[:space:]]*(\.|source)[[:space:]][^#]*env\.sh'
ENV_SH_SELFLOC_RE='dirname[[:space:]]+(-[[:alnum:]-]+[[:space:]]+)?("\$0"|\$0|"\$\{BASH_SOURCE\}"|"\$BASH_SOURCE"|"\$\{BASH_SOURCE\[0\]\}"|\$\{BASH_SOURCE\[0\]\})'
env_sh_selfpath_rows() {  # FILE... — every dirname-of-self evaluated after env.sh moved the cwd
  local f first
  for f in "$@"; do
    [ -f "$f" ] || continue          # a glob that matched nothing stays literal (the sweep's rule)
    first="$(grep -nE "$ENV_SH_SOURCE_RE" "$f" | head -1 | cut -d: -f1)"
    [ -n "${first:-}" ] || continue   # never sources env.sh: not this gate's subject
    grep -nE "$ENV_SH_SELFLOC_RE" "$f" | awk -F: -v first="$first" -v f="$f" '
      ($1 + 0) > first { print f ":" $0 }'
  done
}
env_sh_selfpath_gate() {
  local rows n rc=0
  # green on main is the baseline: the shipped tree carries none
  rows="$(env_sh_selfpath_rows $SHELL_NAMESPACE)"
  [ -z "$rows" ] || { printf 'a script sources env.sh and then self-locates by dirname — the cwd is the repo root by then:\n%s\n' "$rows" >&2; return 1; }
  # red on the injected violation (org L7-2): both spellings, and only those two rows
  rows="$(env_sh_selfpath_rows tests/gate-fixtures/violador.sh)"
  n="$(printf '%s\n' "$rows" | grep -c .)"
  [ "$n" = 2 ] || { printf 'the gate flagged %s rows on the #30 fixture, want exactly 2:\n%s\n' "${n:-0}" "$rows" >&2; rc=1; }
  printf '%s\n' "$rows" | grep -q '\.\./VERSION' || { echo 'the gate missed the #30 shape (a dirname of $0 after the source)' >&2; rc=1; }
  printf '%s\n' "$rows" | grep -q 'BASH_SOURCE' || { echo 'the gate missed the BASH_SOURCE spelling' >&2; rc=1; }
  # and green on every legal idiom, and on a script that never sources env.sh
  rows="$(env_sh_selfpath_rows tests/gate-fixtures/legal.sh)"
  [ -z "$rows" ] || { printf 'the gate reds a legal idiom:\n%s\n' "$rows" >&2; rc=1; }
  rows="$(env_sh_selfpath_rows tests/gate-fixtures/ajeno.sh)"
  [ -z "$rows" ] || { printf 'the gate took a non-sourcer as a subject:\n%s\n' "$rows" >&2; rc=1; }
  return "$rc"
}
check env_sh_selfpath_gate


# --- gate: the channel's identity — instalador is the only home the operator is sent to ---------
# The move re-keyed every operator pointer (D13): the bootstrap, the CLI's remedies, the wizard's
# help arms, the units' Documentation lines. The rename (#53) made gestion the suite repo's own
# name, so the entry files must carry it — the forbid-gestion rule of the clone era would now red
# on the canonical URL. Three shapes pin the channel instead:
#   - the two operator entry files' repo URL is exactly the suite repo's canonical URL, so any
#     drift — back to instalador, or on to anything else — reds naming the file;
#   - the signing key has exactly two committed readers, and they agree (the env.sh lesson):
#     installer.pub's key line and install.sh's embedded SIGNIFY_PUBKEY — package-release.sh reds
#     on a disagreement at tag time; this is the PR-time half, before a tag is ever cut;
#   - no runbook pointer survives with the old docs/ prefix: the runbooks live in aps/ (D13),
#     so such a remedy would be a
#     dead pointer in the package an operator actually holds. aps/CHANGELOG.md is dated history
#     and keeps what it said when it said it.
check bash -c '
  want="https://github.com/APS-Conecta/gestion"
  got="$(sed -n "s|^REPO_URL=\"\${REPO_URL:-\(.*\)}\".*|\1|p" install.sh | head -1)"
  [ "$got" = "$want" ] || { echo "install.sh no lleva el URL canónico del repositorio de la suite: $got" >&2; exit 1; }
  got="$(sed -n "s|^INSTALADOR_REPO_URL=\"\${INSTALADOR_REPO_URL:-\(.*\)}\".*|\1|p" host/aps-conecta | head -1)"
  [ "$got" = "$want" ] || { echo "host/aps-conecta no lleva el URL canónico del repositorio de la suite: $got" >&2; exit 1; }'
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
#     guard and is not one: it asserts nothing. The sweep reads the whole tree, not only seed.sh,
#     because the shape turns up wherever a guard is written.
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
# --- gate: a new file in the fork's namespaces carries an SPDX header (#63) ---------------------
# AGENTS.md's inherited rule ("new fork-owned scripts carry an SPDX header") met 46 of them
# without one, so every PR asked its reviewer to weigh the rule against precedent (#30's retro).
# The owner's call on #63: enforce for files added from now on, fork namespaces only — the same
# namespaces the lint and errexit sweeps own, upstream's shell staying upstream's, and, because
# the rule names scripts, over .sh and .py both; other files (.json, .conf, docs) stay out.
# SPDX_BASELINE freezes the headerless scripts that predate the decision, so main is green by
# construction and the row reds only on a file it has never seen: a tracked one without the
# header line and not on the list. When a baseline file gains its header, drop its line here;
# an exception is a baseline extension in a commit that says why — never a silent row-weakening.
SPDX_BASELINE='
install.sh
provisioning/app-policy.sh
provisioning/intravox/render.py
provisioning/lib.sh
provisioning/phases/05-security.sh
provisioning/phases/06-jobs.sh
provisioning/phases/07-certs.sh
provisioning/phases/10-locale.sh
provisioning/phases/12-apps.sh
provisioning/phases/14-office.sh
provisioning/phases/15-branding.sh
provisioning/phases/16-app-policy.sh
provisioning/phases/20-groups.sh
provisioning/phases/30-folders.sh
provisioning/phases/40-acl.sh
provisioning/phases/41-intravox.sh
provisioning/phases/50-users.sh
provisioning/phases/60-fixtures.sh
provisioning/seed.sh
provisioning/standings.sh
provisioning/usuarios.sh
scripts/acquisition-gate.sh
scripts/aio-testbed.sh
scripts/brand-gate.sh
scripts/cleanboot-site.sh
scripts/comuna-package.sh
scripts/deis.py
scripts/divergence.sh
scripts/env-init.sh
scripts/env.sh
scripts/install.sh
scripts/lockup.py
scripts/office-smoke.sh
scripts/package-release.sh
scripts/provisionador.py
scripts/rename-containers.py
scripts/retag.sh
scripts/seed-idempotent.sh
scripts/smoke.sh
scripts/test.sh
scripts/validate.sh
scripts/wait-ready.sh
'
spdx_offenders() {
  # every argument that neither carries the header line nor sits on the frozen baseline
  local f
  for f in "$@"; do
    grep -qxF "$f" <<<"$SPDX_BASELINE" && continue
    grep -qx "# SPDX-License-Identifier: AGPL-3.0-or-later" "$f" || printf "%s\n" "$f"
  done
}
spdx_header_row() {
  local off
  off="$(spdx_offenders $(git ls-files "*.sh" "*.py" | grep -E '^scripts/|^provisioning/|^host/|^install\.sh$'))"
  [ -z "$off" ] || { printf "tracked scripts lacking an SPDX header and not on the #63 baseline:\n%s\n" "$off" >&2; return 1; }
}
check spdx_header_row
# The baseline's own gate (the seed-idempotent lesson: an allowlist that can rot must not rot
# silently). spdx_header_row pins one direction — every tracked script is headered or on the
# baseline; this pins the other — every baseline line still names a tracked, headerless script.
# Together they make baseline ≡ the headerless set, so green on main cannot erode: a line left
# behind by a rename or a deletion, or by a file that gained its header, reds here instead of
# rotting, and a line appended that names nothing real reds on the spot.
spdx_baseline_row() {
  local line
  local -a dead=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! git ls-files -- "$line" | grep -qx "$line"; then
      dead+=("$line (no longer a tracked file)")
    elif grep -qx "# SPDX-License-Identifier: AGPL-3.0-or-later" "$line"; then
      dead+=("$line (has the header — drop its baseline line)")
    fi
  done <<<"$SPDX_BASELINE"
  [ ${#dead[@]} -eq 0 ] || { printf 'SPDX_BASELINE lines that no longer name a headerless tracked script:\n' >&2; printf '%s\n' "${dead[@]}" >&2; return 1; }
}
check spdx_baseline_row
# The detector's own gate (the AGNOSTIC_SHAPE lesson: a row whose detector cannot go red is not a
# row). The same spdx_offenders bytes the row runs, over a fabricated corpus: a new unheadered
# script is the one offender; a baseline member without the header and a newcomer WITH it are not.
spdx_offenders_cases() {
  local tmp off
  tmp="$(mktemp -d)"
  printf "#!/usr/bin/env bash\necho hi\n" > "$tmp/new.sh"
  printf "#!/usr/bin/env bash\n" > "$tmp/old.sh"
  printf "#!/usr/bin/env bash\n# SPDX-FileCopyrightText: 2026 APS Conecta\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n" > "$tmp/headered.sh"
  off="$(SPDX_BASELINE="$tmp/old.sh" spdx_offenders "$tmp/new.sh" "$tmp/old.sh" "$tmp/headered.sh")"
  rm -rf "$tmp"
  [ "$off" = "$tmp/new.sh" ] \
    || { echo "spdx detector: expected exactly the new unheadered script, got: $off" >&2; return 1; }
}
check spdx_offenders_cases
# And the baseline row's red test, in a scratch git tree so "tracked" is real: a frozen line
# naming a tracked headerless script passes; a line for a file that gained its header, and one
# for a file that is gone, both red — each named with its cause.
spdx_baseline_cases() {
  local tmp out
  tmp="$(mktemp -d)"
  printf "#!/usr/bin/env bash\n" > "$tmp/old.sh"
  printf "#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n" > "$tmp/gained.sh"
  if ! ( cd "$tmp" && git init -q . && git add old.sh gained.sh \
         && SPDX_BASELINE="old.sh" spdx_baseline_row ); then
    rm -rf "$tmp"; echo "spdx baseline: a frozen line naming a tracked headerless script red" >&2; return 1
  fi
  out="$( cd "$tmp" && SPDX_BASELINE="old.sh
gained.sh
gone.sh" spdx_baseline_row 2>&1 )"
  rm -rf "$tmp"
  printf '%s\n' "$out" | grep -q "gained.sh (has the header — drop its baseline line)" \
    && printf '%s\n' "$out" | grep -q "gone.sh (no longer a tracked file)" \
    || { echo "spdx baseline: a gained header or a vanished file did not red with its cause: $out" >&2; return 1; }
}
check spdx_baseline_cases
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
# quotes and backslashes (the deis round trip in the register gate), so one identity value carries both.
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
        print(rel + " does not name the storage folder IV_MOUNT names (ADR-0016)"); sys.exit(1)
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
# groupfolder_name, ADR-0016). Both readers here take it from env.sh; the sandbox stub derives the
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
# a second, empty mount (ADR-0016). Extracted from the phase's own bytes (a named function: the
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

# Phase 30 installs the organization conventions verbatim as «LÉEME — Convenciones.md». The whole
# phase runs under errexit (seed.sh's own shape) with its helpers stubbed, from a scratch root: with
# provisioning/data/convenciones.md present the file's bytes are what it writes; without it the
# phase stops before writing (a failing $(cat …) inside an argument would not trip errexit).
conventions_phase_cases() {
  local tmp out rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/provisioning/data"
  printf 'regla uno\n«dos»\n' > "$tmp/provisioning/data/convenciones.md"
  run30() {
    ( cd "$tmp" && bash -c '
        set -e
        SITE_FOLDERS=(); SITE_SUBFOLDERS=()
        phase_begin() { :; }; phase_end() { :; }
        ensure_groupfolder() { :; }; ensure_gf_subfolder() { :; }
        ensure_gf_file() { printf "WRITE %s|%s|%s\n" "$1" "$2" "$3"; }
        . "$1"' _ "$OLDPWD/provisioning/phases/30-folders.sh" 2>&1 )
  }
  out="$(run30)"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = "$(printf 'WRITE Transversal|LÉEME — Convenciones.md|regla uno\n«dos»')" ] \
    || { echo "phase 30: expected the conventions file's bytes written, got rc=$rc: $out" >&2; rm -rf "$tmp"; return 1; }
  rm "$tmp/provisioning/data/convenciones.md"
  out="$(run30)"; rc=$?
  [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q '^FATAL: ' && ! printf '%s\n' "$out" | grep -q '^WRITE ' \
    || { echo "phase 30: a missing conventions file must stop the phase before any write, got rc=$rc: $out" >&2; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}
check conventions_phase_cases

# Phase 10 seeds the instance time zone (default_timezone) from the Nextcloud container's TZ, the
# zone chosen in AIO. Same shape as above: the whole phase under errexit, helpers stubbed, nc_exec
# standing in for the container's printenv. Not AIO (the legacy container) seeds no zone.
locale_phase_cases() {
  local out rc
  run10() {  # AIO(1|0) CONTAINER_UP(1|0)
    AIO="$1" UP="$2" bash -c '
      set -e
      phase_begin() { :; }; phase_end() { :; }
      config_system_set() { printf "SET %s|%s\n" "$1" "$2"; }
      is_aio() { [ "$AIO" = 1 ]; }
      nc_exec() {
        [ "$UP" = 1 ] || return 1
        [ "$*" = "-- printenv TZ" ] && echo America/Santiago
      }
      . provisioning/phases/10-locale.sh' 2>&1
  }
  out="$(run10 1 1)"; rc=$?
  [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qxF 'SET default_timezone|America/Santiago' \
    || { echo "phase 10: expected default_timezone seeded from the container's TZ, got rc=$rc: $out" >&2; return 1; }
  out="$(run10 1 0)"; rc=$?
  [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q '^FATAL: ' && ! printf '%s\n' "$out" | grep -q '^SET default_timezone' \
    || { echo "phase 10: an unreadable TZ must stop the phase with a FATAL and no zone written, got rc=$rc: $out" >&2; return 1; }
  out="$(run10 0 1)"; rc=$?
  [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q '^SET default_timezone' \
    || { echo "phase 10: the legacy container has no AIO zone and must get none, got rc=$rc: $out" >&2; return 1; }
}
check locale_phase_cases

# The suite manifest unreadable: the gate's apps section says so in ONE Spanish note carrying the
# cause — apps.py's own stderr no longer reaches the operator beside it, and the red branch never
# execs into the instance. Extracted, run in a temp tree whose apps.json is not JSON.
manifest_unreadable_divergence_case() {
  local section tmp out
  section="$(sed -n '/^# --- apps unpacked into custom_apps/,/^fi$/p' scripts/divergence.sh)"
  [ -n "$section" ] || { echo "manifest divergence: apps section not found in divergence.sh" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir "$tmp/scripts"
  cp scripts/apps.py "$tmp/scripts/apps.py"; printf '{no es JSON' > "$tmp/apps.json"
  out="$(cd "$tmp" && bash -c '
    note() { printf "NOTE %s\n" "$*"; }
    nc_exec() { echo "nc_exec reached"; }
    eval "$1"' _ "$section" 2>&1)"
  rm -rf "$tmp"
  [ "$out" = "NOTE no se pudieron revisar las aplicaciones: no se pudo leer la lista de aplicaciones de la suite ($tmp/apps.json): no es JSON válido (línea 1, columna 2)" ] \
    || { echo "manifest divergence: expected the one Spanish note, got: $out" >&2; return 1; }
}
check manifest_unreadable_divergence_case

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

# I0: the session posture of phase 05 and the helper it calls. Three
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

# A boolean system key converges: config:list stores session_keepalive as JSON false and conf_get
# renders it "" (occ's own rendering), so a setter that compares that against the word "false"
# writes on every seed and seed-idempotent reddens. Stored false -> no write; absent or true -> one.
config_system_bool_cases() {
  local cache want out
  while IFS='|' read -r cache want; do
    out="$(CALLS="$(mktemp)" CACHE="$cache" bash -c '
      . scripts/env.sh; . provisioning/lib.sh
      CONF_CACHE="$CACHE"
      occ() { printf "OCC %s\n" "$*" >> "$CALLS"; }
      log() { :; }
      config_system_set session_keepalive false boolean; cat "$CALLS"; rm -f "$CALLS"' 2>&1)"
    case "$want" in
      none) [ -z "$out" ] ;;
      write) [ "$out" = "OCC config:system:set session_keepalive --type=boolean --value=false" ] ;;
    esac || { echo "config_system_set: cache $cache expected $want, got: $out" >&2; return 1; }
  done <<'CASES'
{"system": {"session_keepalive": false}}|none
{"system": {}}|write
{"system": {"session_keepalive": true}}|write
CASES
}
check config_system_bool_cases

# The café case above is behavioural, and load-bearing only under a COLLATING locale — which a
# Chilean dev has and GitHub's runners do not, defaulting to C.UTF-8 where that range refuses `é`
# anyway. So CI stays green on a revert, and CI is the only mechanical gate (AGENTS.md). This is
# the half CI can see. A grep for the fix, deliberately: where it runs, the behaviour is not
# observable at all, and a check that cannot fail there is worse than one that admits what it is.
check grep -q "local LC_ALL=C" provisioning/lib.sh

# --- gate: the tree stays establishment-agnostic (ADR-0009, generalized from the one-code grep) ---
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

# === the theme, the sites register and the data masters ===========================================
# Their gates live beside them: the vendored map bytes, the env template's placeholders, the
# theme's assets and lockups, the DEIS register's round trip through deis.py, and the data manifest.
# --- gate (L5 S4): the vendored map libraries are the pinned bytes ---------------------------------
# The Centro pane's engine is two files copied byte-identical from territorio's node_modules
# (https://aps-conecta.github.io/documentation/desarrollo/licencias.html). Vendored bytes are the one diff a reviewer reads as "just assets":
# territorio upgrades, a re-vendor misses a file, an editor "fixes" a minified line — and the
# installer's map changes with no gate the eye can catch. The pair-pin discipline,
# applied to vendored files: each must exist and hash to its pin. The negative half mutates one
# byte of a copy — a gate that cannot go red is not a gate.
check python3 -c '
import hashlib, os, sys, tempfile
PINS = {
    "themes/apsconecta/core/mapa/leaflet.js":
        "db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a",
    "themes/apsconecta/core/mapa/leaflet.css":
        "a7837102824184820dfa198d1ebcd109ff6d0ff9a2672a074b9a1b4d147d04c6",
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
# A clinic must never be installed with the secrets this repository publishes. env-init.sh generates
# all four, so a placeholder survives only a hand-copy of the template — which is what somebody does
# when scripts/env-init.sh refuses because .env is already there. Behavioural, and driven from
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
  # `$$` one becomes once it undoes the escape — both conventions .env.example already uses.
  # The equality test this replaced let exactly this through: the
  # gate failed OPEN, silently, and a clinic would install with a published secret.
  ( export NEXTCLOUD_ADMIN_PASSWORD="\"$(shipped NEXTCLOUD_ADMIN_PASSWORD)\""; require_real_secrets 2>/dev/null ) && exit 1
  exit 0'
# Regression guard (ADR-0003): every STATIC asset server.css references must exist on disk. It shipped
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
# Regression guard: a lockup that draws text must carry the font that text is set in. An SVG
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
# Every establishment the installer offers carries its official point: the point is where the
# Centro map starts and what SITE_LON/SITE_LAT copy. A --snapshot that skipped --coordenadas is the
# realistic way to get here — snapshot_from writes the ten columns only.
check python3 -c '
import csv, glob, sys
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))
if len(rows) < 100:
    print("register truncated: " + str(len(rows)) + " rows -- this check measured nothing"); sys.exit(1)
bad = [r["codigo"] for r in rows if not all(deis.DEGREES.fullmatch(r.get(k) or "") for k in deis.COORDS)]
if bad:
    print(str(len(bad)) + " register rows without a plain-degree point: " + ", ".join(bad[:5])); sys.exit(1)'
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
# The welcome declaration has a WRITER (deis.py) and a READER (seed.sh's guard + phase 41). This
# proves the writer's output is what the reader expects: written to a scratch tree (write_site
# refuses an existing sites/<name>/), sourced by a real bash, the rows read back — and `equipos`
# absent, because that is the product decision the default carries.
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

# --- gate: a21 (L5): the map is the suite's own route — the separate tiles server is gone -------------
# The grep is a21's own clause, with the pattern assembled without its literals
# ("nginx:alp""ine|TILES_""PORT|:80""84"): a21 covers scripts/ too, and a gate that spelled its
# own banned tokens would be its own hit. tiles.nginx.conf gone, no nginx pin, port or knob left
# anywhere the map used to need one. (Phase 16 no longer points territorio at /tiles/ — its own
# case above asserts the absence.)
check bash -c '
  test ! -e tiles.nginx.conf \
    && ! git grep -qE "nginx:alp""ine|TILES_""PORT|:80""84" -- .env.example host scripts provisioning'

# --- gate: the tile machinery is retired (territorio draws OpenStreetMap's tile service, territorio ADR-0021) -----
# The map-folder default used to be spelled in six places that had to agree (org review L5-S3, I7);
# with the folder gone there is nothing to agree on, and the proof is the absence: the build, the
# refresh, the timer's two units and the host CLI's map step do not exist, and no knob that fed them
# survives. The tokens are assembled without their literals so this file is not its own hit. The ONE
# place the old folder is still named is the host CLI's retirement of a host that ran the earlier
# bundle (retire_tile_remnants, TILES_REMNANT_DIR) — a different name on purpose, so this grep can stay
# absolute. APS_TILES_""DIR itself survives in patch 239's brand-gate row (its own change) and in the
# host self-test's legacy-environment arm, so it is checked only where it would still do work: the
# run string and the testbed.
check bash -c '
  for f in host/tiles.sh scripts/refresh-""basemap.sh host/aps-conecta-tiles.service host/aps-conecta-tiles.timer; do
    [ ! -e "$f" ] || { echo "$f is back — the tile machinery is retired" >&2; exit 1; }
  done
  hits="$(git grep -nE "APS_SKIP_""MAP|TILES_""HOME|TILES_""ARCHIVE|suite_tiles_""dir|refresh-""basemap" -- host scripts provisioning .github || true)"
  [ -z "$hits" ] || { printf "tile-machinery knobs survive:\n%s\n" "$hits" >&2; exit 1; }
  hits="$(git grep -nE "APS_TILES_""DIR" -- scripts/aio-testbed.sh scripts/env.sh .github || true)"
  [ -z "$hits" ] || { printf "the map folder is still handed to the mastercontainer:\n%s\n" "$hits" >&2; exit 1; }
  out="$(APS_SUITE_TAG=v0.0.0 bash host/aps-conecta run-command 2>&1)"
  case "$out" in "docker run"*) ;; *) echo "run-command printed no docker run string: $out" >&2; exit 1 ;; esac
  ! grep -q "APS_TILES_""DIR" <<<"$out"'

# --- gate (#178): AppAPI runs through HaRP only — the board app and the deprecated socket proxy are gone ---
# #175 removes both from the suite with no tombstone, so the proof is the absence, tree-wide: no image
# directory, no container definition (the release list is parsed from it), no wizard setting or checkbox,
# no entrypoint block, no doc line. The pattern is assembled without its literals so this file is not
# its own hit.
check bash -c '
  re="white""board|docker.?socket""[._ -]?proxy"
  hits="$(git ls-files | grep -iE "$re"; git grep -nIiE "$re")"
  [ -z "$hits" ] || { printf "still in the tree:\n%s\n" "$hits" >&2; exit 1; }'

# Clean boot resolves its suite tag once, in the «suite-tag» job: the dispatch's suite-tag input, else
# scripts/aio-testbed.sh's one pin, judged by one regex before docker sees it — the rehearsal's ci-YYYYMMDD-N,
# a release vX.Y.Z, or the pipeline's rehearsal vX.Y.Z-ci.N — then looked up on ghcr.io. The step is extracted
# from the workflow and run here over a fixture testbed and a stubbed docker: each accepted form reaches
# GITHUB_OUTPUT after one manifest lookup of its own tag; no pin, two pins, a floating tag or a smuggled shell
# word are refused with no docker call; a tag ghcr.io does not have fails, and the FATAL names it.
cleanboot_suite_tag_cases() {
  local script tmp got calls kind val want input
  script="$(awk '/- name: The suite tag both jobs install/ {f=1; next}
                 f && /run: \|/ {r=1; next}
                 r && /^          / {sub(/^          /, ""); print; next}
                 r {exit}' .github/workflows/cleanboot.yml)"
  [ -n "$script" ] || { echo "cleanboot: the suite-tag step was not found" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir "$tmp/scripts"
  pin() { printf 'IMAGE="${AIO_TEST_IMAGE:-ghcr.io/aps-conecta/all-in-one:%s}"\n' "$1"; }
  while IFS='|' read -r kind val want input; do
    case "$kind" in
      one)  pin "$val" > "$tmp/scripts/aio-testbed.sh" ;;
      two)  { pin "$val"; pin ci-20261004-2; } > "$tmp/scripts/aio-testbed.sh" ;;
      none) printf 'IMAGE="${AIO_TEST_IMAGE:-nginx}"\n' > "$tmp/scripts/aio-testbed.sh" ;;
    esac
    : > "$tmp/out"; : > "$tmp/calls"
    ( cd "$tmp" && GITHUB_OUTPUT="$tmp/out" DISPATCH_TAG="$input" bash -e -c '
        docker() { printf "%s\n" "$*" >> calls
          case "$*" in *:v0.0.0-ci.99) echo "manifest unknown" >&2; return 1 ;; esac; }
        eval "$1"' _ "$script" ) >/dev/null 2>"$tmp/err"
    got="$(sed -n 's/^tag=//p' "$tmp/out")"; calls="$(cat "$tmp/calls")"
    case "$want" in
      fail)   [ -z "$got" ] && [ -z "$calls" ] \
                || { echo "cleanboot: $kind '$val' input '$input' should be refused before docker, got '$got', docker: $calls" >&2; rm -rf "$tmp"; return 1; } ;;
      absent) [ -z "$got" ] && grep -q "FATAL.*$input" "$tmp/err" \
                || { echo "cleanboot: input '$input' is not on ghcr.io — expected a FATAL naming it, got '$got'" >&2; rm -rf "$tmp"; return 1; } ;;
      *)      [ "$got" = "$want" ] && [ "$calls" = "manifest inspect ghcr.io/aps-conecta/all-in-one:$want" ] \
                || { echo "cleanboot: $kind '$val' input '$input' expected '$want', got '$got', docker: $calls" >&2; rm -rf "$tmp"; return 1; } ;;
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
one|v0.4.0|v0.0.0-ci.8|v0.0.0-ci.8
none|x|v0.0.0-ci.8|v0.0.0-ci.8
one|v0.4.0|fail|latest
one|v0.4.0|fail|v0.4.0;touch x
one|v0.4.0|absent|v0.0.0-ci.99
CASES
  rm -rf "$tmp"
}
check cleanboot_suite_tag_cases

# Clean boot (by IP) asserts Territorio carries the site's comuna and NO tile_url. The step is a YAML block
# no runner has run until CI does, so its script is extracted and run here over a stubbed occ: absent (occ
# exits 1, as for a key that was never set) and stored-empty (exit 0, no value) both pass; a stored value, a
# wrong comuna_cut and a missing comuna_name each fail.
cleanboot_tile_url_cases() {
  local script tmp rc
  script="$(awk '/- name: Territorio carries the site.s comuna and no tile_url/ {f=1; next}
                 f && /run: \|/ {r=1; next}
                 r && /^          / {sub(/^          /, ""); print; next}
                 r {exit}' .github/workflows/cleanboot.yml | grep -v 'source scripts/env.sh')"
  [ -n "$script" ] || { echo "cleanboot: the comuna / tile_url step was not found" >&2; return 1; }
  tmp="$(mktemp -d)"; printf 'SITE_COMUNA="Comuna Prueba"\nSITE_COMUNA_CUT=09999\n' > "$tmp/site.sh"
  while IFS='|' read -r tile cut name want; do
    ( cd "$tmp" && RUNNER_TEMP="$tmp" TILE="$tile" CUT="$cut" NAME="$name" bash -e -o pipefail -c '
        occ() { [ "$1 $2" = "config:app:get territorio" ] || return 2
          case "$3" in
            comuna_cut) printf "%s\n" "$CUT" ;;
            comuna_name) printf "%s\n" "$NAME" ;;
            tile_url) case "$TILE" in absent) return 1 ;; empty) return 0 ;; *) printf "%s\n" "$TILE" ;; esac ;;
          esac; }
        eval "$1"' _ "$script" ) >/dev/null 2>&1
    rc=$?
    case "$want" in pass) [ "$rc" -eq 0 ] ;; fail) [ "$rc" -ne 0 ] ;; esac \
      || { echo "cleanboot: tile_url=$tile cut=$cut name=$name expected $want, got rc=$rc" >&2; rm -rf "$tmp"; return 1; }
  done <<'CASES'
absent|09999|Comuna Prueba|pass
empty|09999|Comuna Prueba|pass
https://x/tiles/chile.pmtiles|09999|Comuna Prueba|fail
absent|01234|Comuna Prueba|fail
absent|09999||fail
CASES
  rm -rf "$tmp"
}
check cleanboot_tile_url_cases

# The usage record's python, out of cleanboot.yml and over a stub df that prints GNU's real header
# (8 words for 7 columns), a source seen twice and a mount point with a space: the record is
# written, one row per source, each named by the columns asked for.
cleanboot_usage_cases() {
  local py tmp rc
  py="$(awk '/- name: The measured usage/ {f=1; next}
             f && /<<.PY.$/ {r=1; next}
             r && /^ *PY$/ {exit}
             r {sub(/^          /, ""); print}' .github/workflows/cleanboot.yml)"
  [ -n "$py" ] || { echo "cleanboot: the usage record's python was not found" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir "$tmp/bin"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/docker"
  printf '#!/bin/sh\nprintf "%%s\\n" "Filesystem Type 1B-blocks Used Avail Use%% Mounted on" "/dev/sda1 ext4 100 40 60 40%% /" "/dev/sda1 ext4 100 40 60 40%% /var/lib/docker" "/dev/sdb1 ext4 100 10 90 10%% /mnt/with space"\n' > "$tmp/bin/df"
  chmod +x "$tmp/bin/docker" "$tmp/bin/df"
  PATH="$tmp/bin:$PATH" python3 - "$tmp/uso.json" <<<"$py" >/dev/null 2>&1; rc=$?
  python3 -c '
import json, sys
disco = json.load(open(sys.argv[1], encoding="utf-8"))["disco"]
assert len(disco) == 2 and all("source" in d and "target" in d for d in disco), disco
assert disco[1]["target"] == "/mnt/with space", disco' "$tmp/uso.json" >/dev/null 2>&1 && [ "$rc" -eq 0 ] \
    || { echo "cleanboot: the usage record was not written as one row per source (rc=$rc)" >&2; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}
check cleanboot_usage_cases

# Both clean-boot jobs read the installed suite's database with scripts/cleanboot-db.sh (#44 on a whole install).
# Run here over a stubbed docker: a ready database passes; no tag, the wrong image, vector missing, a buscador
# role missing or able to log in when it must not, a worker privilege, or no relation read at all each fail;
# a database image without /aps-roles.sh (a tag older than #44) passes with a notice naming the tag, but only
# once psql has answered.
cleanboot_db_cases() {
  local tag img ext roles priv roles_sh down want out rc
  local ok_img=ghcr.io/aps-conecta/aio-postgresql:v0.0.0-ci.8
  while IFS='|' read -r tag img ext roles priv roles_sh down want; do
    [ "$img" != ok ] || img="$ok_img"
    out="$(IMG="$img" EXT="$ext" ROLES="$roles" PRIV="$priv" ROLES_SH="$roles_sh" DOWN="$down" bash -c '
        docker() {
          case "$1" in
            inspect) [ -n "$IMG" ] && printf "%s\n" "$IMG" ;;
            exec) case "$*" in
                *"test -e /aps-roles.sh"*) [ "$ROLES_SH" = yes ] ;;
                *pg_extension*) [ "$DOWN" != yes ] && printf "%s\n" "$EXT" ;;
                *pg_roles*) [ "$DOWN" != yes ] && printf "%s\n" "$ROLES" ;;
                *has_table_privilege*) [ "$DOWN" != yes ] && printf "%s\n" "$PRIV" ;;
                *) return 3 ;;
              esac ;;
            *) return 3 ;;
          esac; }
        export -f docker
        bash scripts/cleanboot-db.sh "$1"' _ "$tag" 2>&1)"; rc=$?
    case "$want" in
      pass)   [ "$rc" -eq 0 ] && ! grep -q '::notice::' <<<"$out" ;;
      notice) [ "$rc" -eq 0 ] && grep -q "::notice::.*$tag" <<<"$out" ;;
      fail)   [ "$rc" -ne 0 ] ;;
    esac || { printf 'cleanboot-db: tag=%s img=%s ext=%s roles=%s priv=%s aps-roles=%s down=%s expected %s, got rc=%s:\n%s\n' \
                "$tag" "$img" "$ext" "$roles" "$priv" "$roles_sh" "$down" "$want" "$rc" "$out" >&2; return 1; }
  done <<'CASES'
v0.0.0-ci.8|ok|plpgsql unaccent vector|bd_owner:false bd_worker:true|0 152|yes|no|pass
|ok|plpgsql unaccent vector|bd_owner:false bd_worker:true|0 152|yes|no|fail
v0.0.0-ci.8|ghcr.io/aps-conecta/aio-postgresql:v0.4.0|plpgsql unaccent vector|bd_owner:false bd_worker:true|0 152|yes|no|fail
v0.0.0-ci.8||plpgsql unaccent vector|bd_owner:false bd_worker:true|0 152|yes|no|fail
v0.0.0-ci.8|ok|plpgsql unaccent|bd_owner:false bd_worker:true|0 152|yes|no|fail
v0.0.0-ci.8|ok|plpgsql unaccent vector|bd_owner:false|0 152|yes|no|fail
v0.0.0-ci.8|ok|plpgsql unaccent vector|bd_owner:true bd_worker:true|0 152|yes|no|fail
v0.0.0-ci.8|ok|plpgsql unaccent vector|bd_owner:false bd_worker:true|1 152|yes|no|fail
v0.0.0-ci.8|ok|plpgsql unaccent vector|bd_owner:false bd_worker:true|0 0|yes|no|fail
v0.0.0-ci.8|ok|plpgsql|||no|no|notice
v0.0.0-ci.8|ok|plpgsql|||no|yes|fail
CASES
}
check cleanboot_db_cases


# --- office-smoke's DS pin: the running DocumentServer is the one the Dockerfile pins (#140) -------
# The real office-smoke (and the env.sh it sources) runs from a fixture tree whose
# Containers/eurooffice/Dockerfile is the real one with a synthetic pin, v1.2.3: a hard-coded
# version reds, and so does a FROM line whose shape the parse no longer reads. A stub docker
# answers apache's loopback posture, the connector enabled and --check with $DS_VERSION; a stub
# curl answers the healthcheck. 9.3.1.37 is what the copied v0.6.0 image answers.
office_pin_cases() {
  local tmp out rc ver want
  tmp="$(mktemp -d)"; mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/Containers/eurooffice"
  cp scripts/office-smoke.sh scripts/env.sh "$tmp/scripts/"
  sed 's|documentserver:v[0-9][0-9.]*|documentserver:v1.2.3|' Containers/eurooffice/Dockerfile > "$tmp/Containers/eurooffice/Dockerfile"
  cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ps -q"*) echo ds0 ;;
  ps*) echo aps-conecta-nextcloud ;;
  inspect*aps-conecta-apache*) printf 'APACHE_PORT=11000\n' ;;
  "inspect ds0"*) echo ghcr.io/aps-conecta/aio-eurooffice:v0.0.0-ci.0 ;;
  *"config:app:get eurooffice enabled"*) echo yes ;;
  *"eurooffice:documentserver --check"*) echo "Document server http://x/ version $DS_VERSION is successfully connected" ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/curl"
  chmod +x "$tmp/bin/docker" "$tmp/bin/curl"
  while IFS='|' read -r ver want; do
    rc=0; out="$(PATH="$tmp/bin:$PATH" DS_VERSION="$ver" bash "$tmp/scripts/office-smoke.sh" 2>&1)" || rc=1
    [ "$rc" = "$want" ] \
      || { echo "office pin: DS $ver against the pin 1.2.3 exited $rc, want $want: $out" >&2; rm -rf "$tmp"; return 1; }
  done <<'CASES'
1.2.3.37|0
1.2.3|0
1.2.30.1|1
9.3.1.37|1
CASES
  rm "$tmp/Containers/eurooffice/Dockerfile"
  rc=0; out="$(PATH="$tmp/bin:$PATH" DS_VERSION=1.2.3.37 bash "$tmp/scripts/office-smoke.sh" 2>&1)" || rc=1
  rm -rf "$tmp"
  [ "$rc" = 1 ] && case "$out" in *"could not read the document server pin"*) ;; *) false ;; esac \
    || { echo "office pin: no Dockerfile must fail closed naming the pin, got exit $rc: $out" >&2; return 1; }
}
check office_pin_cases

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
# The console's last lines and step 7 send staff to GUIA §10; the English twin is INSTALLER §13. The
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
en = section(open("aps/INSTALLER.md", encoding="utf-8").read(), "\n## 13. Without a domain: this server\x27s IP\n")
es = section(open("aps/GUIA-CLINICA.md", encoding="utf-8").read(), "\n## 10. Sin dominio: la dirección IP del servidor\n")
if not twins(en, es): print("INSTALLER §13 and GUIA §10 are missing or carry different commands"); sys.exit(1)
if "aps/GUIA-CLINICA.md §10" not in open("host/aps-conecta", encoding="utf-8").read(): print("the console does not point at GUIA §10"); sys.exit(1)
if "(guía, §10)" not in open("scripts/provisionador.py", encoding="utf-8").read(): print("step 7 does not point at GUIA §10"); sys.exit(1)
if twins("## 14. x\n```\na\n```\n", "## 11. y\n```\nb\n```\n"): print("a drifted pair passed"); sys.exit(1)
if twins("## 14. x\n- **A**\n```\na\n```\n", "## 11. y\n```\na\n```\n"): print("a pair missing a bullet passed"); sys.exit(1)
print("ok")'

# --- org L5-11/L5-05/L5-12: the provisioning self-tests (hermetic) ----------------------------
# standings.sh: the one uid derivation's fixture parity; env.sh: the loader/compose
# round-trip (its compose-parity arm self-skips — no compose.yaml moved — and the container arms
# run on a stub docker); usuarios.sh: the frame guards; apps.py: the suite manifest's shape and
# that every container it names is defined.
check bash provisioning/standings.sh --self-test
check python3 scripts/apps.py --self-test
# releases.py (#33): the app-release resolver — resolve/fetch/lock over a local fixture hub with
# a throwaway key, real redirects and real signify crypto. The signer rides along in the CI job
# already (package-release's self-test needs it); locally its absence is an honest skip, the
# same shape as package-release's arm below.
if command -v signify >/dev/null 2>&1; then
  check python3 scripts/releases.py --self-test
else
  echo "  skipped: releases --self-test (no signify — sudo apt-get install signify-openbsd)"
fi
# brand-tokens.py (#49): the wizard's brand-token projection — pure stdlib, runs everywhere.
check python3 scripts/brand-tokens.py --self-test
# vm-acceptance.sh (#54): the ticket's own acceptance, on a scratch Ubuntu 24.04 VM — the
# self-test pins the classification arms (bootstrap markers, the release five, the store rows,
# the OCS/status answers, the revisar posture, the absent buscador row) against PATH shims:
# no root, no docker, no network. The VM run itself is the release ritual's, not CI's
# (aps/RELEASING.md §7).
check bash scripts/vm-acceptance.sh --self-test
# wizard-fonts.py (#49): the wizard's font subsets' coverage — needs fontTools, which ci.yml's
# gate job installs for row 270; a box without it gets the honest skip (the gate row itself
# fails loudly there, never passes vacuously — the same stance as the tool's import exit).
if python3 -c "import fontTools, brotli" >/dev/null 2>&1; then
  check python3 scripts/wizard-fonts.py --self-test
else
  echo "  skipped: wizard-fonts --self-test (no fontTools — pip install fonttools brotli)"
fi
# #66: the manifest-read failure is said in ONE place — apps.py's own stderr line, which every
# reader already shows beside it (a command substitution captures stdout only). No reader may
# carry its own copy of the old narration again, and no reader gets a field it discards: `lines`
# (id, source, repo — its only reader dropped the source column) is retired for `repos`, whose
# output the self-test pins. This sweep skips its own needles (scripts/test.sh).
check python3 -c '
import pathlib, sys
NEEDLES = (
    ("apps.py lines", "still calls the retired subcommand (its only reader discarded the source column)"),
    ("could not read the suite manifest", "carries a copy of the manifest-failure narration"),
    ("(apps.json) is unreadable", "carries a copy of the manifest-failure narration"),
)
for path in sorted(p for p in pathlib.Path(".").rglob("*")
                   if p.is_file() and ".git" not in p.parts and "__pycache__" not in p.parts
                   and p != pathlib.Path("scripts/test.sh")                 # this sweep itself
                   and p.stat().st_size < 500_000):                           # skip large binaries
    text = path.read_text(encoding="utf-8", errors="ignore")
    for needle, why in NEEDLES:
        if needle in text:
            print(f"{path}: {why} — apps.py says the failure once, on stderr, beside every reader"); sys.exit(1)
print("ok")'
check bash scripts/env.sh --self-test
# #163: both gates curl the suite's public URL — by IP with the installer's CA — never .env's HTTP_PORT
# (set to the template's 8180 here). Each gate runs against a stub docker (apache on 443 by IP; checks
# 1-4 and the connector answer) and a stub curl that records its argv and answers nothing; the gate's
# FIRST curl is asserted, whatever its verdict.
public_url_cases() {
  local tmp gate first
  tmp="$(mktemp -d)"; mkdir "$tmp/bin"; : > "$tmp/ca.crt"
  cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  ps*) echo aps-conecta-nextcloud ;;
  inspect*aps-conecta-apache*) printf 'APACHE_PORT=443\nNC_DOMAIN=203.0.113.10\n' ;;
  *"occ status"*) echo '{"installed":true}' ;;
  *"config:app:get eurooffice enabled"*) echo yes ;;
  *redis-cli*) echo PONG ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CURL_LOG"\nexit 7\n' > "$tmp/bin/curl"
  chmod +x "$tmp/bin/docker" "$tmp/bin/curl"
  for gate in smoke:/status.php office-smoke:/eurooffice/healthcheck; do
    : > "$tmp/curl.log"
    PATH="$tmp/bin:$PATH" CURL_LOG="$tmp/curl.log" SUITE_CA="$tmp/ca.crt" HTTP_PORT=8180 \
      bash "scripts/${gate%%:*}.sh" >/dev/null 2>&1
    first="$(head -1 "$tmp/curl.log")"
    case " $first " in
      *" --cacert $tmp/ca.crt "*" https://203.0.113.10${gate#*:} "*|*" https://203.0.113.10${gate#*:} "*" --cacert $tmp/ca.crt "*) ;;
      *) echo "public URL: ${gate%%:*}'s first curl is «$first», not https://203.0.113.10${gate#*:} with the CA" >&2; rm -rf "$tmp"; return 1 ;;
    esac
  done
  rm -rf "$tmp"
}
check public_url_cases
# #197: the template ships no Nextcloud container and no caller restates its default or guards it
# (`:-` `-` `:?` `?`) — env.sh section 3 is the one place it is decided. git grep exits 1 on no
# match and 128 on error, so only a real "none found" passes (a tree without git is red, not green).
check bash -c '! grep -q "^NC_CONTAINER=" .env.example && { git grep -qE "NC_CONTAINE[R]:?[?-]" -- . ":!scripts/env.sh"; [ $? -eq 1 ]; }'
check bash provisioning/usuarios.sh --self-test

echo "== self-tests (hermetic — no docker, no stack) =="
# The Provisionador's own --self-test (its stub oracle rides --self-test, so the runner needs no
# docker), the host bundle's, and the migration tool's run everywhere test.sh runs — every
# PR, any box — because none needs a stack. The bootstrap's joins them (fixture packages and PATH
# shims only), and so does the signer's — the one self-test that needs signify installed, because
# it is real crypto over a throwaway keypair; CI apt-installs the same package the clinic verifies
# with, and a box without it gets the honest skip. Output is captured, not drowned: a green arm
# prints its own last line, a red one its tail — the #96 lesson, a red log must carry its diagnosis.
# A waived run must SAY so in this log: the self-test prints "SKIPPED (waived …, NOT a pass)" once, but only its
# last line used to reach this output — so CI's log read "237 checks OK" and nothing of the browser arms that
# did not run. This echoes the waiver (with the count of arms) and nothing else of the self-test's output.
selftest_waivers() { printf '%s\n' "$1" | { grep -a "SKIPPED (waived" || true; } | sed 's/^ *//; s/^/  /'; }
selftest_waivers_cases() {
  local w
  w="$(selftest_waivers "$(printf '  ok:   1. x\n  SKIPPED (waived by X=1, NOT a pass): 16 browser arms did NOT run — y\nself-test: 237 checks OK\n')")"
  [ "$w" = "  SKIPPED (waived by X=1, NOT a pass): 16 browser arms did NOT run — y" ] || return 1
  [ -z "$(selftest_waivers "$(printf '  ok:   1. x\nself-test: 254 checks OK\n')")" ] || return 1
  selftest_waivers "$(printf 'self-test: 254 checks OK\n')" >/dev/null   # no waiver is not a failure: the caller chains on this status
}
check selftest_waivers_cases
st_out="$(python3 scripts/provisionador.py --self-test 2>&1)" \
  && { echo "  ok:   provisionador --self-test ($(printf '%s\n' "$st_out" | tail -1))"; selftest_waivers "$st_out"; } \
  || { echo "  FAIL: provisionador --self-test"; printf '%s\n' "$st_out" | tail -25; fail=1; }
hb_out="$(bash host/aps-conecta --self-test 2>&1)" \
  && echo "  ok:   host bundle --self-test ($(printf '%s\n' "$hb_out" | tail -1))" \
  || { echo "  FAIL: host bundle --self-test"; printf '%s\n' "$hb_out" | tail -25; fail=1; }
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
# The retag self-test rides the same capture-and-tail idiom: hermetic (a PATH-shim docker over
# a fixture registry, local git repos as the discovery catalogue — no network, no daemon), so
# it runs everywhere test.sh runs. A green arm prints its verdict line; a red one its tail.
rt_out="$(bash scripts/retag.sh --self-test 2>&1)" \
  && echo "  ok:   retag --self-test ($(printf '%s\n' "$rt_out" | tail -1))" \
  || { echo "  FAIL: retag --self-test"; printf '%s\n' "$rt_out" | tail -25; fail=1; }
# The built-set lockstep assert's own self-test (#76): jq over fixture needs documents — the
# same hermetic bar (no network, no runner), pinning the one-list walk where CI runs it.
lk_out="$(bash scripts/lockstep.sh --self-test 2>&1)" \
  && echo "  ok:   lockstep --self-test ($(printf '%s\n' "$lk_out" | tail -1))" \
  || { echo "  FAIL: lockstep --self-test"; printf '%s\n' "$lk_out" | tail -25; fail=1; }

echo "== smoke (only if a stack is running) =="
. scripts/env.sh
if is_aio; then
  if bash scripts/smoke.sh; then echo "  ok:   smoke"; else echo "  FAIL: smoke"; fail=1; fi
else
  echo "  skipped: no running AIO stack (static-only gate)"
fi

# Euro-Office joined the standard gate in #81, because it joined the stack: office-smoke was
# separate only because it needed a service that might not be running. Its rename assertions
# retired with the bake (#42): the white-label renames are COMMITS in the fork's own repo now,
# carried by its signed release, and the clean-boot greps the installed bytes on every run.
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
