# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Background jobs from AIO's cron, as vanilla runs it: the Nextcloud container runs Nextcloud's cron.php every 5
minutes, so Nextcloud expects cron rather than a page load (ajax), as old gestion set it."""

from steps import configure, differences

NAME = "Tareas en segundo plano"
NEEDS = ("start",)
SETTINGS = {"apps": {"core": {"backgroundjobs_mode": "cron"}}}


def run(context):
    return configure(context.suite.nextcloud, SETTINGS)


def check(context):
    return differences(context.suite.nextcloud, SETTINGS)
