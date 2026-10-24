#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The static gate's SCOPE half (#60): a script that never sources env.sh is not the gate's
# subject, however much it self-locates. Never executed — scripts/test.sh reads these bytes
# and its env_sh_selfpath_gate arm asserts zero rows (the gate polices the env.sh contract,
# not dirname in general).
v="$(dirname "$0")/donde-este"
