#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The static gate's LEGAL half (#60): every idiom the dirname gate must NOT flag. Never
# executed — scripts/test.sh reads these bytes and its env_sh_selfpath_gate arm asserts
# zero rows (a gate that reds a legal idiom teaches developers to route around it).
HERE="$(cd "$(dirname "$0")" && pwd)"          # pre-source: the caller has not moved yet
cd "$(dirname "$0")/.." || exit 1              # usuarios.sh's own cd, still pre-source
. "$(dirname -- "$0")/env.sh"                  # the sourcing line, the -- spelling: expands before env.sh runs
bash "$HERE/db-dump.sh"                        # HERE is absolute by now — no dirname left to re-run
d="$(dirname "$arg")"; b="$(basename "$0")"     # not self-location; basename never reads the cwd
