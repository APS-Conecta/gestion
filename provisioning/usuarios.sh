#!/usr/bin/env bash
# The roster reader's bash half — closes gestion #106 from the Provisionador side (FRD S5).
# OWNER: installer-design slice 16; the python half lives in scripts/provisionador.py.
#
# The canonical roster (sites/<codigo>/usuarios.csv) and the sealed credentials sheet are BOTH
# quoted-CSV, and bash cannot parse quoted CSV without reimplementing csv.py badly — the exact
# reason scripts/deis.py is python. So python parses both and feeds this script ONE record per
# user on stdin, five lines each:
#
#     uid
#     display name          (nombre + apellidos, as the sheet carries it)
#     password              (the sealed one — never in this script's argv, only stdin)
#     grupos                (space-separated, canonical order, as the roster stores them)
#     primer                (si | no)
#
# terminated by one empty line. This script does only what bash is good at: ride the lib.sh
# helpers so the log verbs are EXACTLY the seed's own vocabulary (ensure_user's "user X created",
# add_user_to_group's "user X added to group Y" — what seed-idempotent greps) and the password
# reaches occ the only way it ever does here: -e OC_PASS on docker exec, --password-from-env
# reading it (lib.sh:169-172's precedent — the value rides the exec argv for the moment of the
# call, the container's own env stays clean for `docker inspect`).
#
# Runs AFTER the seed (the executor's order): phase 20 has already created every group the
# roster names, so the missing-group branch below is a loud skip, not an expected path. The
# primer admin's one job — the column exists for this — is joining the `admin` group the wizard
# created. NOT a phase file on purpose: no [0-9] prefix, so the seed's own glob never picks it
# up; the executor calls it explicitly between the seed and the divergence gate.
#
# Sourced from scripts/env.sh so occ()/NC_CONTAINER resolve exactly as the seed's phases see
# them. `set -e` is deliberately NOT used: errexit inside a sourced-function call site is the
# B-001 trap (the guard helpers' failures are checked explicitly instead), and every failing
# helper here already logs FAILED and returns non-zero, which this script propagates.
set -uo pipefail
USUARIOS_SELFTEST=0
[ "${1:-}" = "--self-test" ] && { USUARIOS_SELFTEST=1; shift; }
cd "$(dirname "$0")/.." || exit 1   # repo root — env.sh cds too; this is belt and braces
# org L5-12: dispatched BEFORE the sources — env.sh also answers --self-test, and a sourced
# script's case sees the caller's $1 first (measured: the env arms ran, these did not).

# shellcheck source=../scripts/env.sh
. scripts/env.sh
# shellcheck source=lib.sh
. provisioning/lib.sh

# org L5-12: the five-line frame was validated only on the WRITER side. Any second writer
# whose display name carries a newline shifts every subsequent record — ensure_user would
# create wrong accounts or fail on a garbage password. These guards mirror the writer's own
# rules (provisionador.py's UID_RE, the registry's group-id shape, the si/no column): the
# whole record is refused, because a shifted frame means every line after it is misread too.
frame_guard() {  # UID DISPLAY PASS GRUPOS PRIMER — refuses loudly on a bad record
  case "$1" in
    ''|*[!a-z0-9._-]*|[._-]*) echo "FATAL: registro inválido — uid «$1» no calza con la regla del escritor ([a-z0-9][a-z0-9._-]{0,63})" >&2; return 1 ;;
  esac
  [ "${#1}" -le 64 ] || { echo "FATAL: registro inválido — uid de ${#1} caracteres (máx. 64, la regla del escritor)" >&2; return 1; }
  [ -n "$2" ] || { echo "FATAL: registro inválido — display vacío para «$1» (¿un frame corrido?)" >&2; return 1; }
  [ -n "$3" ] || { echo "FATAL: registro inválido — password vacío para «$1»" >&2; return 1; }
  local g
  for g in $4; do  # shellcheck disable=SC2086  # same split as the loop below
    case "$g" in
      ''|*[!a-z0-9._-]*|[._-]*) echo "FATAL: registro inválido — grupo «$g» no calza con la forma de id del registro (uid «$1»)" >&2; return 1 ;;
    esac
  done
  case "$5" in
    si|no) ;;
    *) echo "FATAL: registro inválido — primer «$5» no es si|no (uid «$1»)" >&2; return 1 ;;
  esac
}

