#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# CI gate tools have one version/checksum owner. Verify bytes before extraction
# or installation; a remote checksum downloaded beside an asset is not a pin.
set -euo pipefail

die() { echo "FATAL: $*" >&2; exit 1; }
[ "$#" -eq 2 ] || die "usage: scripts/ci-tool.sh hadolint|gitleaks DESTINATION"
tool="$1"
destination="$2"
case "$tool" in
  hadolint)
    # https://github.com/hadolint/hadolint/releases/download/v2.15.1/checksums.sha256
    url=https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-x86_64
    checksum=c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
    ;;
  gitleaks)
    # https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_checksums.txt
    url=https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz
    checksum=6298c9235dfc9278c14b28afd9b7fa4e6f4a289cb1974bd27949fc1e9122bdee
    ;;
  *) die "unknown CI tool: $tool" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl --fail --silent --show-error --location --connect-timeout 10 --max-time 60 \
  --output "$tmp/download" "$url" || die "cannot download $tool (bounded 60s)"
printf '%s  %s\n' "$checksum" "$tmp/download" | sha256sum --check --status \
  || die "$tool checksum mismatch; refusing installation"
if [ "$tool" = gitleaks ]; then
  tar -xzf "$tmp/download" -C "$tmp" gitleaks
  binary="$tmp/gitleaks"
else
  binary="$tmp/download"
fi
install -m 0755 "$binary" "$destination"
