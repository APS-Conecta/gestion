# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Menú personalizado», the custom menu step: side_menu, a default store app of the Suite manifest, in the
brand token file's dark violet."""

import re
from pathlib import Path

import steps
from test_provisionador import Installing

MENU = "Menú personalizado"
TOKENS = Path(__file__).resolve().parents[2] / "themes" / "apsconecta" / "core" / "css" / "tokens.css"
VIOLET_DARK = re.search(r"--aps-violet-dark:\s*(#[0-9a-f]{6});", TOKENS.read_text(encoding="utf-8"))[1]


class Menu(Installing):
    def test_the_custom_menu_is_on_in_the_token_files_dark_violet(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        side_menu = self.suite.nextcloud.apps.get("side_menu", {})
        self.assertEqual({key: side_menu.get(key) for key in ("enabled", "background-color", "background-color-to")},
                         {"enabled": "yes", "background-color": VIOLET_DARK, "background-color-to": VIOLET_DARK})

    def test_without_side_menu_the_step_fails_naming_it_until_reintentar_finds_it_in_the_store(self):
        version = self.suite.nextcloud.store.pop("side_menu")  # the store does not deliver it
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[MENU], (
            "failed", "«Menú personalizado»: Nextcloud no completó «occ app:enable side_menu». Presione «Reintentar»; "
                      "si vuelve a ocurrir, contacte a APS Conecta."))
        self.suite.nextcloud.store["side_menu"] = version
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.apps["side_menu"]["enabled"], "yes")

    def test_no_other_apps_failure_holds_the_custom_menu_back(self):
        intravox = next(app for app in steps.apps.MANIFEST if app["id"] == "intravox")
        self.suite.releases.pop((intravox["repo"], intravox["pin"], "intravox.tar.gz"))  # GitHub fails its download
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()["Aplicaciones"][0], "failed")
        self.assertEqual(self.steps()[MENU], ("green", None))
        self.assertEqual(self.suite.nextcloud.apps["side_menu"]["background-color"], VIOLET_DARK)

    def test_the_end_of_install_check_turns_the_step_red_again_when_nextcloud_lost_the_menus_violet(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.suite.nextcloud.apps["side_menu"]["background-color"] = "#000000"  # meanwhile, the menu turns black
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertFalse(self.listo(), "«Listo» came while Nextcloud did not hold the custom menu's violet")
        self.assertEqual(self.steps()[MENU], ("failed", "Nextcloud no conserva estos ajustes: "
                                                        "side_menu.background-color. Presione «Reintentar»; si vuelve "
                                                        "a ocurrir, contacte a APS Conecta."))
