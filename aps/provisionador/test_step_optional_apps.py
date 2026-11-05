# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Aplicaciones opcionales», the optional apps step: the optional apps the operator ticked at «Revisar», off by
default, each from its App release at the tag and checksum the Suite manifest pins."""

import steps
from test_provisionador import Installing, claimed

OPTIONAL = ("farmacia", "estadistica", "totem")


class OptionalApps(Installing):
    def instalar(self, body):
        """«Centro» and «Dirección», then «Instalar» with `body`; the suite's containers come up once AIO starts them."""
        claimed(self.browser)
        status, answer = self.browser.request("POST", "/api/install", body)
        if status == 202:
            self.eventually(lambda: self.suite.starts, "AIO's start")
            self.suite.up()
        return status, answer

    def test_the_optional_apps_ticked_at_revisar_reach_the_install_plan_and_run_their_pinned_app_releases(self):
        status, answer = self.instalar({"optional": ["farmacia"]})
        self.assertEqual((status, answer["install"]["optional"]), (202, ["farmacia"]))
        self.eventually(self.listo, "«Listo»")
        held = self.suite.nextcloud.apps
        pin = next(app["pin"] for app in steps.apps.MANIFEST if app["id"] == "farmacia")
        self.assertEqual((held["farmacia"]["enabled"], f"v{held['farmacia']['installed_version']}"), ("yes", pin))
        self.assertEqual({app for app in OPTIONAL if app in held}, {"farmacia"})

    def test_the_optional_apps_are_off_by_default(self):
        status, answer = self.instalar({})
        self.assertEqual((status, answer["install"]["optional"]), (202, []))
        self.eventually(self.listo, "«Listo»")
        self.assertEqual({app for app in OPTIONAL if app in self.suite.nextcloud.apps}, set())

    def test_an_app_revisar_does_not_offer_is_refused_and_nothing_starts(self):
        for body in ({"optional": ["calendar"]}, {"optional": "farmacia"}):
            with self.subTest(body=body):
                status, answer = self.instalar(body)
                self.assertEqual((status, answer), (400, {"error": "Elija las aplicaciones opcionales entre las que "
                                                                   "ofrece «Revisar»."}))
                self.assertIsNone(self.browser.get("/api/state")[1]["install"])
                self.assertEqual(self.suite.starts, 0)
