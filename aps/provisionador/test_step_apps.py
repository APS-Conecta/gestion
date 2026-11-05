# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Aplicaciones», the apps step: the Suite manifest's default apps, each own and fork app from its App release
at the tag and checksum the manifest pins, and the store apps through vanilla's startup-apps switch."""

from unittest import mock

import steps
from test_provisionador import Installing, app_tarball

APPS = "Aplicaciones"
# The default own and fork apps (#289): epidemiologia, territorio and files_upload_guard, IntraVox and
# files_fulltextsearch.
PINNED = ("intravox", "epidemiologia", "territorio", "files_upload_guard", "files_fulltextsearch")
# The default store apps beside the components' own (#278): groupfolders, calendar, contacts and side_menu.
STORE = ["groupfolders", "calendar", "contacts", "side_menu"]


class Apps(Installing):
    def test_each_default_own_and_fork_app_runs_the_app_release_the_manifest_pins(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        held = self.suite.nextcloud.apps
        pins = {app["id"]: app["pin"] for app in steps.apps.MANIFEST if app["id"] in PINNED}
        self.assertEqual({app: (held.get(app, {}).get("enabled"), f"v{held.get(app, {}).get('installed_version')}")
                          for app in PINNED}, {app: ("yes", pins[app]) for app in PINNED})

    def test_a_download_whose_checksum_is_not_the_pinned_one_is_refused_with_a_reason_and_not_installed(self):
        territorio = next(app for app in steps.apps.MANIFEST if app["id"] == "territorio")
        self.suite.releases[territorio["repo"], territorio["pin"], "territorio.tar.gz"] = app_tarball("territorio",
                                                                                                      "0.81.0-otro")
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[APPS], (
            "failed", "«Territorio»: La descarga de su versión v0.81.0 no coincide con la suma de verificación que fija "
                      "la suite, así que no se instaló. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS "
                      "Conecta."))
        self.assertNotIn("territorio", self.suite.nextcloud.apps)
        self.assertFalse(self.listo())

    def test_a_failed_app_release_download_blocks_only_the_steps_that_depend_on_it(self):
        intravox = next(app for app in steps.apps.MANIFEST if app["id"] == "intravox")
        release = self.suite.releases.pop((intravox["repo"], intravox["pin"], "intravox.tar.gz"))  # GitHub fails it
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        progress = self.steps()
        self.assertEqual(progress.pop(APPS), (
            "failed", "«Inicio»: No se pudo descargar su publicación desde GitHub. Revise la conexión a internet del "
                      "servidor y presione «Reintentar»."))
        self.assertEqual(set(progress.values()), {("green", None)}, "no other step needs the apps")
        self.assertEqual({app for app in PINNED if app in self.suite.nextcloud.apps}, set(PINNED) - {"intravox"})
        self.suite.releases[intravox["repo"], intravox["pin"], "intravox.tar.gz"] = release
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.apps["intravox"]["enabled"], "yes")

    def test_the_default_store_apps_are_vanillas_startup_apps_on_aios_start(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.startup_apps, STORE)
        self.assertEqual({app: self.suite.nextcloud.apps.get(app, {}).get("enabled") for app in STORE},
                         dict.fromkeys(STORE, "yes"))

    def test_a_default_store_app_the_first_start_did_not_install_comes_from_the_store_at_reintentar(self):
        version = self.suite.nextcloud.store.pop("calendar")  # the store does not deliver it at Nextcloud's first start
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[APPS], (
            "failed", "«Calendario»: Nextcloud no completó «occ app:enable calendar». Presione «Reintentar»; si "
                      "vuelve a ocurrir, contacte a APS Conecta."))
        self.suite.nextcloud.store["calendar"] = version
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.apps["calendar"]["enabled"], "yes")

    def test_a_pinned_app_that_runs_another_version_at_the_end_of_install_check_turns_the_step_red_again(self):
        nextcloud = self.suite.nextcloud
        occ = nextcloud.occ

        def store_update(*args, stdin=""):  # something replaces IntraVox once the apps step installed it
            nextcloud.apps.get("intravox", {})["installed_version"] = "3.3.0"
            return occ(*args, stdin=stdin)

        with mock.patch.object(nextcloud, "occ", side_effect=store_update):
            self.install_the_suite()
            self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[APPS], (
            "failed", "Nextcloud no tiene activadas estas aplicaciones en la versión que fija la suite: Inicio. "
                      "Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."))
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(nextcloud.apps["intravox"]["installed_version"], "3.2.0")
