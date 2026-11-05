#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Provisionador: the single web wizard that runs the install, inside our mastercontainer.

Until «Listo», AIO's interface address shows only the Provisionador: Caddy hands it every request on 8080 but the
brand files under /aps/, with AIO's own certificate (provisionador.Caddyfile). At every start it prints the one-time
link, its QR code and that certificate's fingerprint to the mastercontainer's log. The link's address is the one the
operator's browser opens AIO's interface at, given as APS_INTERFACE_ADDRESS: a host, or host:port when the host's
port is not 8080.

Its one public surface is the HTTP API under /api, which the page in www/ uses and the Seam 2 tests drive. The state
is one JSON file in the mastercontainer's volume, so a reload, a restart or a reboot resumes it. The links' secrets
and the sessions are stored only as SHA-256 hashes. Any browser that opens a link exchanges its secret for a session
of its own; each start mints a fresh link, and every link printed stays valid until «Listo». «Listo» is the file
`listo` beside the state: it ends every link and every session, and from then on Caddy serves AIO's page at the same
address.

At «Dirección» it claims the establishment's APS name and keeps the name's credential beside the state, readable
only by its own account. Run as `provisionador.py update-address`, it is the address updater that keeps running after
«Listo» (dinit.d/aps-address-updater): every 10 minutes it points the name at the server's address. Run as
`provisionador.py release-name`, it frees the name whose credential arrives on stdin, never on a command line: the
Bootstrap's reset runs it before it removes anything, and the acceptance harness for each CI name it claimed.

«Instalar» sets AIO up through its settings file and starts the suite with AIO's own start (INSTALL, steps/); AIO's
page stays hidden until «Listo», which comes once AIO reads every container of the suite running. At every start
until «Listo», the Provisionador pulls the suite's images with AIO's own code, so that «Instalar» waits less.
"""

import base64
import hashlib
import hmac
import http.cookies
import ipaddress
import json
import os
import re
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import deis
from steps import backups, components, start, timezone
from suite import Held, Suite, SuitePort, Unreachable

HERE = Path(__file__).resolve().parent
REGISTER = HERE.parent / "deis"
STATE_DIR = Path("/mnt/docker-aio-config/provisionador")  # in the mastercontainer's volume
PORT = 8081  # on loopback: provisionador.Caddyfile hands AIO's interface to it
ADDRESS = "APS_INTERFACE_ADDRESS"
DEFAULT_PORT = 8080  # the interface port of vanilla's start command
LISTO = "listo"  # beside the state; provisionador.Caddyfile reads it too
NAME_CREDENTIAL = "aps-name.json"  # beside the state: the APS name's credential
COOKIE = "__Host-session"
MAX_BODY = 64 * 1024
CERTIFICATE_CHECK = 5 * 60  # seconds; Caddy's internal issuer renews its 12 h certificates after about 8 h
ADDRESS_UPDATE = 10 * 60  # seconds, as upstream's desec-ip-updater updates a deSEC domain's address
# The page and its own files, by request path: no request path is ever joined to a directory.
STATIC = {"/": HERE / "www" / "index.html", "/app.js": HERE / "www" / "app.js", "/app.css": HERE / "www" / "app.css"}
CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                 ".css": "text/css; charset=utf-8"}
DNS_NAME = re.compile(r"(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?", re.I)

LINK_LOG = """\
Abra este enlace en un computador o teléfono conectado a la red del establecimiento:

    {url}

{qr}
El navegador advertirá que la conexión no es privada, porque el servidor usa un certificado propio. Continúe solo si
la huella SHA-256 del certificado es:

    {fingerprint}

El enlace sirve hasta «Listo». Si el servidor se reinicia, aquí aparecerá un enlace nuevo, y este seguirá sirviendo.
"""
RENEWAL_LOG = """\
El certificado del servidor se renovó. Si el navegador vuelve a advertir que la conexión no es privada, continúe solo
si la huella SHA-256 del certificado es:

    {fingerprint}
