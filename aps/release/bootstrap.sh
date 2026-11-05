#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Prints the Bootstrap (aps/bootstrap/install.sh) with its release tag and the mastercontainer's digest filled in:
# the release asset apsconecta-install.sh. Fails unless both were filled.
# Usage: bootstrap.sh <tag> <image@sha256:digest>
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <tag> <image@sha256:digest>" >&2; exit 2; }
tag=$1 pinned=$2
[[ -n "$tag" && "$pinned" =~ ^[a-z0-9./-]+@sha256:[0-9a-f]{64}$ ]] \
  || { echo "bootstrap.sh: '$pinned' is not an image by digest, or the tag is empty" >&2; exit 1; }
filled="$(sed -e "s|^RELEASE_TAG=\"\"$|RELEASE_TAG=\"$tag\"|" \
  -e "s|^MASTERCONTAINER=\"\"$|MASTERCONTAINER=\"$pinned\"|" "$(dirname "$0")/../bootstrap/install.sh")"
if ! grep -qxF "RELEASE_TAG=\"$tag\"" <<<"$filled" || ! grep -qxF "MASTERCONTAINER=\"$pinned\"" <<<"$filled"; then
  echo "bootstrap.sh: aps/bootstrap/install.sh has no empty RELEASE_TAG or MASTERCONTAINER line to fill" >&2
  exit 1
fi
printf '%s\n' "$filled"
