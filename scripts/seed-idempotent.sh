#!/usr/bin/env bash
# Idempotency gate — a SECOND seed must not write anything. Run it right AFTER `make seed`;
# it runs one more and reads the log. AD-2 makes this the pipeline's defining property: `make seed`
# applies desired state, so on an already-provisioned instance it has nothing left to do.
#
# THE LOG IS THE ASSERTION. Every mutating helper in lib.sh prints a different verb for "wrote"
# than for "was already right", so the absence of the write verbs is the whole check. One helper is
# exempt by design: theming_image_set logs `<-` and re-registers the brand images every run, because
# theming:config stores a mime and not a path (see lib.sh, "Brand images").
#
# This is also what makes lib.sh's per-phase caches safe to trust: they answer "is it already there?"
# from memory, and a wrong answer surfaces here as a write that should not have happened.
set -uo pipefail

# cd to the repo root + load .env. See scripts/env.sh.
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

# Match the fixture setting of the seed that just ran, inferred from the instance so no state is
# carried between runs: absent fixture users mean phases 50/60 did not run and must not run now.
# Without this, a gate run after a SEED_FIXTURES=0 seed created the standing accounts for the FIRST
# time and then reported those correct creations as a failure. (The seed that used to do that was
# `make office-eurooffice`, deleted by #81; the inference is kept because any caller can set it.)
# An explicit SEED_FIXTURES always wins.
if [ -z "${SEED_FIXTURES:-}" ]; then
  if occ user:info director >/dev/null 2>&1; then
    SEED_FIXTURES=1
  else
    SEED_FIXTURES=0
  fi
  echo "SEED_FIXTURES not set — inferred ${SEED_FIXTURES} from the instance (fixture users $([ "$SEED_FIXTURES" = 1 ] && echo present || echo absent))"
fi
export SEED_FIXTURES

# Write verbs, in lib.sh order: config/theming/restrict/disable/grant and app enable/unpack (`->`),
# group + user + groupfolder + file + subfolder creation, group membership, schema reconcile after a
# re-imposed unpack, signature drop (12-apps.sh), patch application.
# `patch X applied` is anchored to two fields so it cannot match the skip line, `patch X already
# applied`.
WRITES=' -> | created| added to group| schema reconciled | signature dropped |^ +patch [^ ]+ applied$'

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
