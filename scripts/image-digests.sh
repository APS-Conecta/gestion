#!/usr/bin/env bash
# Keep the pinned image digests honest (#109).
#
#   scripts/image-digests.sh --validate every image is pinned and well formed (no network)
#   scripts/image-digests.sh --check    report drift, change nothing, exit 1 if any moved
#   scripts/image-digests.sh            rewrite every pin to what its tag points at TODAY
#
# --validate and --check answer different questions and only one belongs on a PR. "Is every image
# pinned?" must be true of every commit. "Is every pin the newest?" must NOT gate a PR — a tag
# moving upstream has nothing to do with the branch, and wiring it to the PR would turn an unrelated
# change red and train everyone to ignore the check that matters.
#
# WHY THE PINS EXIST. Rolling tags meant two clinics installed a fortnight apart ran different
# software while both looked identical — measured 2026-08-01, `nextcloud:34-apache` and
# `redis:8-alpine` had BOTH moved since this repo's own box pulled them. That is #96 made permanent
# by a fleet. The digest is the only name for "the version I tested".
#
# NOT AUTOMATIC ALL THE WAY: the weekly workflow runs --check, a human runs the rewrite, and the PR
# is where cleanboot boots the new bytes. Why no bot opens it: .github/workflows/image-digests.yml.
set -uo pipefail
cd "$(dirname "$0")/.."

# Every file that names an image. Both, always: Dockerfile.dev deriving from a different build than
# compose.yaml runs is #96 on the one image where it is hardest to notice.
FILES=(compose.yaml Dockerfile.dev host/tiles.sh)

check_only=0; validate_only=0
case "${1:-}" in
  --check)    check_only=1 ;;
  --validate) validate_only=1 ;;
  "")         ;;
  *) echo "usage: $0 [--check|--validate]" >&2; exit 2 ;;
esac

# An UNPINNED reference is a bug, not a thing to resolve: someone added an image and skipped the
# pin, so the fleet is already drifting. Fail on it rather than silently pinning it to today —
# today's bytes have not been booted, and quietly adopting them is the opposite of the point.
# Deliberately not $-anchored: `FROM x:tag AS build` and `image: x:tag  # note` used to slip past it.
# An internal multi-stage `FROM base AS x` gets flagged too, which is loud rather than silent.
# org L5-02: host/tiles.sh carries its nginx pin as NGINX_REF="…" — the assignment form joins
# the unpinned sweep so losing the digest there is as loud as anywhere else.
if unpinned=$( { grep -nE '^\s*(image:|FROM) ' "${FILES[@]}"; grep -nE '^NGINX_REF="[^"@]*"$' host/tiles.sh; } | grep -v '@sha256:' ); then
  echo "FATAL: image reference with no digest (#109 requires every image pinned):" >&2
  echo "$unpinned" >&2
  echo "Add the digest by running this script without --check, then commit it." >&2
  exit 1
fi

# `name` keeps the tag (`nextcloud:34-apache`); only the digest after @ is replaced.
refs=$( { grep -hoE '(image:|FROM) +[^ ]+@sha256:[0-9a-f]{64}' "${FILES[@]}" | awk '{print $2}';
             grep -hoE 'NGINX_REF="[^"]+@sha256:[0-9a-f]{64}"' host/tiles.sh | sed 's/^NGINX_REF="//; s/"$//'
           } | sort -u)
[ -n "$refs" ] || { echo "FATAL: no pinned images found in ${FILES[*]}" >&2; exit 1; }

if [ "$validate_only" = 1 ]; then
  printf '%s\n' "$refs" | sed 's/^/  pinned: /'
  echo "every image is pinned, every digest well formed"
  exit 0
fi

# Stderr from the registry lands here so a failure can quote it. Removed on any exit, including the
# FATAL paths below, which is why it is a trap and not an rm at the end.
errf=$(mktemp); trap 'rm -f "$errf"' EXIT

drift=0
for ref in $refs; do
  name="${ref%@*}"; old="${ref#*@}"
  # The INDEX digest, not a per-platform manifest — pinning one architecture's manifest would make
  # the stack unresolvable on any other. `imagetools inspect` reads the registry without pulling
  # the ~3.3 GB behind it.
  # Retry once before giving up, and KEEP the registry's own words. Discarding stderr made every
  # cause print the same sentence — a missing tag, a Docker Hub rate limit and a dropped connection
  # were indistinguishable, and the message asserted "could not resolve" without having checked why.
  # Same defect as B-003. Observed 2026-08-05: a run reported postgres:18-alpine unresolvable while
  # the tag was fine and resolved by hand seconds later, which is the anonymous-pull rate limit —
  # a weekly unattended job hits it precisely because it inspects several images back to back.
  # ONE call per attempt — stderr to a file rather than a second invocation, because inspecting
  # twice to read the error would double the registry traffic that causes the failure.
  new=$(docker buildx imagetools inspect "$name" --format '{{.Manifest.Digest}}' 2>"$errf")
  case "$new" in
    sha256:*) ;;
    *) sleep 3   # one retry: the observed failure was transient
       new=$(docker buildx imagetools inspect "$name" --format '{{.Manifest.Digest}}' 2>"$errf") ;;
  esac
  case "$new" in
    sha256:*) ;;
    *) echo "FATAL: could not resolve $name from its registry (twice, 3s apart)." >&2
       sed 's/^/       registry said: /' "$errf" >&2
       echo "       a rate limit and a deleted tag both land here — read the line above before assuming drift." >&2
       exit 1 ;;
  esac

  if [ "$new" = "$old" ]; then
    printf '  = %s\n' "$name"
    continue
  fi

  drift=1
  printf '  ~ %s\n      %s\n   -> %s\n' "$name" "$old" "$new"
  # `|` as the delimiter: an image ref contains / and : but never a pipe, so nothing needs escaping.
  [ "$check_only" = 1 ] || sed -i "s|${name}@${old}|${name}@${new}|g" "${FILES[@]}"
done

if [ "$drift" = 0 ]; then
  echo "all pins current"
  exit 0
fi

if [ "$check_only" = 1 ]; then
  cat >&2 <<'MSG'

A tag has moved past its pin. Nothing was changed.
This is not urgent: no installed clinic is affected, because nothing pulls a new image on its own.

  To take the new bytes:  make images   then commit the diff and open a PR.
  cleanboot runs a full clean bring-up on that PR — do not merge it red.
MSG
  exit 1
fi

echo
echo "Digests rewritten. Commit the diff and open a PR so cleanboot boots the new bytes."