usuarios_main() {  # reads the five-line frame on stdin, exactly as provisionador sends it
local n=0
while IFS= read -r uid && [ -n "$uid" ]; do
  IFS= read -r display
  IFS= read -r pass
  IFS= read -r grupos
  IFS= read -r primer

  frame_guard "$uid" "$display" "$pass" "$grupos" "$primer" || exit 1

  ensure_user "$uid" "$display" "$pass" || { echo "FATAL: no se pudo crear el usuario $uid" >&2; exit 1; }
  for g in $grupos; do  # shellcheck disable=SC2086  # canonical order, already split by the writer — 40-acl.sh:26's precedent
    if group_exists "$g"; then
      add_user_to_group "$uid" "$g" || { echo "FATAL: no se pudo agregar $uid a $g" >&2; exit 1; }
    else
      log "group $g not provisioned — skipping for $uid (phase 20 must run first)"
    fi
  done
  if [ "$primer" = "si" ]; then
    # The primer_admin column's one job (slice 15): the clinic's named first admin joins the
    # wizard's own `admin` group. `admin` always exists on an installed instance, so the plain
    # add_user_to_group suffices — group_exists would only be theater here.
    add_user_to_group "$uid" admin || { echo "FATAL: no se pudo agregar $uid a admin" >&2; exit 1; }
  fi
  n=$((n + 1))
done
echo "== roster: $n usuario(s) =="
}

# org L5-12: run by default; the self-test below calls usuarios_main directly with the
# mutating helpers stubbed IN THIS PROCESS (a child bash would re-source the real lib.sh —
# measured: the good frame FAILED against docker from inside the self-test).
# org L5-12: the flag is cleared BEFORE the sources (env.sh answers --self-test too, and a
# sourced case sees the caller's $1 first — measured) and dispatched here, after every
# definition exists. The self-test stubs the mutating helpers IN THIS PROCESS and calls
# usuarios_main directly; a child bash would re-source the real lib.sh.
if [ "$USUARIOS_SELFTEST" = 1 ]; then
usuarios_self_test() {
  local log; log="$(mktemp)"
  ensure_user() { printf 'user %s created\n' "$1" >> "$log"; }
  group_exists() { return 0; }
  add_user_to_group() { printf 'user %s added to group %s\n' "$1" "$2" >> "$log"; }
  local rc=0 frame
  # good frame: one user, two groups, primer si
  frame="$(printf 'fixture.roster\nFixture Roster\nnot-a-real-password-either\nall-staff cat-jefaturas\nsi\n\n')"
  printf '%s' "$frame" | usuarios_main >/dev/null 2>&1 \
    || { echo "self-test FAIL: the good frame was refused" >&2; rc=1; }
  grep -q 'user fixture.roster created' "$log" || { echo "self-test FAIL: good frame did not create" >&2; rc=1; }
  grep -q 'user fixture.roster added to group admin' "$log" || { echo "self-test FAIL: primer si did not join admin" >&2; rc=1; }
  : > "$log"
  # corrupted: uid violates the writer's own rule
  printf 'Fixture.Bad\nX\np\ng\nno\n\n' | usuarios_main >/dev/null 2>&1 \
    && { echo "self-test FAIL: uppercase uid accepted" >&2; rc=1; }
  # corrupted: uid over the 64-char writer bound
  printf '%s\nX\np\ng\nno\n\n' "$(printf 'u%.0s' $(seq 1 65))" | usuarios_main >/dev/null 2>&1 \
    && { echo "self-test FAIL: 65-char uid accepted" >&2; rc=1; }
  # corrupted: an emptied display — the shape a shifted frame produces when the newline
  # lands the pass line where display should be and nothing follows to fill it
  printf 'fixture.two\n\nnot-a-real-password\nall-staff\nno\n\n' | usuarios_main >/dev/null 2>&1 \
    && { echo "self-test FAIL: empty display accepted (shifted frame)" >&2; rc=1; }
  # corrupted: grupos carries a non-id token
  printf 'fixture.ok\nX\np\nall-staff; DROP\nno\n\n' | usuarios_main >/dev/null 2>&1 \
    && { echo "self-test FAIL: malformed group token accepted" >&2; rc=1; }
  # corrupted: primer not si|no
  printf 'fixture.ok\nX\np\nall-staff\nsí\n\n' | usuarios_main >/dev/null 2>&1 \
    && { echo "self-test FAIL: primer «sí» accepted" >&2; rc=1; }
  [ -s "$log" ] && { echo "self-test FAIL: a corrupted frame still created users:" >&2; cat "$log" >&2; rc=1; }
  rm -f "$log"
  [ "$rc" = 0 ] && echo "self-test: usuarios.sh frame arms OK"
  return "$rc"
}
  usuarios_self_test
  exit $?
fi
usuarios_main

