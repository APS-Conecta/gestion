# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Tareas en segundo plano», the background jobs step."""

from test_provisionador import Installing


class Jobs(Installing):
    def test_nextcloud_runs_its_background_jobs_from_aios_cron(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.apps["core"].get("backgroundjobs_mode"), "cron")
