# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The components: the full suite (ADR 0021), on through AIO's own switches with Euro-Office as the office suite; every
other optional container of AIO's is off. Talk's recording server waits for #290."""

NAME = "Componentes"
NEEDS = ()
# AIO's switches, as its options form sets them (ConfigurationController) and its settings file keeps them.
SETTINGS = {"officeSuite": "eurooffice", "isTalkEnabled": True, "isClamavEnabled": True, "isImaginaryEnabled": True,
            "isFulltextsearchEnabled": True, "isHarpEnabled": True, "isTalkRecordingEnabled": False,
            "isDockerSocketProxyEnabled": False, "isWhiteboardEnabled": False}
# The components as «Revisar» names them.
NAMES = ["Talk", "Euro-Office", "ClamAV (antivirus)", "Imaginary (vistas previas de imágenes)",
         "Búsqueda de texto completo", "HaRP (aplicaciones externas)"]


def run(context):
    context.suite.components(SETTINGS)
