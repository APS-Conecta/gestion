# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Antivirus», the antivirus step: vanilla's antivirus, which AIO's start sets up against ClamAV, deletes what
its background scan finds infected."""

from test_provisionador import Installing

ANTIVIRUS = "Antivirus"
OFF = ("El antivirus no quedó activo en Nextcloud: AIO lo desactiva cuando ClamAV no responde a tiempo al iniciarse "
       "Nextcloud. Contacte a APS Conecta.")


class Antivirus(Installing):
    def test_what_the_background_scan_finds_infected_is_deleted(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.apps["files_antivirus"].get("av_infected_action"), "delete")

    def test_an_antivirus_aio_left_off_at_nextclouds_start_fails_the_step_with_its_reason(self):
        self.suite.nextcloud.late = {"isClamavEnabled"}  # ClamAV does not answer Nextcloud's start in time
        self.install_the_suite()
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed install")
        self.assertFalse(self.listo(), "«Listo» came without the antivirus")
        self.assertEqual(self.steps()[ANTIVIRUS], ("failed", OFF))

    def test_the_end_of_install_check_turns_the_step_red_again_when_the_antivirus_only_logs_again(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        # Meanwhile Nextcloud restarted: vanilla's start sets the antivirus's infected-file action at every start.
        self.suite.nextcloud.apps["files_antivirus"]["av_infected_action"] = "only_log"
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertFalse(self.listo(), "«Listo» came while the antivirus only logged what it found infected")
        self.assertEqual(self.steps()[ANTIVIRUS], (
            "failed", "Nextcloud no conserva estos ajustes: files_antivirus.av_infected_action. Presione «Reintentar»; "
                      "si vuelve a ocurrir, contacte a APS Conecta."))