"""
NO_ADDRESS = ("No hay enlace de instalación: falta la dirección con que se abre este servidor. Inicie el contenedor "
              f"maestro con --env {ADDRESS}=<dirección IP o nombre del servidor>, y su puerto si no es el {DEFAULT_PORT}"
              " (por ejemplo, 192.168.1.10 o 192.168.1.10:8081).")
NOT_JSON = "La solicitud no es JSON válido."
JSON_ONLY = "La solicitud debe enviarse en formato JSON."
NO_SESSION = "Abra el enlace de instalación que muestra el registro del servidor."
LINK_REFUSED = "Este enlace no sirve. Abra el enlace completo que muestra el registro del servidor."
UNKNOWN = "Ruta desconocida."
NOT_IN_REGISTER = "Ese establecimiento no está en el registro DEIS."
OFF_THE_MAP = "El punto del mapa debe tener una latitud entre -90 y 90 y una longitud entre -180 y 180."
CLOSED = ("La instalación terminó en «Listo»: esta dirección muestra ahora la administración de APS Conecta Gestión, "
          "y el enlace de instalación ya no sirve.")
LISTO_LOG = "La instalación terminó en «Listo»: el personal abre APS Conecta Gestión en https://{}"
PULLED = "Las imágenes de la suite están descargadas."  # acceptance's 30-rerun waits for it
FREED = "Se liberó el nombre APS {}."
FREE_ALREADY = "El nombre APS {} ya estaba libre."
NO_CENTRE = "Confirme primero el centro en «Centro»: la dirección es el nombre APS del establecimiento."
CENTRE_KEPT = "El centro ya no puede cambiarse: su dirección, {}, ya se obtuvo."
HELD = ("Otra instalación ya tiene el nombre APS de este establecimiento. Si es una instalación anterior del mismo "
        "establecimiento, APS Conecta puede liberarlo; después presione «Reintentar».")
NO_ADDRESS_YET = "Obtenga primero la dirección del establecimiento en «Dirección»."
UNEXPECTED = ("La instalación se detuvo por un error inesperado. Presione «Reintentar»; si vuelve a ocurrir, contacte a "
              "APS Conecta e indique el registro del contenedor maestro.")
# «Instalar»'s steps (steps/), in their order: AIO's settings for the choices, then AIO's own start.
INSTALL = (components, timezone, backups, start)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def known(value, hashes):
    return isinstance(value, str) and any(hmac.compare_digest(digest(value), h) for h in hashes)


def random_code():
    """256 random bits, URL-safe: the link's secret and the session cookie."""
    return base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()


def fingerprint(der):
    """A certificate's SHA-256 fingerprint, AA:BB:…, as browsers show it."""
    h = hashlib.sha256(der).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


def interface(address):
    """`address`, host or host:port with an IPv6 address in brackets, as (host, port); None when it is not one."""
    try:
        parts = urlsplit("//" + address)
        host, port = parts.hostname, parts.port or DEFAULT_PORT
    except ValueError:
        return None
    if parts.netloc != address or parts.username is not None or not host:
        return None
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not DNS_NAME.fullmatch(host):
            return None
    return host, port


def qr(url):
    """The link as a QR code for the log. qrencode reads the URL on stdin: the host's ps shows the arguments of
    every process in the container."""
    return subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2"], input=url.encode(), capture_output=True,
                          check=True).stdout.decode()


def json_object(data):
    """`data` as a JSON object, or None when it is not one."""
    try:
        body = json.loads(data)
    except (ValueError, RecursionError):
        return None
    return body if isinstance(body, dict) else None


class State:
    """The wizard's state: one JSON file, replaced whole under a lock."""

    def __init__(self, directory):
        self.dir = Path(directory)
        self.dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = self.dir / "state.json"
        self.lock = threading.Lock()

    def listo(self):
        return (self.dir / LISTO).exists()

    def read(self):
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}

    def change(self, update):
        """Apply `update` to the state and keep what it made of it; returns what `update` returned."""
        with self.lock:
            data = self.read()
            answer = update(data)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
            os.replace(tmp, self.path)
            return answer


class Credential:
    """The APS name's credential, as the name service answered the claim: one file beside the state that only the
    Provisionador's account reads. The mastercontainer's start opens its whole volume to the group (upstream's
    start.sh), so each process that keeps the file closes it again."""

    def __init__(self, directory):
        self.path = Path(directory) / NAME_CREDENTIAL
        try:
            os.chmod(self.path, 0o600)
        except FileNotFoundError:
            pass

    def read(self):
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None

    def write(self, credential):
        tmp = self.path.with_suffix(".tmp")
        tmp.unlink(missing_ok=True)
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as file:
            json.dump(credential, file)
        os.replace(tmp, self.path)


