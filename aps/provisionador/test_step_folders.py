# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Carpetas de equipo y permisos», the folders step: old gestion's group folders, Transversal with its
subfolders, one folder per unit and one per team, each with the declared groups' permissions and no other group's."""

from test_provisionador import Installing

FOLDERS = "Carpetas de equipo y permisos"
READ, READ_SHARE, MANAGE = 1, 17, 31  # Groupfolders' permissions: read; read and share; read, write, delete and share


class Folders(Installing):
    def folders(self):
        """Each group folder by its mount point: each group's permissions in it and the files seeded in it."""
        return {folder["mount"]: folder for folder in self.suite.nextcloud.folders.values()}

    def test_instalar_creates_each_group_folder_with_its_groups_permissions_and_transversals_subfolders(self):
        self.install_the_suite(sectors=["Norte"], programs=["Atención Domiciliaria"])
        self.eventually(self.listo, "«Listo»")
        folders = {mount: folder["groups"] for mount, folder in self.folders().items()}
        self.assertLessEqual({
            "Transversal": {"all-staff": READ, "cat-jefaturas": MANAGE},
            "Sectores/Sector Norte": {"sector-norte": MANAGE, "cat-jefaturas": MANAGE},
            "Programas/Atención Domiciliaria": {"prog-atencion-domiciliaria": MANAGE, "cat-jefaturas": MANAGE},
            "Unidades/Farmacia": {"role-quimico-farmaceutico": MANAGE, "role-tens-farmacia": MANAGE,
                                  "cat-jefaturas": READ_SHARE},
            "Unidades/Dirección": {"cat-jefaturas": MANAGE}}.items(), folders.items())
        self.assertEqual(sorted(mount for mount in folders if mount.startswith("Unidades/")), [
            "Unidades/Dental", "Unidades/Dirección", "Unidades/Estadística-REM", "Unidades/Farmacia", "Unidades/OIRS",
            "Unidades/SOME"])
        self.assertEqual(self.folders()["Transversal"]["files"], dict.fromkeys(
            ["Protocolos", "Flujogramas", "Documentación", "Registro de redes", "Actas de reuniones"]))

    def test_the_end_of_install_check_finds_an_undeclared_grant_and_reintentar_revokes_it(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite(sectors=["Norte"], programs=[])
        self.eventually(lambda: self.status() == "failed", "a failed install")
        north = self.folders()["Sectores/Sector Norte"]
        north["groups"]["all-staff"] = MANAGE  # meanwhile, the whole staff gets the sector's folder
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertEqual(self.steps()[FOLDERS], (
            "failed", "Estas carpetas de equipo no tienen los permisos declarados: Sectores/Sector Norte. Presione "
                      "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."))
        self.install()  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(north["groups"], {"sector-norte": MANAGE, "cat-jefaturas": MANAGE})

    def test_without_groupfolders_the_step_fails_naming_it_while_the_groups_go_in(self):
        del self.suite.nextcloud.store["groupfolders"]  # the app store does not serve it
        self.install_the_suite(sectors=["Norte"], programs=[])
        self.eventually(lambda: self.status() == "failed", "a failed install")
        steps = self.steps()
        self.assertEqual(steps[FOLDERS], ("failed", "Nextcloud no completó «occ app:enable groupfolders». Presione "
                                                    "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."))
        self.assertEqual(steps["Grupos y equipos"], ("green", None))
        self.assertEqual(self.suite.nextcloud.folders, {})
