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
# The services of this build: APS's name service (APS-Conecta/gestion-aio), its production deployment as committed. The
# candidate pipeline stamps a test build's at release time (aps/acceptance/test-build.json): no runtime switch.
SERVICES = HERE / "services.json"
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
AIO_REFUSED = "AIO no aceptó {}. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."
NOT_STARTED = ("El contenedor maestro no logró iniciar la suite. Presione «Reintentar»; si vuelve a ocurrir, contacte a "
               "APS Conecta.")
NO_STATES = "AIO no pudo leer el estado de los contenedores de la suite."
NOT_PULLED = "No se pudieron descargar las imágenes de la suite; «Instalar» las descarga."
CREDENTIAL = ("name", "username", "password", "subdomain", "server_url")  # a claim's answer

# AIO's own code, as its cron scripts run it (php/src/Cron), with the values on stdin: the host's ps shows the arguments
# of every process in the container. Each script below follows it.
AIO = r"""
ini_set('display_errors', 'stderr');
ini_set('memory_limit', '2048M');
require '/var/www/docker-aio/php/vendor/autoload.php';
$container = \AIO\DependencyInjection::GetContainer();
$config = $container->get(\AIO\Data\ConfigurationManager::class);
$in = json_decode(stream_get_contents(STDIN), true, 8, JSON_THROW_ON_ERROR);
"""
# AIO's settings for the APS name: its first-run setup, so that AIO's passphrase exists as the first visit to its page
# would make it; the name as the domain, without vanilla's domain check, as upstream's Caddy DNS-challenge recipe and its
# deSEC registration set it; our Caddy as the one community container, with the settings its definition gives AIO
# (reverse-proxy mode: Apache's port and binding); and, among AIO's secrets, the name's acme-dns credential, which
# community-containers/caddy/caddy.json passes to Caddy.
USE_NAME = AIO + r"""
$container->get(\AIO\Data\Setup::class)->Setup();
$config->aioCommunityContainers = ['caddy'];
$config->setDomain($in['domain'], true);
$config->setAioVariables($in['aio_variables']);
(function (array $secrets): void {
    $this->set('secrets', array_merge($this->get('secrets', []), $secrets));
})->call($config, $in['secrets']);
"""
# AIO's switches, as its options form sets them (ConfigurationController::SetConfig); the office suite is one choice.
SWITCH = r"""
$config->startTransaction();
foreach ($in['settings'] as $key => $value) {
    $config->$key = $key === 'officeSuite' ? \AIO\Data\OfficeSuite::from($value) : $value;
}
"""
COMPONENTS = AIO + SWITCH + "$config->commitTransaction();\n"
# AIO's own pull of every image its start runs for those switches and our Caddy, the switches never committed: AIO's
# settings stay as they are until «Instalar».
PULL = AIO + SWITCH + r"""
$config->aioCommunityContainers = ['caddy'];
$container->get(\AIO\Controller\DockerController::class)->PullAllContainerImages();
"""
TIMEZONE = AIO + "$config->timezone = $in['timezone'];\n"
# AIO's backup form: the folder on the server, then the daily time, without automatic updates and with success
# notifications, as AIO's page writes them.
BACKUPS = AIO + r"""
$config->setBorgLocationVars($in['folder'], '');
$config->setDailyBackupTime($in['time'], false, true);
"""
# AIO's start button (DockerController::StartContainer): it records the interface's address and the start, then pulls,
# creates and starts every container in order, Apache last.
START = AIO + r"""
$config->startTransaction();
$config->aioUrl = $in['aio_url'];
$config->wasStartButtonClicked = true;
$config->commitTransaction();
$container->get(\AIO\Controller\DockerController::class)->startTopContainer(true);
"""
# The containers AIO's page lists, with AIO's reading of their state: stopped, starting (running, its port does not
# answer yet) or running. Like AIO's page, it first joins the mastercontainer to the suite's network, where those
# ports answer.
CONTAINERS = AIO + r"""
$container->get(\AIO\Docker\DockerActionManager::class)->ConnectMasterContainerToNetwork();
$listed = [];
foreach ($container->get(\AIO\ContainerDefinitionFetcher::class)->FetchDefinition() as $c) {
    if (!$c->hideFromList) {
        $listed[] = ['id' => $c->identifier, 'name' => $c->displayName, 'state' => $c->GetStartingState()->value];
    }
}
echo json_encode($listed, JSON_THROW_ON_ERROR);
"""


