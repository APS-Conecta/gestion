# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Grupos y equipos», the groups step: the staff-wide group, the four categories, the roles every
establishment shares and one group per team «Equipos» declared, by old gestion's ids, with their Spanish names."""

from test_provisionador import Installing

GROUPS = "Grupos y equipos"


class Groups(Installing):
    def test_instalar_creates_the_staff_wide_group_the_categories_the_roles_and_one_group_per_team(self):
        self.install_the_suite(sectors=["Norte"], programs=["Salud Mental/Adulto"])
        self.eventually(self.listo, "«Listo»")
        groups = {gid: group["name"] for gid, group in self.suite.nextcloud.groups.items()}
        self.assertLessEqual({"all-staff": "Todo el personal", "cat-jefaturas": "Jefaturas", "cat-clinicos": "Clínicos",
                              "cat-tecnicos": "Técnicos", "cat-administrativos": "Administrativos",
                              "role-director-cesfam": "Director/a de CESFAM", "role-oirs": "Encargado/a OIRS",
                              "role-tens-farmacia": "TENS – Farmacia / PNAC", "sector-norte": "Sector Norte",
                              "prog-salud-mental-adulto": "Programa Salud Mental-Adulto"}.items(), groups.items())
        self.assertEqual(len([gid for gid in groups if gid.startswith("role-")]), 23)
        self.assertEqual(len([gid for gid in groups if gid.startswith("cat-")]), 4)

    def test_the_end_of_install_check_finds_a_group_nextcloud_lost_and_reintentar_creates_it_again(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite(sectors=["Norte"], programs=[])
        self.eventually(lambda: self.status() == "failed", "a failed install")
        del self.suite.nextcloud.groups["sector-norte"]  # meanwhile, an administrator deletes the team's group
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertEqual(self.steps()[GROUPS], ("failed", "Nextcloud no tiene estos grupos: Sector Norte. Presione "
                                                          "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."))
        self.install()  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.groups["sector-norte"]["name"], "Sector Norte")
