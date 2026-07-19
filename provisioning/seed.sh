#!/usr/bin/env bash
# provisioning/seed.sh — the single idempotent provisioning runner (Story 0.5, AD-2).
# Invoked by `make seed`. Requires an installed stack, then applies desired state by sourcing the
# numbered phase files under phases/ in fixed order (10 -> 60). Idempotent: safe to re-run.
# Fixture phases (>= 50) are skipped when SEED_FIXTURES=0 (the structure-vs-fixtures partition).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SEED_FIXTURES="${SEED_FIXTURES:-1}"

echo "== APS Conecta provisioning (make seed) =="
require_installed
# Idempotent framework marker — exercises the query-before-write guard on every run.
config_app_set provisioning framework_version 1

run=0; skipped=0
for phase in "$HERE"/phases/[0-9]*.sh; do
  [ -e "$phase" ] || continue
  num="$(basename "$phase" | grep -oE '^[0-9]+')"
  if [ "$num" -ge 50 ] && [ "$SEED_FIXTURES" != "1" ]; then
    echo "▷ skipping $(basename "$phase") (SEED_FIXTURES=0)"; skipped=$((skipped + 1)); continue
  fi
  # Run each phase in a subshell with `set -e` for fault isolation: a failing phase stops the run
  # (named), and no phase can leak shell state into the next — cross-phase state goes through
  # Nextcloud and is re-queried by the guard helpers (AD-2), never via shell vars.
  if ! ( set -e; . "$phase" ); then
    echo "FATAL: phase $(basename "$phase") failed" >&2
    exit 1
  fi
  run=$((run + 1))
done

echo "== provisioning complete — ${run} phase(s) run, ${skipped} skipped =="
