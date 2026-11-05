# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Tema y marca», the theme step: the APS Conecta theme in Nextcloud's themes folder, theming's name, colours,
logos and backgrounds, the text overrides, and Nextcloud's own voice off."""

import json
import re
from pathlib import Path

import steps
from test_provisionador import REGISTER, Installing, claimed

THEME = Path(__file__).resolve().parents[2] / "themes" / "apsconecta"
TOKENS = (THEME / "core" / "css" / "tokens.css").read_text(encoding="utf-8")
VIOLET, VIOLET_DARK = (re.search(rf"{token}:\s*(#[0-9a-f]{{6}});", TOKENS)[1]
                       for token in ("--aps-violet", "--aps-violet-dark"))
NAME = "Tema y marca"
SUITE = "APS Conecta Gestión"
PLACED = "/var/www/html/themes/apsconecta"  # the theme in Nextcloud's themes folder


class Theme(Installing):
    def test_the_theme_goes_in_when_an_app_download_fails(self):
        intravox = next(app for app in steps.apps.MANIFEST if app["id"] == "intravox")
        self.suite.releases.pop((intravox["repo"], intravox["pin"], "intravox.tar.gz"))  # GitHub fails its download
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual((self.steps()["Aplicaciones"][0], self.steps()[NAME]), ("failed", ("green", None)))
        self.assertIn("apsconecta", self.suite.nextcloud.themes)

    def test_the_end_of_install_check_turns_the_step_red_again_when_nextcloud_turned_its_support_app_on(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.suite.nextcloud.apps["support"]["enabled"] = "yes"  # meanwhile, as vanilla's start turns it on
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertFalse(self.listo(), "«Listo» came with Nextcloud's support app on")
        self.assertEqual(self.steps()[NAME], ("failed", "Nextcloud no conserva estos ajustes: support.enabled. "
                                                        "Presione «Reintentar»; si vuelve a ocurrir, contacte a APS "
                                                        "Conecta."))

    def test_nextcloud_runs_the_theme_folder_with_the_establishments_name_in_its_site_css(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        placed = dict(self.suite.nextcloud.themes.get("apsconecta", {}))
        self.assertEqual(placed.pop("core/css/site.css", None),
                         ':root { --aps-clinic: "Centro de Salud Familiar Los Castaños"; }\n'.encode())
        self.assertEqual(placed, {path.relative_to(THEME).as_posix(): path.read_bytes()
                                  for path in THEME.rglob("*") if path.is_file()})
        self.assertEqual(self.suite.nextcloud.system.get("theme"), "apsconecta")

    def test_theming_says_aps_conecta_gestion_in_the_token_files_colours_with_the_themes_logos_light_only(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        expected = {"name": SUITE, "productName": SUITE, "slogan": "La salud primaria que compartimos es la que mejora",
                    "url": "https://apsconecta.cl", "primary_color": VIOLET, "background_color": VIOLET_DARK,
                    "disable-user-theming": True, "logoMime": "image/svg+xml", "logoheaderMime": "image/svg+xml",
                    "faviconMime": "image/svg+xml", "backgroundMime": "image/svg+xml"}
        theming = self.suite.nextcloud.apps.get("theming", {})
        self.assertEqual({key: theming.get(key) for key in expected}, expected)
        self.assertEqual(self.suite.nextcloud.images, {
            "logo": f"{PLACED}/core/img/logo/logo.svg", "logoheader": f"{PLACED}/core/img/logo/logo-header.svg",
            "favicon": f"{PLACED}/core/img/favicon.svg", "background": f"{PLACED}/core/img/background.svg"})
        self.assertEqual(self.suite.nextcloud.system.get("enforce_theme"), "light")

    def test_nextclouds_own_voice_goes_quiet_with_its_ios_banner_and_a_new_home_starts_without_its_sample_files(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        apps, system = self.suite.nextcloud.apps, self.suite.nextcloud.system
        off = ("nextcloud_announcements", "firstrunwizard", "survey_client", "support")
        self.assertEqual({app: apps.get(app, {}).get("enabled") for app in off}, dict.fromkeys(off, "no"))
        quiet = {"knowledgebaseenabled": False, "simpleSignUpLink.shown": False, "updatechecker": False,
                 "customclient_ios_appid": "", "skeletondirectory": ""}
        self.assertEqual({key: system.get(key, "unset") for key in quiet}, quiet)

    def test_everyones_personal_settings_link_the_suites_source_code_and_its_licence(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        notice = self.suite.nextcloud.themes["apsconecta"].get(  # in place of Nextcloud's development notice
            "apps/settings/templates/settings/personal/development.notice.php", b"").decode()
        for link in ("https://github.com/APS-Conecta/gestion", "https://www.gnu.org/licenses/agpl-3.0.html"):
            self.assertIn(f'<a href="{link}"', notice)

    def test_the_themes_spanish_says_aps_conecta_gestion_where_nextcloud_and_its_apps_say_nextcloud(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        placed = self.suite.nextcloud.themes["apsconecta"]
        overrides = {name.removesuffix("/l10n/es.json"): json.loads(data)["translations"]
                     for name, data in placed.items() if name.endswith("/l10n/es.json")}
        self.assertLessEqual({"core", "lib", "apps/settings", "custom_apps/spreed", "custom_apps/eurooffice"},
                             overrides.keys())
        named = {source: text for texts in overrides.values() for source, text in texts.items() if "Nextcloud" in text}
        self.assertEqual(named, {}, "an override that still says «Nextcloud»")
        self.assertEqual(overrides["core"].get("The Nextcloud login form is disabled. Use another login option if "
                                               "available or contact your administration."),
                         "El formulario de inicio de sesión de APS Conecta Gestión está deshabilitado. Use otro medio "
                         "de inicio de sesión disponible o contacte a su administración.")

    def register_file(self, folder):
        """The register, with an establishment whose name carries a double quote and a backslash."""
        path = folder / "establecimientos-deis-2026-07-23.csv"
        path.write_text(REGISTER + '999005,SAPU,"SAPU ""Dr. Juan Lozic"" \\ Norte",Calle Cinco 500,13101,Santiago,13,'
                        'Metropolitana de Santiago,Servicio de Salud Metropolitano Central,Municipal,-33.48,-70.63\r\n',
                        encoding="utf-8", newline="")
        return path

    def test_an_establishments_name_with_a_quote_or_a_backslash_stays_one_css_string(self):
        claimed(self.browser, "999005")
        self.install()
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.themes["apsconecta"]["core/css/site.css"],
                         ':root { --aps-clinic: "SAPU \\"Dr. Juan Lozic\\" \\\\ Norte"; }\n'.encode())
