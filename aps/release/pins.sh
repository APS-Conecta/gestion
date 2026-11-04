#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The digest pins: every container in php/containers.json that isn't ours, and the base of our thin Nextcloud
# image, names an official image (ghcr.io/nextcloud-releases) by digest, and each digest resolves to an image
# upstream built from the Keep-list's base commit; every base in aps/images/*/Dockerfile (the thin Nextcloud
# and Caddy images) is pinned by digest. At an Upstream merge, `pins.sh <upstream image tag>` first re-pins
# the official images to that tag (v14.4.3's: 20261029_150718).
# Usage: pins.sh [<upstream image tag>]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[ "$#" -le 1 ] || { echo "usage: $0 [<upstream image tag>]" >&2; exit 2; }
nextcloud=aps/images/nextcloud/Dockerfile
official() { # <container> <image> <image_tag> of every container that isn't ours
  jq -r '.aio_services_v1[] | select(.image | startswith("ghcr.io/aps-conecta/") | not)
         | "\(.container_name) \(.image) \(.image_tag)"' php/containers.json
}
if [ "$#" -eq 1 ]; then
  digest() { docker buildx imagetools inspect "$1:$2" --format '{{json .Manifest}}' | jq -r .digest; }
  official | while read -r container image _; do
    pin="$(digest "$image" "$1")"
    sed -i "/\"container_name\": \"$container\",/,/\"image_tag\":/s|\"image_tag\": \"[^\"]*\"|\"image_tag\": \"$pin\"|" \
      php/containers.json
  done
  base="$(sed -n 's/^FROM \([^:@ ]*\).*/\1/p' "$nextcloud")"
  sed -i "s|^FROM .*|FROM $base:$1@$(digest "$base" "$1")|" "$nextcloud"
fi
commit="$(sed -n 's/^# base: \([0-9a-f]\{40\}\) .*/\1/p' aps/keep-list.txt)"
{ official | awk '{ print $2 "@" $3 }'; sed -n 's/^FROM //p' "$nextcloud"; } | while read -r pinned; do
  [[ "$pinned" =~ ^ghcr\.io/nextcloud-releases/[a-z0-9-]+(:[A-Za-z0-9_.-]+)?@sha256:[0-9a-f]{64}$ ]] \
    || { echo "::error::$pinned is not an official image pinned by digest"; exit 1; }
  aps/release/revision.sh "$pinned" "$commit"
done
for dockerfile in aps/images/*/Dockerfile; do
  awk '/^FROM / { if (!($2 in stages) && $2 !~ /@sha256:[0-9a-f]{64}$/) bad = bad " " $2; if (toupper($3) == "AS") stages[$4] }
       END { if (bad) { print "::error::" FILENAME " has bases not pinned by digest:" bad; exit 1 } }' "$dockerfile"
done