class Unreachable(Exception):
    """A part of the suite did not answer; the Spanish message says which."""


class Held(Exception):
    """Another installation holds the name of that DEIS code."""


class Unknown(Unreachable):
    """The name service does not know the credential: its name is free."""


class SuitePort(Protocol):
    def certificate(self, host: str) -> bytes:
        """The certificate, in DER, that AIO's interface presents to a browser that opens it at `host`."""

    def claim(self, code: str) -> dict:
        """The APS name of the DEIS code `code` and its credential, claimed from the name service; Held when another
        installation holds it."""

    def publish(self, credential: dict, address: str) -> None:
        """Point the claimed name at `address`."""

    def release(self, credential: dict) -> bool:
        """Free the claimed name with its own credential: True, or False when the name service no longer knows the
        credential, so the name is free already."""

    def server_address(self) -> str:
        """The server's address on the network its default route leaves by: the clinic's network."""

    def use_name(self, credential: dict) -> None:
        """Set AIO up to serve the claimed name with our Caddy, in reverse-proxy mode."""

    def opened(self, name: str) -> bool:
        """Whether a browser opened AIO's interface at `name`."""

    def pull(self, settings: dict) -> None:
        """Pull the images AIO's start runs with these switches and our Caddy, writing none of AIO's settings."""

    def components(self, settings: dict) -> None:
        """Set AIO's switches for its optional containers, as AIO's settings file keeps them."""

    def timezone(self, zone: str) -> None:
        """Set AIO's timezone, which AIO gives every container of the suite."""

    def backups(self, folder: str, time: str) -> None:
        """Set AIO's nightly backup: to `folder` on the server, daily at `time` (UTC)."""

    def start(self, aio_url: str) -> None:
        """Start the suite with AIO's own start, which pulls, creates and starts each container."""

    def containers(self) -> list:
        """Each container AIO's page lists, by its `id` and AIO's `name` for it, with its `state` as AIO reads it:
        stopped, starting or running."""


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
        """Free the name with its own credential: the Bootstrap's reset, the CI proof and the acceptance harness free
        the names they claimed; the Provisionador's install never frees one."""
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
            if error.code == 401 and credential:
                raise Unknown(REFUSED.format(code=401)) from None
            if error.code == 429:
                raise Unreachable(LIMITED) from None
            raise Unreachable(UNREACHABLE if error.code >= 500 else REFUSED.format(code=error.code)) from None
        except (OSError, ValueError) as error:
            print(f"name service {path}: {error}", file=sys.stderr, flush=True)
            raise Unreachable(UNREACHABLE) from None


class Suite:
    """The suite port inside the mastercontainer."""

    def __init__(self):
        self.names = NameService(json.loads(SERVICES.read_text(encoding="utf-8"))["name_service"])

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

    def release(self, credential):
        try:
            self.names.release(credential)
        except Unknown:
            return False
        return True

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

    @staticmethod
    def aio(script, values, failed, timeout=120):
        """What `script`, AIO's own code, printed with `values` on its stdin; Unreachable with `failed` when it fails."""
        try:
            return subprocess.run(["php", "-r", script], input=json.dumps(values), capture_output=True, text=True,
                                  check=True, timeout=timeout).stdout
        except (OSError, subprocess.SubprocessError) as error:
            print(f"AIO: {getattr(error, 'stderr', None) or error}", file=sys.stderr, flush=True)
            raise Unreachable(failed) from None

    def use_name(self, credential):
        """AIO's settings for the name, through AIO's own configuration code (USE_NAME)."""
        values = {"domain": credential["name"], "aio_variables": caddy()["aio_variables"],
                  "secrets": acmedns(credential)}
        self.aio(USE_NAME, values, AIO_REFUSED.format("la dirección del establecimiento"))

    def opened(self, name):
        """Caddy issues AIO's interface certificate for a name the first time a TLS client asks for it there, before
        the client judges the certificate, and keeps it in its storage."""
        return (INTERFACE_CERTIFICATES / name / f"{name}.crt").exists()

    def pull(self, settings):
        self.aio(PULL, {"settings": settings}, NOT_PULLED, timeout=3600)

    def components(self, settings):
        self.aio(COMPONENTS, {"settings": settings}, AIO_REFUSED.format("los componentes de la suite"))

    def timezone(self, zone):
        self.aio(TIMEZONE, {"timezone": zone}, AIO_REFUSED.format("la zona horaria del establecimiento"))

    def backups(self, folder, time):
        self.aio(BACKUPS, {"folder": folder, "time": time}, AIO_REFUSED.format("las copias de seguridad"))

    def start(self, aio_url):
        """AIO's start answers once it started every container; their images may still be downloading."""
        self.aio(START, {"aio_url": aio_url}, NOT_STARTED, timeout=3600)

    def containers(self):
        try:
            listed = json.loads(self.aio(CONTAINERS, {}, NO_STATES))
        except ValueError:
            raise Unreachable(NO_STATES) from None
        return [{**c, "state": c["state"] if c["state"] in ("starting", "running") else "stopped"} for c in listed]