class Provisionador:
    def __init__(self, state_dir, register, suite: SuitePort, address):
        self.state = State(state_dir)
        self.credential = Credential(state_dir)
        self.claiming = threading.Lock()  # one claim at a time, so a name is claimed once
        self.register = deis.Register(register)
        self.suite = suite
        self.interface = interface(address)
        self.shown = None  # the fingerprint the log printed last
        self.installing = threading.Lock()  # one install at a time
        self.worker = None  # the thread that runs «Instalar»'s steps

    def server(self, address=("127.0.0.1", PORT)):
        httpd = Server(address, Handler)
        httpd.app = self
        return httpd

    def announce(self):
        """Print the one-time link, its QR code and the certificate's fingerprint to the log. The links printed before
        stay valid."""
        if self.interface is None:
            print(NO_ADDRESS, flush=True)
            return
        host, port = self.interface
        self.shown = fingerprint(self.suite.certificate(host))
        secret = random_code()
        self.state.change(lambda s: s.update(links=s.get("links", []) + [digest(secret)]))
        url = f"https://{f'[{host}]' if ':' in host else host}:{port}/#{secret}"
        print(LINK_LOG.format(url=url, qr=qr(url), fingerprint=self.shown), flush=True)

    def check_certificate(self):
        """Print the fingerprint of the certificate AIO's interface presents now, without the link, when it is not the
        one the log printed last: Caddy's internal issuer renews it while the links stay valid."""
        if self.interface is None:
            return
        try:
            shown = fingerprint(self.suite.certificate(self.interface[0]))
        except Unreachable:
            return  # the next check asks again
        if shown != self.shown:
            self.shown = shown
            print(RENEWAL_LOG.format(fingerprint=shown), flush=True)

    def open_session(self, session, body):
        """POST /api/session {"link": <a link's secret>}: a browser that already has a session keeps it; otherwise any
        link printed since the install began opens one. Returns the new session, if any."""
        def exchange(s):
            if known(session, s.get("sessions", [])):
                return 200, {"ok": True}, None
            if not known(body.get("link"), s.get("links", [])):
                return 401, {"error": LINK_REFUSED}, None
            new = random_code()
            s["sessions"] = s.get("sessions", []) + [digest(new)]
            return 200, {"ok": True}, new
        return self.state.change(exchange)

    def has_session(self, session):
        return known(session, self.state.read().get("sessions", []))

    def address(self, state):
        """The APS name «Dirección» set up, and whether a browser opened AIO's interface at it: the page asks for it
        there, and a resolver that drops answers pointing to private addresses keeps that request from the server."""
        name = state.get("address", {}).get("name")
        return name and {"name": name, "opened": self.suite.opened(name)}

    def get_state(self, query, body):
        state = self.state.read()
        # «Revisar», once «Dirección» claimed the name: what «Instalar» sets up beside the centre, its name and timezone.
        review = state.get("address") and {"components": components.NAMES,
                                           "backup": {"folder": backups.FOLDER, "time": backups.TIME}}
        return 200, {"centre": state.get("centre"), "address": self.address(state), "review": review,
                     "install": self.progress(state)}

    def progress(self, state):
        """None before «Instalar»; then whether the install runs or failed, with its reasons, and each container of the
        suite with its state as AIO reads it. A reading that fails says why, and the next one asks again."""
        install = state.get("install")
        if install is None:
            return None
        try:
            return {**install, "containers": [{"name": c["name"], "state": c["state"]} for c in self.suite.containers()]}
        except Unreachable as outage:
            return {**install, "containers": [], "error": str(outage)}

    def post_install(self, query, body):
        """POST /api/install, «Instalar» and «Reintentar»: the steps run in the background, and GET /api/state shows
        their progress. While they run, pressing it again starts nothing more."""
        if not self.state.read().get("address"):
            return 409, {"error": NO_ADDRESS_YET}
        self.install()
        return 202, {"install": self.progress(self.state.read())}

    def pull_images(self):
        """At a start of the Provisionador, until «Listo»: the images of the suite «Instalar» starts, pulled with AIO's
        own code, so that «Instalar» waits less. A pull that fails is logged; «Instalar» pulls them again."""
        try:
            self.suite.pull(components.SETTINGS)
        except Unreachable as outage:
            print(outage, file=sys.stderr, flush=True)
            return
        print(PULLED, flush=True)

    def resume(self):
        """At a start of the Provisionador: an install a restart cut short goes on by itself, its steps being
        idempotent."""
        if (self.state.read().get("install") or {}).get("status") == "installing":
            self.install()

    def install(self):
        """Run INSTALL's steps in the background, unless they run already."""
        with self.installing:
            if self.worker is not None and self.worker.is_alive():
                return
            self.state.change(lambda s: s.update(install={"status": "installing"}))
            self.worker = threading.Thread(target=self.run_install, daemon=True)
            self.worker.start()

    def run_install(self):
        """Each step in order; the first that fails ends the install with its reasons. The last one done is «Listo»."""
        context = SimpleNamespace(suite=self.suite, centre=self.state.read()["centre"], interface=self.interface)
        for step in INSTALL:
            try:
                reasons = step.run(context) or []
            except Unreachable as outage:
                reasons = [str(outage)]
            except Exception:  # a defect: the log gets the traceback, the operator a reason
                traceback.print_exc()
                reasons = [UNEXPECTED]
            if reasons:
                self.state.change(lambda s: s.update(install={"status": "failed", "reasons": reasons}))
                return
        (self.state.dir / LISTO).touch()
        print(LISTO_LOG.format(self.state.read()["address"]["name"]), flush=True)

    def get_register(self, query, body):
        return 200, self.register.facets()

    def get_establishments(self, query, body):
        """GET /api/establishments?region=&comuna=&type=&name=: the register rows matching every filter."""
        filters = {k: v[0] for k, v in parse_qs(query).items() if k in ("region", "comuna", "type", "name")}
        return 200, self.register.search(**filters)

    def post_centre(self, query, body):
        """POST /api/centre {"code", "point"?}: the establishment, at its official point or where the operator moved
        it on the map."""
        code = body.get("code")
        row = self.register.by_code.get(code) if isinstance(code, str) else None
        if row is None:
            return 404, {"error": NOT_IN_REGISTER}
        moved = body.get("point")
        point = None if moved is None else deis.point(moved)
        if moved is not None and point is None:
            return 400, {"error": OFF_THE_MAP}
        claimed = self.credential.read()
        if claimed and claimed["username"] != code:
            return 409, {"error": CENTRE_KEPT.format(claimed["name"])}
        centre = deis.centre(row, point)
        self.state.change(lambda s: s.update(centre=centre))
        return 200, {"centre": centre}

    def post_address(self, query, body):
        """POST /api/address: the centre's APS name. The first call claims it from the name service by the centre's
        DEIS code and keeps its credential, so the name is claimed once; every call sets AIO up to serve the name and
        points the name at the server's address."""
        centre = self.state.read().get("centre")
        if centre is None:
            return 409, {"error": NO_CENTRE}
        with self.claiming:
            credential = self.credential.read()
            try:
                if credential is None:
                    credential = self.suite.claim(centre["code"])
                    self.credential.write(credential)
                self.suite.use_name(credential)
                self.suite.publish(credential, self.suite.server_address())
            except Held:
                return 409, {"error": HELD}
            except Unreachable as outage:
                return 503, {"error": str(outage)}
        self.state.change(lambda s: s.update(address={"name": credential["name"]}))
        return 200, {"address": self.address(self.state.read())}

    ROUTES = {
        ("GET", "/api/state"): get_state,
        ("GET", "/api/register"): get_register,
        ("GET", "/api/establishments"): get_establishments,
        ("POST", "/api/centre"): post_centre,
        ("POST", "/api/address"): post_address,
        ("POST", "/api/install"): post_install,
    }

    def call(self, method, path, query, body):
        route = self.ROUTES.get((method, path))
        if route is None:
            return 404, {"error": UNKNOWN}
        return route(self, query, body)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    app = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 30
    server_version = "Provisionador"
    sys_version = ""

    def log_message(self, format, *args):
        pass  # no request lines: the log carries no session

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def dispatch(self, method):
        app = self.server.app
        if app.state.listo():
            self.close_connection = True  # a body left unread must not be taken for the next request
            return self.send_json(410, {"error": CLOSED})
        path, _, query = self.path.partition("?")
        if method == "GET" and not path.startswith("/api/"):
            return self.send_static(path)
        body = {}
        if method == "POST":
            try:
                data = self.read_body()
            except ValueError:
                self.close_connection = True  # an unread body must not be taken for the next request
                return self.send_json(400, {"error": NOT_JSON})
            if self.headers.get_content_type() != "application/json":
                return self.send_json(415, {"error": JSON_ONLY})  # another origin would need a preflight
            body = json_object(data)
            if body is None:
                return self.send_json(400, {"error": NOT_JSON})
        session, new_session = self.session(), None
        if (method, path) == ("POST", "/api/session"):
            status, answer, new_session = app.open_session(session, body)
        elif not app.has_session(session):
            status, answer = 401, {"error": NO_SESSION}
        else:
            status, answer = app.call(method, path, query, body)
        cookie = f"{COOKIE}={new_session}; Path=/; Secure; HttpOnly; SameSite=Strict" if new_session else None
        self.send_json(status, answer, cookie)

    def session(self):
        try:
            cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        except http.cookies.CookieError:
            return None
        return cookie[COOKIE].value if COOKIE in cookie else None

    def read_body(self):
        """The whole body, so a refused request leaves the connection in step for the next one."""
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY:
            raise ValueError("body size")
        return self.rfile.read(length)

    def send_static(self, path):
        file = STATIC.get(path)
        if file is None:
            return self.send_json(404, {"error": UNKNOWN})
        self.send(200, CONTENT_TYPES[file.suffix], file.read_bytes(), {"Cache-Control": "no-cache"})

    def send_json(self, status, answer, cookie=None):
        data = (json.dumps(answer, ensure_ascii=False) + "\n").encode()
        headers = {"Cache-Control": "no-store"}
        if cookie:
            headers["Set-Cookie"] = cookie
        self.send(status, "application/json; charset=utf-8", data, headers)

    def send(self, status, content_type, data, headers):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)


