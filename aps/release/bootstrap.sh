#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Prints the Bootstrap (aps/bootstrap/install.sh) with its release tag and the mastercontainer's digest filled in:
# the release asset apsconecta-install.sh. A test build's also carries the CAs its suite trusts for its own
# server-side calls, the PEM file <cacerts>: Let's Encrypt's staging roots. Fails unless all were filled.
# Usage: bootstrap.sh <tag> <image@sha256:digest> [<cacerts>]
set -euo pipefail
[[ "$#" -eq 2 || "$#" -eq 3 ]] || { echo "usage: $0 <tag> <image@sha256:digest> [<cacerts>]" >&2; exit 2; }
tag=$1 pinned=$2 cacerts=""
[[ -n "$tag" && "$pinned" =~ ^[a-z0-9./-]+@sha256:[0-9a-f]{64}$ ]] \
  || { echo "bootstrap.sh: '$pinned' is not an image by digest, or the tag is empty" >&2; exit 1; }
if [ "$#" -eq 3 ]; then
  grep -q -e '-----BEGIN CERTIFICATE-----' "$3" || { echo "bootstrap.sh: $3 holds no certificate" >&2; exit 1; }
  cacerts="$(base64 -w 0 "$3")"
fi
filled="$(sed -e "s|^RELEASE_TAG=\"\"$|RELEASE_TAG=\"$tag\"|" \
  -e "s|^MASTERCONTAINER=\"\"$|MASTERCONTAINER=\"$pinned\"|" \
  -e "s|^TRUSTED_CACERTS=\"\"$|TRUSTED_CACERTS=\"$cacerts\"|" "$(dirname "$0")/../bootstrap/install.sh")"
if ! grep -qxF "RELEASE_TAG=\"$tag\"" <<<"$filled" || ! grep -qxF "MASTERCONTAINER=\"$pinned\"" <<<"$filled" \
    || ! grep -qxF "TRUSTED_CACERTS=\"$cacerts\"" <<<"$filled"; then
  echo "bootstrap.sh: aps/bootstrap/install.sh has no empty RELEASE_TAG, MASTERCONTAINER or TRUSTED_CACERTS line" >&2
  exit 1
fi
printf '%s\n' "$filled"
