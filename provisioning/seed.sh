#!/usr/bin/env bash
# provisioning/seed.sh — the single idempotent provisioning runner (Story 0.5, AD-2).
# Invoked by `make seed`. Requires an installed stack, then applies desired state by sourcing the
# numbered phase files under phases/ in fixed order (05 -> 60). Idempotent: safe to re-run.
# Fixture phases (>= 50) are skipped when SEED_FIXTURES=0 (the structure-vs-fixtures partition).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# env.sh FIRST: it cds to the repo root, loads .env the way compose reads it, and defines occ(),
# which every helper in lib.sh calls.
# shellcheck source=../scripts/env.sh
. "$HERE/../scripts/env.sh"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SEED_FIXTURES="${SEED_FIXTURES:-1}"

# The clinic this stack serves (#78). SITE names a directory under sites/ and arrives from .env like
# every other setting. Sourced HERE, in the parent shell: each phase runs in a subshell of this one,
# so all of it is visible to every phase and none of it can leak back out.
require_site || exit 1
# shellcheck disable=SC1090  # the path is SITE, resolved at run time
. "$HERE/../sites/$SITE/site.sh" || { echo "FATAL: sites/$SITE/site.sh failed to load" >&2; exit 1; }

echo "== APS Conecta provisioning (make seed) =="
require_installed

run=0; skipped=0
for phase in "$HERE"/phases/[0-9]*.sh; do
  # A glob that matches nothing stays literal. This used to be `|| continue`, which turned "the
  # phases directory is gone" into `0 phase(s) run` and exit 0 — a green run that provisioned
  # nothing. Same detection, opposite conclusion.
  [ -e "$phase" ] || { echo "FATAL: no phase files matched $HERE/phases/[0-9]*.sh" >&2; exit 1; }
  num="${phase##*/}"; num="${num%%-*}"
  if [ "$num" -ge 50 ] && [ "$SEED_FIXTURES" != "1" ]; then
    echo "▷ skipping $(basename "$phase") (SEED_FIXTURES=0)"; skipped=$((skipped + 1)); continue
  fi
  # Run each phase in a subshell with `set -e` for fault isolation: a failing phase stops the run
  # (named), and no phase can leak shell state into the next — cross-phase state goes through
  # Nextcloud and is re-queried by the guard helpers (AD-2), never via shell vars.
  #
  # Run the subshell as its OWN command and test $? afterwards. Do NOT fold it back into
  # `if ! ( set -e; . "$phase" ); then` — bash suppresses errexit inside a command used as an `if`
  # condition, and the suppression reaches into the subshell, so `set -e` there becomes a no-op: the
  # phase runs past its first failure and reports success. That silently skipped every group folder
  # and the whole ACL matrix on a real run.
  ( set -e; . "$phase" )
  if [ $? -ne 0 ]; then
    echo "FATAL: phase $(basename "$phase") failed" >&2
    exit 1
  fi
  run=$((run + 1))
done

echo "== provisioning complete — ${run} phase(s) run, ${skipped} skipped =="
