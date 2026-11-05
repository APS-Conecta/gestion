# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The suite port: the only code that talks to AIO, the APS name service, Coolify's proxy folder and Nextcloud's
command line (occ).

The Provisionador is built with one implementation: `Suite` inside the mastercontainer, `FakeSuite` in the Seam 2
tests. A screen or an install step that needs the suite adds its method to the port and to both implementations.
"""

import ipaddress
import json
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Protocol
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
INTERFACE = 8080  # AIO's interface inside the mastercontainer: Caddy, Containers/mastercontainer/internal.Caddyfile
# The certificates Caddy issues AIO's interface on demand, a folder per server name (its storage, internal.Caddyfile).
INTERFACE_CERTIFICATES = Path("/mnt/docker-aio-config/caddy-internal/certificates/local")
NAME_SERVICE = "https://gestion-nombres.apsconecta.workers.dev"  # APS's name service (APS-Conecta/gestion-aio)
CADDY = HERE.parents[1] / "community-containers" / "caddy" / "caddy.json"  # our Caddy, as AIO's community container
MASTERCONTAINER = "nextcloud-aio-mastercontainer"  # the name AIO requires of its own container
INTERFACE_DOWN = "La interfaz de AIO no responde en el puerto 8080 del contenedor maestro."
UNREACHABLE = ("No se pudo conectar con el servicio de nombres de APS Conecta. Revise la conexión a internet del "
               "servidor y presione «Reintentar».")
LIMITED = ("El servicio de nombres de APS Conecta limita las solicitudes que recibe desde una misma red. Presione "
           "«Reintentar» más tarde.")
REFUSED = "El servicio de nombres de APS Conecta rechazó la solicitud (HTTP {code}). Contacte a APS Conecta."
NO_SERVER_ADDRESS = ("No se pudo leer la dirección del servidor en la red del establecimiento. Presione «Reintentar»; "
                     "si vuelve a ocurrir, contacte a APS Conecta.")
AIO_REFUSED = ("AIO no aceptó la dirección del establecimiento. Presione «Reintentar»; si vuelve a ocurrir, contacte "
               "a APS Conecta.")
CREDENTIAL = ("name", "username", "password", "subdomain", "server_url")  # a claim's answer

# AIO's settings for the APS name, written by AIO's own configuration code: its first-run setup, so that AIO's
# passphrase exists as the first visit to its page would make it; the name as the domain, without vanilla's domain
# check, as upstream's Caddy DNS-challenge recipe and its deSEC registration set it; our Caddy as the one community
# container, with the settings its definition gives AIO (reverse-proxy mode: Apache's port and binding); and, among
# AIO's secrets, the name's acme-dns credential, which community-containers/caddy/caddy.json passes to Caddy. The values
# arrive on stdin: the host's ps shows the arguments of every process in the container.
USE_NAME = r"""
ini_set('display_errors', 'stderr');
require '/var/www/docker-aio/php/vendor/autoload.php';
$container = \AIO\DependencyInjection::GetContainer();
$container->get(\AIO\Data\Setup::class)->Setup();
$config = $container->get(\AIO\Data\ConfigurationManager::class);
$in = json_decode(stream_get_contents(STDIN), true, 4, JSON_THROW_ON_ERROR);
$config->aioCommunityContainers = ['caddy'];
$config->setDomain($in['domain'], true);
$config->setAioVariables($in['aio_variables']);
(function (array $secrets): void {
    $this->set('secrets', array_merge($this->get('secrets', []), $secrets));
})->call($config, $in['secrets']);
"""


class Unreachable(Exception):
    """A part of the suite did not answer; the Spanish message says which."""


class Held(Exception):
    """Another installation holds the name of that DEIS code."""


class SuitePort(Protocol):
    def certificate(self, host: str) -> bytes:
        """The certificate, in DER, that AIO's interface presents to a browser that opens it at `host`."""

    def claim(self, code: str) -> dict:
        """The APS name of the DEIS code `code` and its credential, claimed from the name service; Held when another
        installation holds it."""

    def publish(self, credential: dict, address: str) -> None:
        """Point the claimed name at `address`."""

    def server_address(self) -> str:
        """The server's address on the network its default route leaves by: the clinic's network."""

    def use_name(self, credential: dict) -> None:
        """Set AIO up to serve the claimed name with our Caddy, in reverse-proxy mode."""

    def opened(self, name: str) -> bool:
        """Whether a browser opened AIO's interface at `name`."""


