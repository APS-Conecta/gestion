# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Idioma y formato regional», the locale step."""

from test_provisionador import Installing, claimed

LOCALE = "Idioma y formato regional"

class Locale(Installing):
    def test_everyone_gets_spanish_with_chiles_formats_whatever_the_browser_asks_for(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual({key: self.suite.nextcloud.system.get(key) for key in (
            "default_language", "force_language", "default_locale", "default_phone_region")},
            {"default_language": "es", "force_language": "es", "default_locale": "es_CL", "default_phone_region": "CL"})

    def test_nextclouds_server_side_clock_and_its_log_run_on_the_centres_timezone(self):
        claimed(self.browser, "999002")  # CECOSF Estrecho, in Magallanes
        self.install()
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual({key: self.suite.nextcloud.system.get(key) for key in ("default_timezone", "logtimezone")},
                         {"default_timezone": "America/Punta_Arenas", "logtimezone": "America/Punta_Arenas"})

    def test_the_end_of_install_check_turns_the_step_red_again_when_nextclouds_timezone_changed(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.suite.nextcloud.system["logtimezone"] = "UTC"  # meanwhile, Nextcloud's log is back on UTC
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.status() == "failed", "a failed end-of-install check")
        self.assertEqual(self.steps()[LOCALE], ("failed", "Nextcloud no conserva estos ajustes: logtimezone. Presione "
                                                          "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."))
