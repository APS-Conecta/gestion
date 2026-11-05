# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Aplicaciones del personal», the app policy step, as old gestion's: the administrator keeps every app, and
the staff get the reduced set."""

from test_provisionador import Installing

POLICY = "Aplicaciones del personal"
ADMIN = '["admin"]'  # an app enabled for the admin group alone, as Nextcloud keeps it
ADMIN_ONLY = ("updatenotification", "serverinfo", "recommendations", "related_resources", "weather_status")


class AppPolicy(Installing):
    def test_nextclouds_tooling_is_the_administrators_its_tour_survey_and_announcements_are_off(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        apps = self.suite.nextcloud.apps
        self.assertEqual({app: apps[app]["enabled"] for app in ADMIN_ONLY}, dict.fromkeys(ADMIN_ONLY, ADMIN))
        self.assertEqual({app: apps[app]["enabled"] for app in ("survey_client", "nextcloud_announcements")},
                         {"survey_client": "no", "nextcloud_announcements": "no"})
        self.assertEqual((apps["firstrunwizard"]["wizard_enabled"], apps["survey_client"]["never_again"],
                          apps["password_policy"]["enforceHaveIBeenPwned"]), ("false", "true", "0"),
                         "no first-run tour, the survey's own kill switch, and no breached-password lookup")

    def test_the_end_of_install_check_finds_an_app_the_staff_got_back(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.suite.nextcloud.apps["weather_status"]["enabled"] = "yes"  # meanwhile, enabled for everyone again
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertEqual(self.steps()[POLICY], (
            "failed", "Nextcloud no conserva estos ajustes: weather_status.enabled. Presione «Reintentar»; si vuelve a "
                      "ocurrir, contacte a APS Conecta."))
        self.install()  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.apps["weather_status"]["enabled"], ADMIN)
