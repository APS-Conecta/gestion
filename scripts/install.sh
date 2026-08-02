#!/usr/bin/env bash
# `make install` — the one command (#79). Idempotent by construction: the first run installs, every
# later run converges on whatever the repo and the site file now say. Run it after editing
# sites/<slug>/site.sh, and after `git pull`.
#
# What it deliberately does NOT do: pull a newer Nextcloud image (the digests are pinned — #109,
# bumped by `make images`) or run `occ app:update` (ADR-0002 refuses it — it reverts our patches and
# restores signature.json). Moving the platform under a live clinic needs a window and a rollback
# story, so it stays a deliberate separate act.
#
# And it never DELETES (#85). It converges everything reversible — memberships, grants, config — and
# only reports what is live but no longer declared, because the three operations that lose content
# (group folders, users, files) must never be automatic and there is no backup story to gate them on.
#
# It refuses rather than bootstraps: .env holds passwords no script can invent, and a clinic needs
# answers only a human has.
set -uo pipefail

# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"
require_site || exit 1

LOG=.install.log

printf '▸ stack\n'
make --no-print-directory up || exit 1

# The phase log is the operator-facing register, so it goes to the file and only the phase names
# reach the terminal. Nothing is prettified away — `make seed` still prints all of it, which is what
# seed-idempotent.sh runs and greps.
printf '▸ provisioning — full log: %s\n' "$LOG"
provisioning/seed.sh 2>&1 | tee "$LOG" | sed -n 's/^▶ phase [0-9]*-\([a-z-]*\).*/    \1/p'
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  echo
  echo "✗ provisioning failed. Last 20 lines of $LOG:" >&2
  tail -20 "$LOG" >&2
  echo >&2
  echo "  Re-run it: make install — everything already applied is skipped in seconds." >&2
  exit 1
fi

# Counted from the site file rather than from the log: these are the numbers that WERE applied, and
# they cannot drift from a log format.
# shellcheck disable=SC1090  # the path is SITE, resolved at run time
. "sites/$SITE/site.sh"
printf '\n✓ %s — %d teams, %d group folders, %d grants\n' \
  "$SITE_NOMBRE_CORTO" "${#SITE_TEAMS[@]}" "${#SITE_FOLDERS[@]}" "${#SITE_ACL[@]}"

if bash scripts/smoke.sh >>"$LOG" 2>&1; then
  printf '  health: PASS\n'
else
  printf '  health: FAIL — see %s\n' "$LOG"
fi
printf '  http://localhost:%s\n' "$HTTP_PORT"

# What is live that the repo no longer declares (#85). Printed HERE rather than from inside the
# seed, for two reasons. The phases write and this reads, so it does not belong among them. And the
# seed's output goes to $LOG — only phase names reach the terminal — so a report printed there would
# be seen by nobody, which is the one thing a report cannot afford.
#
# --quiet, so a clean install ends clean. It exits 0 whatever it finds — see scripts/divergence.sh.
bash scripts/divergence.sh --quiet
