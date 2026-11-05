# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Seam 2: «Componentes», the components step: Talk's recording server is on, with the full suite, on a server that
passes the recording threshold, and off on any other. The threshold is the Bootstrap's, beside its hardware floors."""

import re
from pathlib import Path

from test_provisionador import Installing

BOOTSTRAP = (Path(__file__).resolve().parents[1] / "bootstrap" / "install.sh").read_text()
# The cores and the memory in GiB a server records Talk calls with, as aps/bootstrap/install.sh alone sets them.
THRESHOLD = {key: int(re.search(rf"^{variable}=(\d+)$", BOOTSTRAP, re.M)[1])
             for key, variable in (("cpus", "RECORDING_MIN_CPUS"), ("memory_gib", "RECORDING_MIN_MEMORY_GIB"))}


class Recording(Installing):
    def recording(self, **machine):
        """AIO's switch for Talk's recording server once «Instalar» finished on a server with this hardware."""
        self.suite.machine = machine
        self.install_the_suite()
        self.eventually(self.listo, "«Listo»")
        return self.suite.aio["isTalkRecordingEnabled"]

    def test_a_server_at_the_threshold_records_talk_calls(self):
        self.assertIs(self.recording(**THRESHOLD), True)

    def test_a_server_one_core_short_does_not(self):
        self.assertIs(self.recording(**{**THRESHOLD, "cpus": THRESHOLD["cpus"] - 1}), False)

    def test_a_server_one_gib_short_does_not(self):
        self.assertIs(self.recording(**{**THRESHOLD, "memory_gib": THRESHOLD["memory_gib"] - 1}), False)

    def test_on_a_server_that_records_the_provisionadors_start_pulls_the_recording_servers_image_too(self):
        self.suite.machine = THRESHOLD
        self.app.pull_images()
        self.assertEqual([pull.get("isTalkRecordingEnabled") for pull in self.suite.pulled], [True])
