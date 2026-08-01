#!/usr/bin/env bash
# Wait until Nextcloud has finished installing ITSELF. `docker compose up -d` returns when the
# containers start; the official image then runs its own installer, which takes ~90 s on first boot
# and is why `make seed` used to fail with "not installed/reachable" if you were quick.
#
# It lives here and `make up` runs it, so there is one copy: CI carried its own nine-line loop, and a
# human running `make smoke` by hand simply raced. Silent and instant on an already-installed stack.
set -uo pipefail

# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

ready() { occ status --output=json 2>/dev/null | grep -q '"installed":true'; }

# `installed:true` means the installer FINISHED, not that Nextcloud stopped writing — it keeps
# setting config of its own (`maintenance_window_start`, `default_language`) for a few seconds after.
# Provisioning inside that window loses whichever key it wrote first, and the second seed then
# rewrites it: #96, where three CI runs failed on two DIFFERENT keys and passed once. So wait for the
# config to stop moving, which is the surface that actually broke. Self-scaling by construction — a
# fast machine settles fast, a slow one waits longer, and it was machine speed that hid this (CI
# reached installed:true in 15 s, a dev laptop in 35 s).
settled() { occ config:list --output=json 2>/dev/null | sha256sum; }

quiesce() {
  local prev cur i
  prev="$(settled)"
  for i in $(seq "${WAIT_SETTLE_TRIES:-24}"); do
    sleep 5
    cur="$(settled)"
    [ "$cur" = "$prev" ] && return 0
    printf '~'   # config still moving
    prev="$cur"
  done
  echo >&2
  echo "FATAL: Nextcloud config never stopped changing (2 minutes after install)." >&2
  return 1
}

# Only reached on a COLD boot. A warm stack is already quiesced by definition, and `make up` runs on
# every dev loop — making it pay for the settle check daily would buy nothing.
ready && exit 0

# Ten minutes: a first boot pulls no images (compose did that) but does create the schema. CI's own
# loop allowed the same, and it has never needed more.
printf 'waiting for Nextcloud to finish installing itself'
for _ in $(seq "${WAIT_READY_TRIES:-120}"); do
  sleep 5
  printf '.'
  if ready; then
    quiesce || exit 1
    printf ' ready\n'; exit 0
  fi
done

printf '\n'
echo "FATAL: Nextcloud did not finish installing in 10 minutes." >&2
docker compose logs --tail=50 nextcloud >&2
exit 1