def every(seconds, task):
    """Call `task` every `seconds` seconds, for as long as the process runs."""
    while True:
        time.sleep(seconds)
        task()


def update_address(state_dir, suite: SuitePort):
    """Point the APS name at the server's address, once «Dirección» claimed it, so that the name follows a DHCP
    change. An unchanged address changes nothing at the name service; an outage waits for the next update."""
    credential = Credential(state_dir).read()
    if credential is None:
        return
    try:
        suite.publish(credential, suite.server_address())
    except Unreachable as outage:
        print(outage, file=sys.stderr, flush=True)


def release_name(suite: SuitePort, credential):
    """Free the APS name with its own credential. A name the name service no longer knows is free already."""
    try:
        freed = suite.release(credential)
    except Unreachable as outage:
        print(outage, file=sys.stderr, flush=True)
        return 1
    print((FREED if freed else FREE_ALREADY).format(credential["name"]), flush=True)
    return 0


def main(argv, suite=None):
    suite = suite or Suite()
    if argv == ["release-name"]:  # the Bootstrap's reset, and the acceptance harness: the credential on stdin
        return release_name(suite, json.load(sys.stdin))
    if argv == ["update-address"]:  # the address updater, aps/provisionador/dinit.d/aps-address-updater
        update_address(STATE_DIR, suite)
        every(ADDRESS_UPDATE, lambda: update_address(STATE_DIR, suite))
    app = Provisionador(STATE_DIR, deis.newest(REGISTER), suite, os.environ.get(ADDRESS, ""))
    if app.state.listo():
        print(CLOSED, flush=True)
        return 0
    httpd = app.server()
    try:
        app.announce()
    except Unreachable as outage:
        print(outage, file=sys.stderr, flush=True)
        return 1  # dinit starts it again
    app.resume()
    threading.Thread(target=app.pull_images, daemon=True).start()
    threading.Thread(target=every, args=(CERTIFICATE_CHECK, app.check_certificate), daemon=True).start()
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
