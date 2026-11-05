# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Cuentas de cargo», the cargo accounts step: one account per position every establishment has and a jefatura
per sector, by the usernames the install reserves, each in its groups, with a first password made once and kept beside
the Provisionador's state."""

import json

from test_provisionador import Installing

CARGO = {"director": ("Director/a de CESFAM", {"role-director-cesfam", "cat-jefaturas", "all-staff"}),
         "subdirector": ("Subdirector/a Médico o Jefe Técnico",
                         {"role-subdirector-jefe-tecnico", "cat-jefaturas", "all-staff"}),
         "jefe.farmacia": ("Jefe/a de Farmacia (Químico/a Farmacéutico/a)",
                           {"role-quimico-farmaceutico", "cat-jefaturas", "all-staff"}),
         "jefe.some": ("Jefe/a de SOME", {"role-jefe-some", "cat-jefaturas", "all-staff"}),
         "jefe.norte": ("Jefe/a de Sector Norte", {"role-jefe-sector-mais", "sector-norte", "cat-jefaturas",
                                                   "all-staff"})}


class CargoAccounts(Installing):
    def accounts(self):
        """Each cargo account Nextcloud holds: its name and the groups it is in."""
        nextcloud = self.suite.nextcloud
        return {user: (nextcloud.users[user]["name"], {group for group, held in nextcloud.groups.items()
                                                       if user in held["members"]})
                for user in CARGO if user in nextcloud.users}

    def first_passwords(self):
        return json.loads((self.state / "first-passwords.json").read_text(encoding="utf-8"))

    def test_instalar_creates_each_cargo_account_by_its_reserved_username_in_its_groups(self):
        self.install_the_suite(sectors=["Norte"], programs=["Cardiovascular"])
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.accounts(), CARGO)

    def test_each_first_password_is_kept_beside_the_state_readable_by_the_provisionadors_account_alone(self):
        self.install_the_suite(sectors=["Norte"], programs=[])
        self.eventually(self.listo, "«Listo»")
        users = self.suite.nextcloud.users
        self.assertEqual((self.state / "first-passwords.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual({user: users[user]["password"] for user in CARGO}, self.first_passwords())
        self.assertEqual(len({users[user]["password"] for user in CARGO}), len(CARGO))

    def test_the_accounts_wait_for_the_app_policy_so_that_no_first_password_is_looked_up_outside_the_server(self):
        self.suite.nextcloud.ignored = {"enforceHaveIBeenPwned"}  # Nextcloud keeps the breached-password lookup on
        self.install_the_suite(sectors=["Norte"], programs=[])
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()["Cuentas de cargo"],
                         ("waiting", "Espera a que se complete «Aplicaciones del personal»."))
        self.assertEqual(self.accounts(), {})
        self.suite.nextcloud.ignored = set()
        self.install()  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual([user for user in CARGO if self.suite.nextcloud.users[user]["looked_up"]], [])

    def test_the_end_of_install_check_finds_an_account_out_of_its_team_and_reintentar_keeps_every_password(self):
        del self.suite.nextcloud.apps["admin_audit"]  # the security step fails, so the end-of-install check waits
        self.install_the_suite(sectors=["Norte"], programs=[])
        self.eventually(lambda: self.status() == "failed", "a failed install")
        first = self.first_passwords()
        self.suite.nextcloud.groups["sector-norte"]["members"].remove("jefe.norte")
        self.suite.nextcloud.apps["admin_audit"] = {"enabled": "no"}
        self.install()  # «Reintentar»
        self.eventually(lambda: self.listo() or self.status() == "failed", "a failed end-of-install check")
        self.assertEqual(self.steps()["Cuentas de cargo"], (
            "failed", "Estas cuentas de cargo no existen o no están en sus grupos: jefe.norte. Presione «Reintentar»; "
                      "si vuelve a ocurrir, contacte a APS Conecta."))
        self.install()  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.accounts(), CARGO)
        self.assertEqual(({user: self.suite.nextcloud.users[user]["password"] for user in CARGO},
                          self.first_passwords()), (first, first))
