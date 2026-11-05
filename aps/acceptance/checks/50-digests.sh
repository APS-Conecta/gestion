#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Every started container runs an image the candidate pins by digest: one of the three images its release names, or
# one its mastercontainer pins in AIO's php/containers.json or in a community container's file. It runs once «Instalar»
# started the suite (40-install), so it covers each of the suite's containers.
set -euo pipefail
aio=/var/www/docker-aio # AIO's tree in the mastercontainer
files="$aio/php/containers.json $aio/community-containers/*/*.json"
pins="$(
  gh release view "$TAG" --json body --jq .body \
    | { grep -oE '[a-z0-9._/-]+@sha256:[0-9a-f]{64}' || true; }
  "$MACHINE" "sudo docker exec nextcloud-aio-mastercontainer sh -c 'cat $files'" \
    | jq -r '.aio_services_v1[]? | select((.image_tag // "") | startswith("sha256:")) | "\(.image)@\(.image_tag)"'
)"
grep -q '^ghcr\.io/aps-conecta/all-in-one@sha256:' <<< "$pins" \
  || { echo "the release $TAG names no mastercontainer by digest" >&2; exit 1; }
# Each container on the machine, with the digests its image was pulled by.
containers="$("$MACHINE" sudo bash -s << 'CONTAINERS'
set -euo pipefail
for name in $(docker ps --all --format '{{.Names}}'); do
  echo "$name $(docker image inspect --format '{{join .RepoDigests " "}}' "$(docker inspect --format '{{.Image}}' "$name")")"
done
CONTAINERS
)"
unpinned=()
while read -r name digests; do
  [ -n "$name" ] || continue
  pin="$(tr ' ' '\n' <<< "$digests" | grep -m 1 -xF "$pins" || true)"
  if [ -n "$pin" ]; then echo "$name runs $pin"; else unpinned+=("$name (${digests:-pulled by no digest})"); fi
done <<< "$containers"
[ "${#unpinned[@]}" -eq 0 ] || { printf 'runs no digest the candidate pins: %s\n' "${unpinned[@]}" >&2; exit 1; }
echo "every started container runs a digest the candidate pins"
