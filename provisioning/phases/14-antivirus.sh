# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

# Phase 12 installs the app after first boot; reuse its normal startup configuration.
phase_begin "14-antivirus" "antivirus upload configuration"
nc_exec --user www-data -- bash /configure-apps.sh antivirus
phase_end