def arrival():
    """This network's address on its default route: the mastercontainer's on Docker's bridge network, where the host's
    published ports lead, or the host's own on the host's network."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.connect(("192.0.2.1", 9))  # TEST-NET-1: a route lookup, no packet is sent
        return udp.getsockname()[0]


def caddy():
    """Our Caddy's definition as AIO's community container."""
    return json.loads(CADDY.read_text(encoding="utf-8"))["aio_services_v1"][0]


def acmedns(credential):
    """The name's acme-dns credential, under the names of the secrets community-containers/caddy/caddy.json passes."""
    return {"ACMEDNS_USERNAME": credential["username"], "ACMEDNS_PASSWORD": credential["password"],
            "ACMEDNS_SUBDOMAIN": credential["subdomain"], "ACMEDNS_SERVER_URL": credential["server_url"]}


def docker(*args):
    return subprocess.run(["docker", *args], check=True, capture_output=True, text=True, timeout=120).stdout.strip()


class NameService:
    """The APS name service's HTTP API (APS-Conecta/gestion-aio, aps/name-service/names.mjs). A claim by DEIS code
    answers the name, `<slug>.gestion.apsconecta.cl`, and its credential: a `username` and `password`, the name's
    acme-dns `subdomain` and the service's `server_url`, where the credential points the name at an address, answers
    Caddy's DNS challenge (acme-dns's /update) and frees the name. A refusal is logged, never a credential."""

    def __init__(self, url):
        self.url = url

    def claim(self, code):
        answer = self.call(f"{self.url}/claim", {"code": code})
        if not (isinstance(answer, dict) and all(isinstance(answer.get(key), str) for key in CREDENTIAL)
                and re.fullmatch(r"[a-z0-9.-]+", answer["name"])):
            raise Unreachable(UNREACHABLE)
        return answer

    def publish(self, credential, address):
        self.call(f"{credential['server_url']}/address", {"address": address}, credential)

    def release(self, credential):
        """Free the name with its own credential. The CI proof frees each name it claims; the Provisionador never
        frees one."""
        self.call(f"{credential['server_url']}/release", {"code": credential["username"]}, credential)

    @staticmethod
    def call(url, body, credential=None):
        headers = {"Content-Type": "application/json", "User-Agent": "aps-conecta-gestion"}
        if credential:
            headers.update({"X-Api-User": credential["username"], "X-Api-Key": credential["password"]})
        request = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
        path = urlsplit(url).path
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            print(f"name service {path}: {error.code} {error.read(500).decode(errors='replace')}", file=sys.stderr,
                  flush=True)
            if error.code == 409:
                raise Held() from None
            if error.code == 429:
                raise Unreachable(LIMITED) from None
            raise Unreachable(UNREACHABLE if error.code >= 500 else REFUSED.format(code=error.code)) from None
        except (OSError, ValueError) as error:
            print(f"name service {path}: {error}", file=sys.stderr, flush=True)
            raise Unreachable(UNREACHABLE) from None


