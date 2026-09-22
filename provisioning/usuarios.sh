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
cd "$(dirname "$0")/.." || exit 1   # repo root — env.sh cds too; this is belt and braces
# shellcheck source=../scripts/env.sh
. scripts/env.sh
# shellcheck source=lib.sh
. provisioning/lib.sh

n=0
while IFS= read -r uid && [ -n "$uid" ]; do
  IFS= read -r display
  IFS= read -r pass
  IFS= read -r grupos
  IFS= read -r primer

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
