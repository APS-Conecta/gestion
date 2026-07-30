#!/usr/bin/env bash
# Idempotency gate — a SECOND seed must not write anything. Run it right AFTER `make seed`;
# it runs one more and reads the log. AD-2 makes this the pipeline's defining property: `make seed`
# applies desired state, so on an already-provisioned instance it has nothing left to do.
#
# THE LOG IS THE ASSERTION. Every mutating helper in provisioning/lib.sh prints a different verb
# for "wrote" than for "was already right", so the absence of the write verbs is the whole check —
# no extra state to inspect, and nothing to keep in sync with the helpers but the patterns below.
#
# One helper is exempt on purpose: theming_image_set logs `<-` and re-registers the four brand
# images every run by design — theming:config stores a mime, not a path, so a query-before-set
# there would mean an edited SVG never reaches the instance (see lib.sh, "Brand images").
#
# This is also what makes lib.sh's per-phase caches safe to trust. They answer "is it already
# there?" from memory instead of from the server; a wrong answer surfaces here as a write that
# should not have happened, or as a missing one that shows up as a second-run write.
set -uo pipefail

# cd to the repo root + load .env. See scripts/env.sh.
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

# Match the fixture setting of the seed that just ran. seed.sh defaults SEED_FIXTURES to 1, so a gate
# run after `make office-eurooffice` (whose recipe is SEED_FIXTURES=0) used to run phases 50 and 60
# for the FIRST time: it created the four dev.* accounts on an instance the operator had deliberately
# kept fixture-free, then reported those correct creations as an idempotency failure.
#
# Inferred from the instance rather than remembered, so no state has to be carried between runs: if
# the fixture users are absent, phases 50/60 did not run and must not run now. An explicit
# SEED_FIXTURES always wins.
if [ -z "${SEED_FIXTURES:-}" ]; then
  if docker compose exec -T --user www-data nextcloud php occ user:info dev.direccion >/dev/null 2>&1; then
    SEED_FIXTURES=1
  else
    SEED_FIXTURES=0
  fi
  echo "SEED_FIXTURES not set — inferred ${SEED_FIXTURES} from the instance (fixture users $([ "$SEED_FIXTURES" = 1 ] && echo present || echo absent))"
fi
export SEED_FIXTURES

# Write verbs, in lib.sh order: config/theming/restrict/disable/grant (`->`), group + user +
# groupfolder + file + subfolder creation, group membership, app install, patch application.
# `patch X applied` is anchored to two fields so it cannot match the skip line, `patch X already
# applied`.
WRITES=' -> | created| added to group|installed/enabled|^ +patch [^ ]+ applied$'

out="$(provisioning/seed.sh 2>&1)"; rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: the second seed did not complete (exit $rc)"; exit 1; }

writes="$(printf '%s\n' "$out" | grep -E "$WRITES")"
if [ -n "$writes" ]; then
  echo
  echo "FAIL: the second seed wrote. These lines must not appear on an already-provisioned instance:"
  printf '%s\n' "$writes"
  exit 1
fi

echo
echo "PASS: the second seed wrote nothing — provisioning is idempotent"
