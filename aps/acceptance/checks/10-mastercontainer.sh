#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The mastercontainer runs the image the candidate's release names by digest, as the channel tag.
set -euo pipefail
channel=ghcr.io/aps-conecta/all-in-one:latest
released="$(gh release view "$TAG" --json body --jq .body \
  | { grep -oE "${channel%:*}@sha256:[0-9a-f]{64}" || true; } | sort -u)"
[[ "$released" =~ ^[^[:space:]]+$ ]] \
  || { echo "the release $TAG names no one mastercontainer by digest: ${released:-none}" >&2; exit 1; }
read -r running runs id <<< "$("$MACHINE" \
  "sudo docker inspect --format '{{.State.Running}} {{.Config.Image}} {{.Image}}' nextcloud-aio-mastercontainer")"
expected="$("$MACHINE" "sudo docker image inspect --format '{{.Id}}' $released")"
tagged="$("$MACHINE" "sudo docker image inspect --format '{{.Id}}' $channel")"
echo "nextcloud-aio-mastercontainer: running $running, $runs, $id; $TAG names $released, $expected; $channel is $tagged"
[[ "$running" = true && "$runs" = "$channel" && "$id" = "$expected" && "$tagged" = "$expected" ]] \
  || { echo "the mastercontainer does not run $released as $channel" >&2; exit 1; }
