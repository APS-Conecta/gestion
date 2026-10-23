#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The static gate's INJECTED VIOLATION (#60). Never executed: scripts/test.sh reads these
# bytes, and its env_sh_selfpath_gate arm asserts they ARE flagged (org L7-2 — a gate that
# cannot red is no gate). env.sh's first job is cd'ing to the repo root, so both
# dirname-of-self lines below resolve against the wrong cwd when this script is started by a
# relative path — the exact shape #30's first draft shipped twice.
. "$(dirname "$0")/env.sh"                    # the sourcing line: expands BEFORE the cd — legal
v="$(cat "$(dirname "$0")/../VERSION")"        # #30's shape: resolves against the repo root — RED
v="$(dirname -- "${BASH_SOURCE[0]}")/dato"     # the same hazard, the BASH_SOURCE spelling — RED
