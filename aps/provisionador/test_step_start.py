# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Inicio de la suite», the start step: AIO's own start, each container's progress as AIO reads it, and the
step's reasons."""

import time
from unittest import mock

import steps
from suite import Unreachable
from test_provisionador import Installing, claimed

START = "Inicio de la suite"


class Start(Installing):
    def test_the_progress_shows_each_container_as_aio_reads_it_and_listo_waits_for_every_one(self):
        claimed(self.browser)
        self.install()
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up("nextcloud-aio-nextcloud")
        install = self.browser.get("/api/state")[1]["install"]
        self.assertEqual((install["status"], install["containers"]), ("installing", [
            {"name": "Apache & Caddy", "state": "starting"}, {"name": "Servidor de aplicaciones", "state": "running"},
            {"name": "Talk", "state": "starting"}, {"name": "EuroOffice", "state": "starting"}]))
        self.assertEqual(self.steps()[START], ("running", None))
        self.suite.up("nextcloud-aio-talk", "nextcloud-aio-eurooffice")
        time.sleep(0.3)  # many readings of the containers
        self.assertFalse(self.listo(), "Apache still starts")
        self.suite.up("nextcloud-aio-apache")
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.browser.get("/api/state")[0], 410, "«Listo» ends the session; AIO's page takes 8080")
        self.assertIn("«Listo»: el personal abre APS Conecta Gestión en https://centro-999001.gestion.apsconecta.cl",
                      self.log.getvalue())

    def test_a_container_that_never_runs_fails_the_start_with_its_name_until_reintentar_finds_it_running(self):
        self.enterContext(mock.patch.object(steps.start, "WAIT", 0.3))
        claimed(self.browser)
        self.install()
        self.eventually(lambda: self.suite.starts, "AIO's start")
        self.suite.up("nextcloud-aio-apache", "nextcloud-aio-nextcloud", "nextcloud-aio-eurooffice")
        self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[START], ("failed", "Estos contenedores de la suite no quedaron en ejecución: "
                                                         "Talk. Presione «Reintentar»; si vuelve a ocurrir, contacte a "
                                                         "APS Conecta."))
        self.assertFalse(self.listo())
        self.suite.up("nextcloud-aio-talk")
        self.assertEqual(self.install()[0], 202)  # «Reintentar»
        self.eventually(self.listo, "«Listo»")
        self.assertEqual(self.suite.starts, 1, "AIO's start is not sent again while no container is stopped")

    def test_a_suite_that_does_not_start_fails_the_start_with_aios_reason(self):
        claimed(self.browser)
        with mock.patch.object(self.suite, "start", side_effect=Unreachable("El contenedor maestro no logró iniciar "
                                                                            "la suite.")):
            self.install()
            self.eventually(lambda: self.status() == "failed", "a failed install")
        self.assertEqual(self.steps()[START], ("failed", "El contenedor maestro no logró iniciar la suite."))
