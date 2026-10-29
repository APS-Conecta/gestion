#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Clean boot's package install, bounded (#85): apt-get update, then apt-get install of the named
# packages, each under a time limit. A stalled mirror fails the step within minutes, naming the
# apt-get call and the configured mirrors, instead of hanging silently until the job's own timeout.
# One copy for both Clean boot jobs: by domain and by IP.
#   scripts/cleanboot-apt.sh PACKAGE...
set -euo pipefail
ETC_DIR="${ETC_DIR:-/etc}"   # the test points it at a fixture tree
LIMIT=180                    # seconds per apt-get call; a healthy runner needs well under one

apt_bounded() {
  local rc=0 list
  sudo timeout "$LIMIT" apt-get "$@" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  {
    echo "FAIL: apt-get $* exited $rc (124: still running after ${LIMIT}s); the configured mirrors:"
    grep -hsE '^(URIs:|deb )' "$ETC_DIR"/apt/sources.list "$ETC_DIR"/apt/sources.list.d/* || true
    # a runner's mirror+file: URI names a list of mirrors, not a mirror: print the list too
    grep -hsoE 'mirror\+file:[^[:space:]]+' "$ETC_DIR"/apt/sources.list "$ETC_DIR"/apt/sources.list.d/* | sort -u \
      | while read -r list; do echo "${list}:"; cat "${list#mirror+file:}" || true; done
  } >&2
  exit 1
}

apt_bounded update -qq
apt_bounded install -y "$@"
