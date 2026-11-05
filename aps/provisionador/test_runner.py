# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: the install step runner, through «Instalar» and «Reintentar», with the fake suite port injecting failures.
Each step's own tests are in test_step_<id>.py."""

from unittest import mock

from suite import Unreachable
from test_provisionador import Installing, claimed

BACKUPS_REFUSED = ("AIO no aceptó las copias de seguridad. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS "
                   "Conecta.")
NEXTCLOUD_DOWN = ("El servidor de aplicaciones de la suite no responde. Presione «Reintentar»; si vuelve a ocurrir, "
                  "contacte a APS Conecta.")
TALK_STOPPED = ("Estos contenedores de la suite no quedaron en ejecución: Talk. Presione «Reintentar»; si vuelve a "
                "ocurrir, contacte a APS Conecta.")


class Runner(Installing):
    def test_a_failed_step_makes_its_dependents_wait_and_the_steps_independent_of_it_still_run(self):
        claimed(self.browser)
        with mock.patch.object(self.suite, "backups", side_effect=Unreachable(BACKUPS_REFUSED)):
            self.install()
            self.eventually(lambda: self.status() == "failed", "a failed install")
        steps = self.steps()
        self.assertEqual(steps["Copias de seguridad"], ("failed", BACKUPS_REFUSED))
        self.assertEqual(steps["Inicio de la suite"], ("waiting", "Espera a que se complete: «Copias de seguridad»."))
        self.assertEqual((steps["Componentes"], steps["Zona horaria"]), (("green", None), ("green", None)))
        self.assertEqual(self.suite.starts, 0)
        self.assertFalse(self.listo())

    def test_reintentar_runs_the_failed_and_waiting_steps_again_and_never_a_green_one(self):
        claimed(self.browser)
        components = self.enterContext(mock.patch.object(self.suite, "components", wraps=self.suite.components))
        with mock.patch.object(self.suite, "backups", side_effect=Unreachable(BACKUPS_REFUSED)):
            self.install()
            self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up()
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.daily_backup_time, "06:00\nautomaticUpdatesAreNotEnabled\n", "the backups ran")
        self.assertEqual(components.call_count, 1, "the components were green, so «Reintentar» left them alone")

    def test_a_silent_success_is_reported_as_a_failure(self):
        self.suite.nextcloud.ignored = {"session_lifetime"}  # Nextcloud answers the import and keeps that one out
        claimed(self.browser)
        self.install()
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()["Sesiones y registro de auditoría"], (
            "failed", "Nextcloud no conserva estos ajustes: session_lifetime. Presione «Reintentar»; si vuelve a "
                      "ocurrir, contacte a APS Conecta."))
        self.assertFalse(self.listo())

    def test_listo_waits_for_a_clean_end_of_install_check_and_a_step_whose_part_differs_turns_red_again(self):
        occ = self.suite.nextcloud.occ

        def talk_exits(*args, stdin=""):  # Talk exits while the steps after the start run
            self.suite.states["nextcloud-aio-talk"] = "stopped"
            return occ(*args, stdin=stdin)

        claimed(self.browser)
        with mock.patch.object(self.suite.nextcloud, "occ", side_effect=talk_exits):
            self.install()
            self.eventually(lambda: self.suite.starts, "AIO's start")
            self.suite.up()
            self.eventually(lambda: self.status() == "failed", "a failed install")
        steps = self.steps()
        self.assertEqual(steps["Inicio de la suite"], ("failed", TALK_STOPPED))
        self.assertEqual(steps["Sesiones y registro de auditoría"], ("green", None))
        self.assertFalse(self.listo())
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(lambda: self.suite.starts == 2, "AIO's start again, for Talk")
        self.suite.up()
        self.eventually(self.listo, "«Listo»")

    def test_a_step_whose_container_never_answers_fails_loudly(self):
        self.suite.nextcloud.down = True
        self.install_the_suite()
        self.eventually(lambda: self.status() == "failed", "a failed install")
        steps = self.steps()
        self.assertEqual({steps[name] for name in ("Certificados de confianza", "Tareas en segundo plano",
                                                   "Idioma y formato regional", "Sesiones y registro de auditoría")},
                         {("failed", NEXTCLOUD_DOWN)})
        self.assertFalse(self.listo())