class Suite:
    """The suite port inside the mastercontainer."""

    def __init__(self):
        self.names = NameService(NAME_SERVICE)

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

    def claim(self, code):
        return self.names.claim(code)

    def publish(self, credential, address):
        self.names.publish(credential, address)

    def server_address(self):
        """The mastercontainer sits on Docker's bridge network, which hides the host's address. So a short-lived
        container of the mastercontainer's own image reads it on the host's network, through the Docker socket."""
        try:
            image = docker("inspect", "--format", "{{.Image}}", MASTERCONTAINER)
            address = docker("run", "--rm", "--network", "host", "--user", "www-data", "--cap-drop", "ALL",
                             "--entrypoint", "python3", image, "-I", "-c",
                             f"import sys; sys.path.insert(0, {str(HERE)!r}); import suite; print(suite.arrival())")
            return str(ipaddress.ip_address(address))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"server address: {getattr(error, 'stderr', None) or error}", file=sys.stderr, flush=True)
            raise Unreachable(NO_SERVER_ADDRESS) from None

    def use_name(self, credential):
        """AIO's settings for the name, through AIO's own configuration code (USE_NAME)."""
        values = {"domain": credential["name"], "aio_variables": caddy()["aio_variables"],
                  "secrets": acmedns(credential)}
        try:
            subprocess.run(["php", "-r", USE_NAME], input=json.dumps(values), capture_output=True, text=True,
                           check=True, timeout=120)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"AIO's settings: {getattr(error, 'stderr', None) or error}", file=sys.stderr, flush=True)
            raise Unreachable(AIO_REFUSED) from None

    def opened(self, name):
        """Caddy issues AIO's interface certificate for a name the first time a TLS client asks for it there, before
        the client judges the certificate, and keeps it in its storage."""
        return (INTERFACE_CERTIFICATES / name / f"{name}.crt").exists()


class FakeSuite:
    """The suite port for the Seam 2 tests: a certificate for each host, as Caddy issues one per address, and new ones
    after renew(), as Caddy's internal issuer renews them. Its name service gives the DEIS code <code> the name
    centro-<code>.gestion.apsconecta.cl once, refuses the codes another installation holds, and fails while `outage`
    is set. Its AIO keeps its settings file in `aio`, the server's address is `server` until DHCP changes it, and a
    browser whose resolver answers the server's address says hello() to AIO's interface at a name."""

    def __init__(self):
        self.renewals = 0
        self.claims = []  # the DEIS codes claimed, in order
        self.held = set()  # the DEIS codes another installation holds
        self.outage = False  # the name service, or the internet, does not answer
        self.credentials = {}  # by name, the credential the name service gave
        self.addresses = {}  # by name, the address it points at
        self.server = "192.168.1.10"
        self.aio = {}
        self.hellos = set()  # the names a TLS client asked AIO's interface for

    def certificate(self, host):
        return b"FakeSuite certificate for " + host.encode() + b" renewed" * self.renewals

    def renew(self):
        self.renewals += 1

    def claim(self, code):
        if self.outage:
            raise Unreachable(UNREACHABLE)
        name = f"centro-{code}.gestion.apsconecta.cl"
        if code in self.held or name in self.credentials:
            raise Held()
        self.claims.append(code)
        self.credentials[name] = {"name": name, "username": code, "password": f"fake-{len(self.claims)}-{code}",
                                  "subdomain": f"centro-{code}", "server_url": "https://nombres.example"}
        return dict(self.credentials[name])

    def publish(self, credential, address):
        if self.outage:
            raise Unreachable(UNREACHABLE)
        if self.credentials.get(credential["name"]) != credential:
            raise Unreachable(REFUSED.format(code=401))
        self.addresses[credential["name"]] = address

    def server_address(self):
        return self.server

    def use_name(self, credential):
        """What AIO's configuration code writes: the domain, the community container and the variables of its
        definition, and the secrets."""
        name = credential["name"]
        self.aio.update(domain=name, aio_community_containers="caddy")
        for variable in caddy()["aio_variables"]:
            key, value = variable.split("=", 1)
            self.aio[key] = value.replace("%NC_DOMAIN%", name)
        self.aio["secrets"] = {**self.aio.get("secrets", {}), **acmedns(credential)}

    def opened(self, name):
        return name in self.hellos

    def hello(self, name):
        self.hellos.add(name)
