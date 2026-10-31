# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

# Phase 12 installs the apps after first boot; reuse their normal startup configuration.
phase_begin "14-fulltextsearch" "document content search configuration"
nc_exec --user www-data -- bash /configure-apps.sh fulltextsearch
phase_end
