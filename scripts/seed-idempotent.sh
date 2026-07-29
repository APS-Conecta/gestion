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
