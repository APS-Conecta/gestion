# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The suite's start, with AIO's own start command, which pulls, creates and starts each container; then each container
answers in turn. The step goes by AIO's own reading of the containers: it sends AIO's start while one of them is
stopped, which starts only the containers not running, so that «Reintentar» or a restart of the Provisionador does not
start the suite twice, and it is done once AIO reads every container running."""

from steps import until
from suite import Unreachable

NAME = "Inicio de la suite"
NEEDS = ("components", "timezone", "backups")
WAIT = 30 * 60  # seconds: as long as the start may take, Nextcloud's first setup and a slow download included
NOT_RUNNING = ("Estos contenedores de la suite no quedaron en ejecución: {}. Presione «Reintentar»; si vuelve a "
               "ocurrir, contacte a APS Conecta.")


def aio_url(interface):
    """AIO's interface address, as AIO's start keeps it: host:port, an IPv6 address in brackets."""
    host, port = interface
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def unready(suite):
    """Why the suite is not up yet: the containers AIO does not read running, or why AIO's reading failed."""
    try:
        late = [c["name"] for c in suite.containers() if c["state"] != "running"]
    except Unreachable as outage:
        return [str(outage)]
    return [NOT_RUNNING.format(", ".join(late))] if late else []


def run(context):
    if any(c["state"] == "stopped" for c in context.suite.containers()):
        context.suite.start(aio_url(context.interface))
    return until(lambda: unready(context.suite), lambda reasons: not reasons, WAIT)