class FakeSuite:
    """The suite port for the Seam 2 tests: a certificate for each host, as Caddy issues one per address, and new ones
    after renew(), as Caddy's internal issuer renews them. Its name service gives the DEIS code <code> the name
    centro-<code>.gestion.apsconecta.cl once, refuses the codes another installation holds, and fails while `outage`
    is set. Its AIO keeps its settings file in `aio` and its daily backup file in `daily_backup_time`, the server's
    address is `server` until DHCP changes it, and a browser whose resolver answers the server's address says hello() to
    AIO's interface at a name. AIO's start makes each of its CONTAINERS starting, until up() makes their ports answer."""

    CONTAINERS = {"nextcloud-aio-apache": "Apache & Caddy", "nextcloud-aio-nextcloud": "Servidor de aplicaciones",
                  "nextcloud-aio-talk": "Talk", "nextcloud-aio-eurooffice": "EuroOffice"}  # by id, AIO's names

    def __init__(self):
        self.renewals = 0
        self.claims = []  # the DEIS codes claimed, in order
        self.held = set()  # the DEIS codes another installation holds
        self.outage = False  # the name service, or the internet, does not answer
        self.credentials = {}  # by name, the credential the name service gave
        self.addresses = {}  # by name, the address it points at
        self.server = "192.168.1.10"
        self.aio = {}
        self.daily_backup_time = None
        self.hellos = set()  # the names a TLS client asked AIO's interface for
        self.starts = 0  # how often AIO's start was sent
        self.states = {}  # by container, AIO's reading of it once AIO's start created it
        self.pulled = []  # the switches of each image pull

    def pull(self, settings):
        self.pulled.append(settings)

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
            raise Unknown(REFUSED.format(code=401))
        self.addresses[credential["name"]] = address

    def release(self, credential):
        if self.outage:
            raise Unreachable(UNREACHABLE)
        if self.credentials.get(credential["name"]) != credential:
            return False
        del self.credentials[credential["name"]]
        self.addresses.pop(credential["name"], None)
        return True

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

    def components(self, settings):
        self.aio.update(settings)

    def timezone(self, zone):
        self.aio["timezone"] = zone

    def backups(self, folder, time):
        """AIO's backup location in its settings file, and its daily backup file as AIO writes it: the time, then that
        automatic updates are off; success notifications are on."""
        self.aio.update(borg_backup_host_location=folder, borg_remote_repo="")
        self.daily_backup_time = f"{time}\nautomaticUpdatesAreNotEnabled\n"

    def start(self, aio_url):
        self.starts += 1
        self.aio.update(AIO_URL=aio_url, wasStartButtonClicked=True)
        for container in self.CONTAINERS:
            if self.states.get(container, "stopped") == "stopped":
                self.states[container] = "starting"

    def containers(self):
        return [{"id": container, "name": name, "state": self.states.get(container, "stopped")}
                for container, name in self.CONTAINERS.items()]

    def up(self, *containers):
        """The containers' ports answer, all of them by default: AIO reads them running."""
        for container in containers or self.CONTAINERS:
            self.states[container] = "running"
