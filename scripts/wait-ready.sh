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

ready && exit 0

# Ten minutes: a first boot pulls no images (compose did that) but does create the schema. CI's own
# loop allowed the same, and it has never needed more.
printf 'waiting for Nextcloud to finish installing itself'
for _ in $(seq "${WAIT_READY_TRIES:-120}"); do
  sleep 5
  printf '.'
  if ready; then printf ' ready\n'; exit 0; fi
done

printf '\n'
echo "FATAL: Nextcloud did not finish installing in 10 minutes." >&2
docker compose logs --tail=50 nextcloud >&2
exit 1
