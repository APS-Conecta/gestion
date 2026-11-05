# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Página de bienvenida», the welcome step: every login lands on IntraVox («Inicio», the fork app the Suite
manifest pins), whose home page names the establishment, in the group folder Intranet, which the staff read and the
jefaturas and OIRS edit."""

import json

from test_provisionador import Installing

READ, EDIT = 1, 7  # Groupfolders' permissions: read; read and write


class Welcome(Installing):
    def intranet(self):
        return next(folder for folder in self.suite.nextcloud.folders.values() if folder["mount"] == "Intranet")

    def test_every_login_lands_on_the_welcome_page_which_names_the_establishment(self):
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        nextcloud = self.suite.nextcloud
        self.assertEqual((nextcloud.system["defaultapp"], nextcloud.apps["intravox"]["telemetry_enabled"]),
                         ("intravox", "false"), "logins land on IntraVox, which reports nothing to its makers")
        intranet = self.intranet()
        self.assertLessEqual({"all-staff": READ, "cat-jefaturas": EDIT, "role-oirs": EDIT}.items(),
                             intranet["groups"].items())
        home = json.loads(intranet["files"]["es/home.json"])
        self.assertEqual(home["title"], "Inicio")
        for shown in ("Centro de Salud Familiar Los Castaños", "Santiago · Servicio de Salud Metropolitano Central"):
            self.assertIn(shown, json.dumps(home, ensure_ascii=False))
        self.assertEqual(json.loads(intranet["files"]["es/navigation.json"])["items"][0]["uniqueId"], home["uniqueId"])
        self.assertEqual(nextcloud.indexed, {home["uniqueId"]}, "IntraVox lists the home page")

    def test_the_end_of_install_check_finds_a_welcome_page_the_staff_cannot_read(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        del self.intranet()["groups"]["all-staff"]  # meanwhile, the staff lose the Intranet folder
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertEqual(self.steps()["Página de bienvenida"], (
            "failed", "El personal no puede leer la página de bienvenida en la carpeta Intranet. Presione "
                      "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."))
        self.install()  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.intranet()["groups"]["all-staff"], READ)
