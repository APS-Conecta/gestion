# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The suite port: the only code that talks to AIO, the APS name service, Coolify's proxy folder and Nextcloud's
command line (occ).

The Provisionador is built with one implementation: `Suite` inside the mastercontainer, `FakeSuite` in the Seam 2
tests. A screen or an install step that needs the suite adds its method to the port and to both implementations.
"""

import socket
import ssl
import time
from typing import Protocol

INTERFACE = 8080  # AIO's interface inside the mastercontainer: Caddy, Containers/mastercontainer/internal.Caddyfile
INTERFACE_DOWN = "La interfaz de AIO no responde en el puerto 8080 del contenedor maestro."


class Unreachable(Exception):
    """A part of the suite did not answer; the Spanish message says which."""


class SuitePort(Protocol):
    def certificate(self, host: str) -> bytes:
        """The certificate, in DER, that AIO's interface presents to a browser that opens it at `host`."""


def arrival():
    """The mastercontainer's address on the network of its default route, where the host's published ports lead."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.connect(("192.0.2.1", 9))  # TEST-NET-1: a route lookup, no packet is sent
        return udp.getsockname()[0]


class Suite:
    """The suite port inside the mastercontainer."""

    def certificate(self, host, timeout=60):
        """Caddy issues AIO's interface certificate on demand: for the server name a browser sends, or, for an IP
        address, which browsers never send as one, for the container address the connection arrives at. So the
        handshake sends `host` as a browser would, to the address the host's published port leads to. Caddy may still
        be starting, so it is asked again for up to `timeout` seconds."""
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE  # the operator checks the fingerprint, not a chain
        deadline = time.monotonic() + timeout
        while True:
            try:
                with socket.create_connection((arrival(), INTERFACE), timeout=5) as raw, \
                        context.wrap_socket(raw, server_hostname=host) as tls:
                    return tls.getpeercert(binary_form=True)
            except OSError:
                if time.monotonic() > deadline:
                    raise Unreachable(INTERFACE_DOWN) from None
                time.sleep(1)


class FakeSuite:
    """The suite port for the Seam 2 tests: a fixed certificate for each host, as Caddy issues one per address."""

    def certificate(self, host):
        return b"FakeSuite certificate for " + host.encode()
