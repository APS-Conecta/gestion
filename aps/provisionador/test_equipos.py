# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Equipos», where the operator types the establishment's sectors and programs and sees the team each becomes,
with its group and its folder, and the cargo accounts they bring; «Instalar» builds the last ones posted. The install
steps that build them have their tests in test_step_<id>.py."""

from test_provisionador import Installing, claimed

TEAMS = {"sectors": ["Norte", "Sector Sur", "sector norte", " "],
         "programs": ["Programa Atención Domiciliaria", "Salud Mental/Adulto"]}
DECLARED = [
    {"id": "sector-norte", "kind": "sector", "name": "Sector Norte", "folder": "Sectores/Sector Norte"},
    {"id": "sector-sur", "kind": "sector", "name": "Sector Sur", "folder": "Sectores/Sector Sur"},
    {"id": "prog-atencion-domiciliaria", "kind": "program", "name": "Programa Atención Domiciliaria",
     "folder": "Programas/Atención Domiciliaria"},
    {"id": "prog-salud-mental-adulto", "kind": "program", "name": "Programa Salud Mental-Adulto",
     "folder": "Programas/Salud Mental-Adulto"}]
CARGO = [{"user": "director", "name": "Director/a de CESFAM"},
         {"user": "subdirector", "name": "Subdirector/a Médico o Jefe Técnico"},
         {"user": "jefe.farmacia", "name": "Jefe/a de Farmacia (Químico/a Farmacéutico/a)"},
         {"user": "jefe.some", "name": "Jefe/a de SOME"},
         {"user": "jefe.norte", "name": "Jefe/a de Sector Norte"},
         {"user": "jefe.sur", "name": "Jefe/a de Sector Sur"}]


class Equipos(Installing):
    def teams(self, **body):
        return self.browser.request("POST", "/api/teams", body)

    def test_each_sector_and_program_becomes_one_team_with_its_group_and_folder(self):
        claimed(self.browser)
        status, body = self.teams(**TEAMS)
        self.assertEqual((status, body["teams"]), (200, DECLARED))
        self.assertEqual(self.browser.get("/api/state")[1]["teams"], DECLARED)

    def test_the_teams_bring_the_cargo_accounts_whose_usernames_the_install_reserves(self):
        claimed(self.browser)
        self.assertEqual(self.teams(**TEAMS)[1]["cargo_accounts"], CARGO)
        self.assertEqual(self.browser.get("/api/state")[1]["cargo_accounts"], CARGO)
        self.assertEqual(self.teams(sectors=["Farmacia"], programs=[])[1]["cargo_accounts"][-1],
                         {"user": "jefe.sector-farmacia", "name": "Jefe/a de Sector Farmacia"},
                         "a sector named as a position gets a jefatura of its own")

    def test_a_list_that_is_not_one_of_names_of_text_is_refused_and_changes_nothing(self):
        claimed(self.browser)
        self.teams(**TEAMS)
        for body in ({"sectors": "Norte"}, {"programs": [3]}, {"sectors": ["Nor\x00te"]}, {"programs": ["x" * 61]}):
            status, answer = self.teams(**body)
            self.assertEqual(status, 400, body)
            self.assertTrue(answer["error"], body)
        self.assertEqual(self.browser.get("/api/state")[1]["teams"], DECLARED)

    def test_instalar_builds_the_teams_posted_last_and_then_they_stay(self):
        claimed(self.browser)
        self.teams(**TEAMS)
        self.teams(sectors=["Oriente"], programs=[])
        self.install()
        status, body = self.teams(**TEAMS)
        self.assertEqual(status, 409)
        self.assertEqual(body["error"], "Los equipos ya no pueden cambiarse: se presionó «Instalar».")
        self.assertEqual([team["name"] for team in self.browser.get("/api/state")[1]["teams"]], ["Sector Oriente"])
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.nextcloud.groups["sector-oriente"]["name"], "Sector Oriente")
        self.assertNotIn("sector-norte", self.suite.nextcloud.groups)
