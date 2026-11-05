# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""AIO's own nightly backup, to a fixed folder on this server. AIO's automatic updates stay off until the Nightly update
(#299) turns them on."""

NAME = "Copias de seguridad"
NEEDS = ()
FOLDER = "/var/backups/apsconecta-gestion"  # on the server: AIO's borg repository
TIME = "06:00"  # UTC, as the mastercontainer's clock runs: 02:00 or 03:00 in continental Chile, 00:00 or 01:00 in Rapa Nui


def run(context):
    context.suite.backups(FOLDER, TIME)
