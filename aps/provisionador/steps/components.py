# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The components: the full suite (ADR 0021), on through AIO's own switches with Euro-Office as the office suite; every
other optional container of AIO's is off, except Talk's recording server on a server that passes the recording
threshold, which the Bootstrap keeps beside its hardware floors and our image carries."""

import re
from pathlib import Path

NAME = "Componentes"
NEEDS = ()
# AIO's switches, as its options form sets them (ConfigurationController) and its settings file keeps them, but the
# recording server's, which settings() adds for the server.
SETTINGS = {"officeSuite": "eurooffice", "isTalkEnabled": True, "isClamavEnabled": True, "isImaginaryEnabled": True,
            "isFulltextsearchEnabled": True, "isHarpEnabled": True, "isDockerSocketProxyEnabled": False,
            "isWhiteboardEnabled": False}
# The components as «Revisar» names them.
NAMES = ["Talk", "Euro-Office", "ClamAV (antivirus)", "Imaginary (vistas previas de imágenes)",
         "Búsqueda de texto completo", "HaRP (aplicaciones externas)"]
BOOTSTRAP = (Path(__file__).resolve().parents[2] / "bootstrap" / "install.sh").read_text()
# The least cores and memory in GiB a server records Talk calls with: the Bootstrap's.
THRESHOLD = {key: int(re.search(rf"^{variable}=(\d+)$", BOOTSTRAP, re.M)[1])
             for key, variable in (("cpus", "RECORDING_MIN_CPUS"), ("memory_gib", "RECORDING_MIN_MEMORY_GIB"))}


def records(hardware):
    """Whether a server with this hardware, its cores and its memory in GiB, passes the recording threshold."""
    return all(hardware[key] >= least for key, least in THRESHOLD.items())


def settings(hardware):
    """AIO's switches for a server with this hardware."""
    return {**SETTINGS, "isTalkRecordingEnabled": records(hardware)}


def run(context):
    context.suite.components(settings(context.suite.hardware()))
