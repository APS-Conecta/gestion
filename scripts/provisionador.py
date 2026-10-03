#!/usr/bin/env python3
"""Provisionador — the host-side wizard that walks an operator from a fresh AIO install to a
provisioned clinic (FRD S5 core + S6 screens).

  scripts/provisionador.py               serve the API + UI (bearer token printed at start)
  scripts/provisionador.py --self-test   the FRD's named self-tests; exit 0 green / 1 red

The operator flow, one establishment per install (D13): Centro → equipos y personas →
revisar/dry-run → divergencia vacía. This file is built across
installer-design slices 14-17: slice 14 ships the HTTP server, the bearer auth, /api/deis (the
cascade's search leg) and /api/sitio (site.sh generation); slice 15 adds /api/usuarios (the roster:
CSV validation against the site and the shared registry) plus the credentials sealing; slice 16 adds
the executor — /api/generar (the FRD's review/dry-run AND the run: .env convergence, the seed, the
roster driver, the divergence gate); slice 17 the eight es-CL screens over these routes. L3 S2 replaced /api/deis with
/api/centros + /api/centro: the Centro screen's one payload and the held choice.

Python stdlib only, like deis.py — the install host is assumed to carry python3, bash, git and
docker, nothing else (#77) — plus openssl, which ca-certificates brings, to sign the installer's own
certificate. HTTPS on the LAN with that certificate (L3 S1, owner 2026-10-02; a13: no code and no
cookie crosses the LAN in clear): the CSPRNG token below is the only auth, so this never faces the
public internet — preflight (S7) reports the port and the clinic's own firewall keeps the edge.

deis.py is IMPORTED, never shelled out to: load/write_site are the pure functions the
endpoints ride, and its ask() — input()-driven, terminal-shaped — is replaced by the UI here, with
ask()'s (gid, display, bare) triple construction replicated exactly: gids flow into SITE_TEAMS,
SITE_FOLDERS mounts and SITE_ACL rows, so a drift here is a divergence event, not a cosmetic one.
deis.py's FATAL paths sys.exit(); on the serving paths the calls catch SystemExit and answer JSON
instead of dying — a half-served wizard page is worse than an honest 4xx — while startup re-exits
fatally with the hint intact, before any socket opens.

The server keeps no session: the token is the credential and the state. The one thing it holds is
the centre chosen at step 6, until step 8 writes the site file that answers from then on — no code
rides a URL (L3 S2), a restart before step 8 costs one re-pick, and every endpoint is one curl. The
token never rides a request: the console's one link
carries it in the URL fragment (#acceso=…), which browsers never send; the sign-in page trades it
for the cookie and wipes it from the address bar. On the wire the Authorization header (and the
login cookie) is the only carrier, and the request log is silent (R42).
"""
import csv
import errno
import hashlib
import hmac
import html
import http.client
import io
import json
import os
import re
import secrets
import shlex
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # deis.py sits beside this file; the host bundle keeps the repo layout
import deis  # noqa: E402  — the path insert above is the import mechanism

# The bearer token, env-init's discipline in Python: 32 bytes from the stdlib CSPRNG, HEX, never
# base64 (B-004 — no character any layer treats as syntax). Printed ONCE, in the startup banner,
# compared constant-time, and never logged.
TOKEN = ""
# The register, loaded once at startup so a missing register fails BEFORE any socket opens — the
# operator reads a fix hint, not a half-booted wizard. Read-only afterwards.
SNAPSHOT = ""
ROWS = []

# The DEIS-codigo whitelist (FRD S5). The site directory IS the codigo — the register's own unique
# key, one establishment per install (D13) — so this regex is also the path-traversal guard:
# whatever passes it cannot name anything but sites/<digits>/site.sh.
CODIGO = re.compile(r"[0-9]{4,6}")

# The chosen centre (L3 S2): the browser's «Confirmar centro» lands here and holds until step 8
# writes the site file, which answers from then on — one install, one establishment (D13).
# Process-local on purpose: a restart before step 8 costs one re-pick, nothing else.
CENTRO = None
# The Centro screen's orders (the approved design's): regions north to south — the register's
# codes are not — and the types with the long name the card shows. R36: every type is offered,
# none excluded by default.
REGION_ORDER = ("15", "01", "02", "03", "04", "05", "13", "06", "07", "16", "08", "09", "14", "10",
                "11", "12")
TIPOS = (("CESFAM", "Centro de Salud Familiar"), ("CECOSF", "Centro Comunitario de Salud Familiar"),
         ("PSR", "Posta de Salud Rural"), ("SAPU", "Servicio de Atención Primaria de Urgencia"),
         ("SUR", "Servicio de Urgencia Rural"), ("SAR", "Servicio de Alta Resolutividad"),
         ("COSAM", "Centro Comunitario de Salud Mental"), ("CGU", "Consultorio General Urbano"),
         ("CGR", "Consultorio General Rural"))

# Dynamic bind (FRD S5): try these in order, then port 0 (OS-assigned). A busy port is a
# fall-through, never an error — the banner prints whatever actually bound.
PORTS = (8081, 8082, 8083)

# The roster CSV (slice 15) is KBs; this exists so a junk Content-Length cannot park a thread on an
# unbounded read (FINDINGS #10 — bounded waits everywhere).
MAX_BODY = 8 * 1024 * 1024


# ── The roster (slice 15, FRD S5) ──────────────────────────────────────────────────────
# usuario;nombre;apellidos;correo;grupos;primer_admin — semicolon-delimited, UTF-8. Excel's
# "CSV UTF-8" carries a BOM: stripped on read, never required, and the canonical copy this writes
# carries none. NO password column, on purpose: a spreadsheet is the worst place to keep a secret
# (#80's whole point — env-init exists because hand-invented .env passwords were), so every
# password is generated host-side and sealed to credentials.txt below. The file the clinic brings
# carries no secret material at all.
ROSTER_HEADER = ("usuario", "nombre", "apellidos", "correo", "grupos", "primer_admin")
UID_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")  # the register's own uids: director, jefe.farmacia…
EMAIL_RE = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")
UNKNOWN_GROUP = "no existe en este centro"   # the unknown-group line; the 400 keys its valid list on it
# Phase 20 IS the group registry — parsed, never restated (registry_groups below).
PHASE20 = os.path.join(HERE, "..", "provisioning", "phases", "20-groups.sh")
# Where the sealed credentials sheet lives (FRD S5; the host bundle's directory — S7 wires
# /opt/aps-conecta into backups). The self-test redirects it; this default is the only literal.
CRED_PATH = "/opt/aps-conecta/credentials.txt"
ESTADO_PATH = "/opt/aps-conecta/estado.txt"   # the last execution's verdict (a10): 0644, «aps-conecta estado»
AIO_STATE = "/opt/aps-conecta/aio"   # the host's wizard state (0700): passphrase, domain, Talk options — passed to it

# The installer's own certificate authority and the leaf it signs for the link's address (L3 S1,
# owner 2026-10-02). The CA is kept: the suite's certificate (L4, R22) hangs from the same one and
# staff import it once. The self-test redirects this; the default is the only literal.
CERT_DIR = "/opt/aps-conecta/certificados"
SERVICE = "Provisionador APS Conecta"   # the identity /api/salud answers (R33); the host probe keys on it
# Set by a green «Revisar y ejecutar» over HTTP: the server then closes itself (SEC-2, a13).
DONE = threading.Event()

# The step registry lives in the host CLI (a11, «one home per step»): read once at start into this
# list, never restated here. The rail, the step numbers and the titles all come from it.
ROOT_DIR = os.path.join(HERE, "..")
HOST_CLI = os.path.join(ROOT_DIR, "host", "aps-conecta")
STEPS = []
LAN_IP, HOSTNAME, PORT = "", "", 0   # the session's address, the server's name, the bound port — set in main
# phase 15's theming:slogan, the host CLI's MOTTO — one string, three homes, each pinned by a self-test
MOTTO = "La salud primaria que compartimos es la que mejora"
REPO = "github.com/APS-Conecta/gestion"
# /recursos/<name> → the theme's own files: local, zero egress (the fonts are OFL). A whitelist —
# no path is ever joined from the request.
ASSETS = {
    "fraunces.woff2": ("themes/apsconecta/core/fonts/Fraunces.woff2", "font/woff2"),
    "fraunces-italica.woff2": ("themes/apsconecta/core/fonts/Fraunces-Italic.woff2", "font/woff2"),
    "nunito-sans.woff2": ("themes/apsconecta/core/fonts/NunitoSans.woff2", "font/woff2"),
    "fondo.svg": ("themes/apsconecta/core/img/background.svg", "image/svg+xml"),
    "favicon.svg": ("themes/apsconecta/core/img/favicon.svg", "image/svg+xml"),
}


def read_steps():
    """The registry, as `aps-conecta pasos` prints it: id · título · dónde · subcomando · propósito
    · resultado. A missing or unreadable list stops the start before any socket opens."""
    try:
        out = subprocess.run(["bash", HOST_CLI, "pasos"], capture_output=True, text=True,
                             timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.exit(f"✗ no se pudo leer la lista de pasos ({HOST_CLI}): {e}")
    keys = ("id", "titulo", "donde", "comando", "para", "resultado")
    steps = [dict(zip(keys, line.split("\t"))) for line in out.stdout.splitlines()
             if line.count("\t") == len(keys) - 1]
    if out.returncode != 0 or len(steps) < 2:
        sys.exit(f"✗ la lista de pasos ({HOST_CLI}) no se pudo leer\n"
                 "  → descargue de nuevo la suite: sudo aps-conecta descargar")
    return steps
SEAL_BYTES = 12  # 24 hex chars — env-init's FIXTURE_USER_PASSWORD size, the human-typed precedent
# The seal is a read-modify-write over one shared file, and the server is threaded: two
# concurrent /api/usuarios posts (a double-submit is one double-click away) would share the
# one tmp inode and interleave. One process-wide lock — the D13 single-operator posture makes
# it unobservable, and the R1 verifier's double-submit arm is exactly the ceiling it documents.
SEAL_LOCK = threading.Lock()


# One execution at a time (the executor's own stampede guard — SEAL_LOCK's shape): two concurrent
# /api/generar ejecutar posts would run two seeds against the one instance. The 409 names it.
EXEC_LOCK = threading.Lock()
# The browser's «Ejecutar» (a14): the run happens on a worker and the page polls this every second —
# no request is held open for minutes. One run at a time (EXEC_LOCK inside api_generar; EJEC_GUARD
# makes check-and-start one step); read without a lock — plain values, a snapshot.
EJECUCION = {"estado": "sin_ejecutar", "hechos": [], "veredicto": None}
EJEC_GUARD = threading.Lock()
# Every executor subprocess is bounded (B-015: a phase that hangs must not hang a thread forever).
# The seed's bound is the harness's pull budget (30 min); the roster driver rides the same number —
# a big clinic's N×0.8 s execs fit with margin; the gate only reads. The self-test patches this
# dict for its timeout arm instead of a test-only env knob.
TIMEOUTS = {"seed": 1800, "roster": 1800, "gate": 300, "suite": 900}
# The silent install's console (R42): one Spanish line per finished phase, keyed by the phase
# file's stem — a self-test arm pins one title per file in provisioning/phases.
PHASE_TITLES = {
    "05-security": "Seguridad de sesión", "06-jobs": "Tareas programadas",
    "07-certs": "Certificados del servidor", "10-locale": "Idioma y región (es-CL)",
    "12-apps": "Aplicaciones de la suite", "14-office": "Oficina en línea",
    "15-branding": "Imagen de APS Conecta", "16-app-policy": "Aplicaciones por perfil",
    "20-groups": "Grupos: roles, categorías y equipos", "30-folders": "Carpetas compartidas",
    "40-acl": "Permisos de las carpetas", "41-intravox": "Portada del establecimiento",
    "50-users": "Cuentas de cargo", "60-fixtures": "Contenido de ejemplo"}
# What the clinic gets, as the review step lists it (R37): one row per component staff see — its
# app, its name, what it gives. Plumbing is not listed; a self-test pins every app under
# provisioning/apps to one side or the other (ponytail: a JSON file once the host TUI needs it too).
COMPONENTES = (
    ("intravox", "Inicio", "Portada del establecimiento: noticias, avisos y accesos del equipo."),
    ("groupfolders", "Documentos", "Carpetas compartidas por sector y programa, con permisos por grupo."),
    ("eurooffice", "Oficina", "Edición en línea de documentos, planillas y presentaciones."),
    ("calendar", "Calendario", "Agendas personales y compartidas del equipo."),
    ("contacts", "Contactos", "Directorio del personal y contactos externos."),
    ("epidemiologia", "Epidemiología", "Alertas del MINSAL y del ISP, informes IRAG y tablero nacional."),
    ("estadistica", "Estadística",
     "Cifras REM frente al promedio nacional y de pares; avance de las Metas Sanitarias."),
    ("farmacia", "Farmacia", "Arsenal farmacológico del establecimiento con información de seguridad clínica."),
    ("territorio", "Territorio", "Mapa territorial: unidades vecinales y establecimientos."),
    ("spreed", "Talk", "Chat y videollamadas internas."),
)
PLUMBING_APPS = ("desktop_workspace", "notify_push", "side_menu")
# The browser's progress list (a14): the phases by their console titles, then the people, then the gate.
PASO_PLANILLA, PASO_GATE = "Cuentas del personal", "Comprobación final"
PASOS_EJECUCION = [PHASE_TITLES[k] for k in sorted(PHASE_TITLES)] + [PASO_PLANILLA, PASO_GATE]
# Step 7, «Iniciar la suite» (L3 S5). The five APS apps phase 12 ships (OWN_APPS — an arm pins the set),
# named as the catalogue names them; each version is read from its VENDOR file.
APPS_APS = ("intravox", "epidemiologia", "estadistica", "farmacia", "territorio")
# The suite's containers, named for the people who run it: the host's AIO_SET plus Nextcloud's own (an
# arm pins the set). Talk's two join when the wizard was given Talk — they never block «Siguiente».
CONTENEDORES_SUITE = (("nextcloud-aio-apache", "Servidor web"), ("nextcloud-aio-nextcloud", "Núcleo de la suite"),
                      ("nextcloud-aio-database", "Base de datos"), ("nextcloud-aio-redis", "Caché"),
                      ("nextcloud-aio-notify-push", "Notificaciones al instante"),
                      ("nextcloud-aio-eurooffice", "Oficina"))
CONTENEDORES_TALK = (("nextcloud-aio-talk", "Talk"), ("nextcloud-aio-talk-recording", "Grabación de Talk"))
# Talk sized to the server (R26). ponytail: Talk ~1 GiB is AIO's own figure; the recording's 4 free cores
# are the approved design's example, above AIO's ~2 vCPU — the conservative side until measured. Clean
# boot prints the suite's memory; the L7 rehearsal box (12 GiB, 4 cores) confirms or moves them.
SUITE_GIB, TALK_GIB, GRABACION_GIB, RESERVA_GIB = 6, 1, 1, 1
SUITE_NUCLEOS, GRABACION_NUCLEOS = 2, 4
PUERTO_TALK = 3478
RESPALDO_DIR = "/srv/aps-conecta/respaldos"   # the daily backup's folder on this server (INSTALLER §11)
DOMINIO = re.compile(r"[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?")   # the host's DOMAIN_RE
# The wizard's preparation, followed by the page (a12): the host's ✓ lines, as the page names them
PASOS_SUITE = ((("✓ Suite iniciada", "✓ Suite reanudada", "✓ La suite ya está iniciada"), "Asistente en marcha"),
               (("✓ Contraseña del asistente",), "Contraseña del asistente"),
               (("✓ Ingreso al asistente",), "Ingreso al asistente"),
               (("✓ Dominio:",), "Dominio"), (("✓ Zona horaria:",), "Zona horaria"),
               (("✓ Opciones:",), "Opciones"), (("✓ Respaldo diario",), "Respaldo diario"))
SUITE = {"estado": "sin_preparar", "hechos": [], "motivo": ""}
SUITE_GUARD = threading.Lock()
SUITE_CMD = ["bash", HOST_CLI, "asistente-aio", "--preparar"]   # the host's own drive; the self-test fakes it


STUB_DOCKER = r'''#!/usr/bin/env python3
"""The stub docker — the test.sh #143 stub pattern as a PATH binary, for the executor's de-risk
and self-test. Answers the seed/phases/driver/gate world against a state file, so a RE-RUN sees
what the first run created (users, groups, memberships, folders): the executor's idempotent
re-run arms are load-bearing (the weekly timer rides them) and a stateless stub would fake them
red. Everything it does is logged to FAKE_DOCKER_LOG (one line per argv) — the OC_PASS delivery
and the AIO-arm arms grep THAT. Control knobs arrive via FAKE_DOCKER_CONTROL (python-assignable
lines), so the log stays a pure record: FAIL_ON (a word that makes any matching call exit 1 —
the fail-stop arm), GATE_EXTRA (a uid the user:list answer plants — the gate-red arm), PS_MODE
('empty' — the compose-arm), PS_LISTA (the containers docker ps -a lists — the step-7
arms), SLOW (sleep before answering — the timeout arm).
"""
import json
import os
import sys
import time

args = sys.argv[1:]
joined = " ".join(args)

log = os.environ.get("FAKE_DOCKER_LOG")
if log:
    with open(log, "a", encoding="utf-8") as fh:
        fh.write(joined + "\n")

control = {}
try:
    with open(os.environ.get("FAKE_DOCKER_CONTROL", ""), encoding="utf-8") as fh:
        for line in fh:
            if "=" in line:
                k, v = line.split("=", 1)
                control[k.strip()] = v.strip()
except OSError:
    pass

if control.get("SLOW"):
    time.sleep(30)
if control.get("FAIL_ON") and control.get("FAIL_ON") in args:
    sys.exit(1)


def state():
    try:
        with open(os.environ["FAKE_DOCKER_STATE"], encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError, ValueError):
        return []


def save(rows):
    with open(os.environ["FAKE_DOCKER_STATE"], "w", encoding="utf-8") as fh:
        json.dump(rows, fh, ensure_ascii=False)


def find(word):
    return args[args.index(word) + 1] if word in args else None


rows = state()
if args and args[0] == "ps":
    if control.get("PS_MODE") == "empty":
        sys.exit(0)
    # two --format shapes ride the same verb: the detection idiom asks for bare names
    # (install.sh/smoke/14-office: grep -qx needs whole lines), the estado leg for name+status
    if any("{{.Status}}" in a for a in args):  # the tab template arrives as ONE argv
        if control.get("PS_LISTA"):   # the step-7 arms' containers, name:status;name:status
            for item in control["PS_LISTA"].split(";"):
                print(item.replace(":", "\t", 1))
        else:
            print("nextcloud-aio-nextcloud\tUp 2 minutes")
            print("nextcloud-aio-database\tUp 2 minutes (healthy)")
    else:
        print("nextcloud-aio-nextcloud")
    sys.exit(0)
elif "printenv" in args and "TALK_ENABLED" in args:   # the suite's Talk switch, as AIO sets it: yes or empty
    print(control.get("TALK_ENABLED", ""))
elif "status" in args and "--output=json" in args:
    print('{"installed":true,"version":"34.0.4","maintenance":false}')
elif "user:info" in args:
    uid = find("user:info")
    sys.exit(0 if any(r == ["user", uid] for r in rows) else 1)
elif "user:add" in args:
    rows.append(["user", args[-1]])
    save(rows)
elif "user:list" in args:
    users = sorted(r[1] for r in rows if r[0] == "user")
    if control.get("GATE_EXTRA"):
        users.append(control["GATE_EXTRA"])
    print(json.dumps({u: {"displayname": u} for u in users}))
elif "group:adduser" in args:
    i = args.index("group:adduser")
    rows.append(["member", args[i + 1], args[i + 2]])
    save(rows)
elif "group:add" in args:
    rows.append(["group", args[-1]])
    save(rows)
elif "group:list" in args and "--output=json" in args:
    groups = sorted(r[1] for r in rows if r[0] == "group")
    members = {}
    for r in rows:
        if r[0] == "member":
            members.setdefault(r[1], []).append(r[2])
    print(json.dumps({g: members.get(g, []) for g in groups}))
elif "groupfolders:create" in args:
    # mounts carry spaces ("Sectores/Sector Estrella") — everything after the verb is the mount
    i = args.index("groupfolders:create")
    mount = " ".join(args[i + 1:])
    nxt = 1 + max((int(r[2]) for r in rows if r[0] == "folder"), default=0)
    rows.append(["folder", mount, str(nxt)])
    save(rows)
    print(nxt)
elif "groupfolders:list" in args:
    # a LIST of folder objects — real occ's shape (measured live: [{"id":1,...}]). This used
    # to print a dict keyed by fid, which only survived because gf_load/divergence accept both
    # shapes; phase 41's lookup iterates rows and .get()s the mount on each, so against the
    # dict it AttributeError'd into 2>/dev/null and saw no folders at all.
    print(json.dumps([{"id": int(r[2]), "mountPoint": r[1], "groups_list": {}}
                      for r in rows if r[0] == "folder"]))
elif "app:enable" in args:
    # B-028: enabling an app writes the appconfig 'enabled' row real Nextcloud writes, and
    # phase 41's enable-guard reads exactly that back (config:app:get intravox enabled -> yes).
    # The old fall-through no-op'd without state, so the guard FATAL'd only in this sandbox
    # while the real stack stayed green. Upsert, not append: idempotent re-runs re-enable.
    app = find("app:enable")
    if not any(r == ["appconfig", app, "enabled", "yes"] for r in rows):
        rows.append(["appconfig", app, "enabled", "yes"])
        save(rows)
elif "intravox:setup" in args:
    # B-028: SetupService creates the groupfolder named by the `groupfolder_name` appconfig row
    # (IntraVox MountName, default IntraVox) — phase 41 sets that row right before and looks
    # the mount up by the same name after (ADR-0020). The config:app:set arm appends, so the
    # LAST row is the live value, as in Nextcloud. The folder row and the three engine groups
    # are modelled — the group map (lib.sh intravox_group_map) reads their members back, so a
    # stub without them re-added every member on every seed; the mount grants stay invisible to
    # every parser here, and divergence declares the mount itself (declared_folders,
    # divergence.sh). Query-first, ensure_groupfolder's discipline: a re-run must find them,
    # never re-create them.
    mount = next((r[3] for r in reversed(rows) if r[:3] == ["appconfig", "intravox", "groupfolder_name"] and r[3]), "IntraVox")
    if not any(r[0] == "folder" and r[1] == mount for r in rows):
        nxt = 1 + max((int(r[2]) for r in rows if r[0] == "folder"), default=0)
        rows.append(["folder", mount, str(nxt)])
    for g in ("IntraVox Admins", "IntraVox Editors", "IntraVox Users"):
        if ["group", g] not in rows:
            rows.append(["group", g])
    save(rows)
elif "config:system:get" in args and "datadirectory" in args:
    # implement-time arm (FINDINGS P15): the fence was authored against the pre-port tree whose
    # content helpers never asked for it; the ported datadir_load (lib.sh:142) fails CLOSED on an
    # empty answer, so the post-port seed needs one. "data" is a fixture-relative stand-in — the
    # value only ever flows into nc_exec argv, which this stub no-ops.
    print("data")
elif "config:app:set" in args:
    # implement-time arm (FINDINGS P16): the seed WRITES app-config keys (phase 16's comuna pair
    # among them) and the gate READS them back — a write-noop/read-empty stub would red every
    # gate on exactly the keys the phases converge. Stateful, like the user/group arms.
    i = args.index("config:app:set")
    val = args[i + 3]
    if val.startswith("--value="):
        val = val[len("--value="):]
    rows.append(["appconfig", args[i + 1], args[i + 2], val])
    save(rows)
elif "config:app:get" in args:
    i = args.index("config:app:get")
    for r in rows:
        if r[0] == "appconfig" and r[1] == args[i + 1] and r[2] == args[i + 2]:
            print(r[3])
            break
elif "config:list" in args:
    print("{}")
elif "inspect" in args:
    print("{}")
sys.exit(0)'''


def team_lines(word, gid_prefix, names):
    """ask()'s triple construction with input() removed — the UI supplies the names, this builds
    what the register cannot know. Replicated line-for-line from deis.py ask() (the fold, the word
    strip, the gid join, the display form) because the triples flow into site.sh verbatim.
    Variants converge — "Sector Estrella" and "SECTOR estrella" land on the same gid, by ask()'s
    own design — so duplicates collapse to their first occurrence; an empty name is ask()'s
    terminator and is dropped."""
    out = {}
    for name in names:
        if not isinstance(name, str):
            raise ValueError("cada sector o programa debe ser texto")
        name = name.strip()
        if not name:
            continue
        if "|" in name or any(ord(c) < 32 for c in name):   # the site file's field separator, a line break
            raise ValueError(f"«{name}» no puede llevar «|» ni saltos de línea")
        bare = name[len(word):].strip() if deis.fold(name).startswith(word) else name
        if not bare:  # the word alone ("sector") names nothing
            continue
        gid = gid_prefix + "-".join(deis.fold(bare).split())
        out.setdefault(gid, (gid, f"{word.capitalize()} {bare}", bare))
    return list(out.values())


def find_row(codigo):
    return next((r for r in ROWS if r["codigo"] == codigo), None)


def site_path(codigo):
    # The same join write_site performs — computed here so /api/sitio can look BEFORE writing.
    # Both read deis.HERE at call time, so a redirected HERE (self-test) checks and writes the
    # same throwaway tree.
    return os.path.normpath(os.path.join(deis.HERE, "..", "sites", codigo, "site.sh"))


def _site_rel(codigo):
    # The path exactly as write_site reports it (its own print is a relpath to the repo root).
    return os.path.relpath(site_path(codigo), os.path.join(deis.HERE, ".."))


def site_deis(path):
    """The establishment a written site.sh belongs to — its SITE_DEIS line, or None when unreadable
    or hand-edited past recognition. The identity block writes it unquoted (deis.py block()), so an
    anchored read is the whole parser."""
    try:
        with open(path, encoding="utf-8") as fh:
            m = re.search(r"^SITE_DEIS=([0-9]+)$", fh.read(), re.MULTILINE)
    except OSError:
        return None
    return m.group(1) if m else None


def load_register():
    """deis.py load(), SystemExit made local: its FATAL strings are fix-hints, and a wizard that
    cannot name an establishment should never open a socket — fail fast, in Spanish, hint intact."""
    global SNAPSHOT, ROWS
    try:
        SNAPSHOT, ROWS = deis.load()
    except SystemExit as e:
        sys.exit(f"No se puede cargar el registro DEIS: {e}\n"
                 "El paquete de aprovisionamiento debe incluir sites/establecimientos-deis-*.csv.")


def written_sites():
    """The centres with a written site file, by directory (sites/<codigo>/site.sh): one install,
    one establishment (D13), so any entry is the install's centre, fixed."""
    base = os.path.join(deis.HERE, "..", "sites")
    try:
        return sorted(d for d in os.listdir(base) if os.path.isfile(os.path.join(base, d, "site.sh")))
    except OSError:
        return []


def one_establishment(codigo):
    """None when `codigo` may be this install's centre; else the 409 naming the one it serves — the
    one refusal the silent install (site_import), «Confirmar centro» and step 8 share. No path in it
    (a16): the operator reads a centre, not a file."""
    others = [d for d in written_sites() if d != codigo]
    if not others:
        return None
    row = find_row(others[0])
    quien = f"{row['nombre']} (DEIS {others[0]})" if row else f"otro establecimiento (DEIS {others[0]})"
    return 409, {"error": f"este servidor ya sirve a {quien}: una instalación sirve a un solo "
                          "establecimiento"}


def api_centros():
    """GET /api/centros — the whole register in one compact payload for the Centro screen's
    client-side cascade and search (R36: every centre, every type): each name once, and each centre
    as [codigo, tipo, nombre, dirección, comuna, servicio, dependencia] with indexes into them.
    ~250 KB once per visit on the LAN (ponytail: no gzip, no paging — compress if a box feels it)."""
    def orden(lista, codigos):
        return lambda x: (lista.index(x) if x in lista else len(lista), codigos(x))
    region = {r["region_codigo"]: r["region"] for r in ROWS}
    comuna = {r["comuna_codigo"]: (r["comuna"], r["region_codigo"]) for r in ROWS}
    siglas = [s for s, _ in TIPOS]
    regiones = sorted(region, key=orden(list(REGION_ORDER), str))
    tipos = sorted({r["tipo"] for r in ROWS}, key=orden(siglas, str))
    servicios = sorted({r["servicio_salud"] for r in ROWS}, key=deis.fold)
    dependencias = sorted({r["dependencia"] for r in ROWS}, key=deis.fold)
    ri = {c: i for i, c in enumerate(regiones)}
    comunas = sorted(comuna, key=lambda c: (ri[comuna[c][1]], deis.fold(comuna[c][0])))
    ti = {t: i for i, t in enumerate(tipos)}
    ci = {c: i for i, c in enumerate(comunas)}
    si = {s: i for i, s in enumerate(servicios)}
    di = {d: i for i, d in enumerate(dependencias)}
    centros = sorted(([r["codigo"], ti[r["tipo"]], r["nombre"], r["direccion"],
                       ci[r["comuna_codigo"]], si[r["servicio_salud"]], di[r["dependencia"]]]
                      for r in ROWS), key=lambda x: (x[1], deis.fold(x[2])))
    largo = dict(TIPOS)
    return 200, {"registro": SNAPSHOT, "regiones": [region[c] for c in regiones],
                 "comunas": [[comuna[c][0], ri[comuna[c][1]]] for c in comunas],
                 "tipos": [[t, largo.get(t, t)] for t in tipos],
                 "servicios": servicios, "dependencias": dependencias, "centros": centros}


def centro_actual():
    """GET /api/centro — this install's centre: the written site's («fijo»; its directory IS the
    code, as for the host CLI's site_codigo and every other door), else the one confirmed on the
    Centro screen; none yet is {"codigo": null} — a state, not an error (a 404 would land in the
    browser console as one). A written code the register lacks (a silent install's own site.sh) is
    still this install's centre, named plainly. Every later screen reads it here, so no code rides a
    URL (L3 S2); «Listo» names the centre from it too."""
    sitios = written_sites()
    codigo = sitios[0] if sitios else CENTRO
    if codigo is None:
        return 200, {"codigo": None}
    row = find_row(codigo)
    nombre = row["nombre"] if row else f"el establecimiento DEIS {codigo}"
    return 200, {"codigo": codigo, "nombre": nombre, "fijo": bool(sitios)}


def api_centro(payload):
    """POST /api/centro {"codigo"} — «Confirmar centro»: held until step 8 writes the site file. A
    correction is free until then; afterwards only that centre answers 200 (D13)."""
    global CENTRO
    codigo = payload.get("codigo")
    if not isinstance(codigo, str) or not CODIGO.fullmatch(codigo):
        return 400, {"error": "el código DEIS debe ser de 4 a 6 dígitos"}
    row = find_row(codigo)
    if row is None:
        return 404, {"error": f"ningún establecimiento con código DEIS {codigo} en el registro {SNAPSHOT}"}
    refused = one_establishment(codigo)
    if refused:
        return refused
    CENTRO = codigo
    return 200, {"ok": True, "codigo": codigo, "nombre": row["nombre"]}


def _site_exists_answer(codigo, path):
    """Converge, never overwrite — write_site's own contract, kept at the HTTP layer: the file is
    hand-edited from here on, so an existing file for the SAME codigo is a re-run and answers
    already=true (the executor and the weekly re-provision ride this arm); anything else refuses,
    naming what is there."""
    have = site_deis(path)
    if have == codigo:
        return 200, {"ok": True, "already": True, "site": _site_rel(codigo)}
    if have is None:
        return 409, {"error": f"sites/{codigo}/site.sh ya existe pero no se puede leer su código "
                              "DEIS — revíselo o elimínelo a mano"}
    return 409, {"error": f"sites/{codigo}/site.sh ya existe y pertenece al establecimiento "
                          f"DEIS {have} — revíselo o elimínelo a mano"}



def site_import(payload):
    """{"texto"} — the silent install's centre (`--paso sitio --archivo`): an operator's own site.sh,
    placed at sites/<SITE_DEIS>/site.sh and read exactly as the executor reads /api/sitio's output
    (fail closed). The same bytes already there are a re-run; a different file for the same centre,
    or another centre's site, is refused — one install, one establishment, never overwritten."""
    text = payload.get("texto")
    if not isinstance(text, str) or not text.strip():
        return 400, {"error": "el sitio está vacío"}
    m = re.search(r"(?m)^SITE_DEIS=([0-9]+)$", text)
    if not m or not CODIGO.fullmatch(m.group(1)):
        return 400, {"error": "el sitio no declara SITE_DEIS=<código DEIS de 4 a 6 dígitos, sin comillas>"}
    codigo = m.group(1)
    if not re.search(r"(?m)^SITE_ROSTER=", text):
        return 400, {"error": "el sitio no trae la línea SITE_ROSTER= (la que completa la planilla)"}
    if not re.search(r'(?m)^SITE_DOMINIO="?[^"\s]+"?$', text):
        return 400, {"error": 'el sitio no declara SITE_DOMINIO="<dominio del servidor>" — la suite se '
                              "configura con él"}
    with tempfile.TemporaryDirectory() as tmp:
        probe = os.path.join(tmp, "site.sh")
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write(text)
        try:
            _teams, roles = site_arrays(probe)
        except ValueError as e:
            rel = os.path.relpath(probe, os.path.join(deis.HERE, ".."))
            return 400, {"error": str(e).replace(rel, "el sitio")}
    wrong = [f"{gid} → {cat}" for gid, _display, cat in roles
             if cat not in ("cat-jefaturas", "cat-clinicos", "cat-tecnicos", "cat-administrativos")]
    if wrong:  # 20-groups refuses these too, but only at step 9, after the suite is up
        return 400, {"error": "el sitio nombra una categoría que no existe: " + ", ".join(wrong)
                              + " — use cat-jefaturas, cat-clinicos, cat-tecnicos o cat-administrativos"}
    refused = one_establishment(codigo)
    if refused:
        return refused
    dest = site_path(codigo)
    if os.path.exists(dest):
        with open(dest, encoding="utf-8") as fh:
            if fh.read() == text:
                return 200, {"ok": True, "already": True, "site": _site_rel(codigo), "codigo": codigo}
        return 409, {"error": f"{_site_rel(codigo)} ya existe y difiere del archivo entregado — "
                              "compárelos y deje uno (la instalación no pisa un sitio)"}
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        with open(dest + ".tmp", "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        os.replace(dest + ".tmp", dest)  # never half a site: a re-run would read it as «difiere»
    finally:
        if os.path.exists(dest + ".tmp"):
            os.unlink(dest + ".tmp")
    return 200, {"ok": True, "site": _site_rel(codigo), "codigo": codigo}


def api_sitio(payload):
    """POST /api/sitio {"codigo", "sectors", "programs", "vista"?, "reemplazar"?} — step 8's teams,
    into sites/<codigo>/site.sh via deis.py write_site: the establishment's whole truth in one
    standalone file, byte-identical to what `deis.py <codigo> --new <slug>` writes, with the slug
    being the codigo itself. One install, one establishment (D13): another centre's site file
    refuses 409 here as in the silent install. Saved again (R35, never a silent 200): the same teams
    are a re-run; different ones answer 409 naming what is new and what goes, unless «reemplazar» —
    then replace_teams rewrites the team blocks. «vista» derives the group ids and touches nothing:
    the screen shows them under each list before saving (a16)."""
    codigo = payload.get("codigo")
    if not isinstance(codigo, str) or not CODIGO.fullmatch(codigo):
        return 400, {"error": "el código DEIS debe ser de 4 a 6 dígitos"}
    row = find_row(codigo)
    if row is None:
        return 404, {"error": f"ningún establecimiento con código DEIS {codigo} "
                              f"en la instantánea {SNAPSHOT}"}
    sectors_in = payload.get("sectors", [])
    programs_in = payload.get("programs", [])
    if not isinstance(sectors_in, list) or not isinstance(programs_in, list):
        return 400, {"error": "sectores y programas deben ser listas de nombres"}
    try:
        sectors = team_lines("sector", "sector-", sectors_in)
        programs = team_lines("programa", "prog-", programs_in)
    except ValueError as e:
        return 400, {"error": f"sectores y programas: {e}"}
    equipos = [[gid, display] for gid, display, _ in programs + sectors]   # write_site's order
    if payload.get("vista") is True:
        return 200, {"ok": True, "equipos": equipos}

    # ponytail: the first write is check-then-write across threads — write_site refuses an existing
    # file and the SystemExit arm below settles the race; the rewrites take SITE_LOCK
    refused = one_establishment(codigo)   # D13 at step 8 too, not only in the silent install
    if refused:
        return refused

    path = site_path(codigo)
    if not os.path.exists(path):
        try:
            buf = io.StringIO()
            with redirect_stdout(buf):  # write_site's "wrote sites/…" line is the response, not noise
                deis.write_site(row, SNAPSHOT, codigo, sectors, programs, domain=dominio_actual())
            return 200, {"ok": True, "already": False, "site": _site_rel(codigo),
                         "written": buf.getvalue().strip(), "equipos": equipos}
        except SystemExit:  # the refusal raced our look (threaded server) — settle it the same way
            pass
    status, body = _site_exists_answer(codigo, path)
    if status != 200:
        return status, body
    try:
        guardados = [list(t) for t in site_arrays(path)[0]]
    except ValueError as e:
        return 409, {"error": str(e)}
    antes, ahora = {tuple(t) for t in guardados}, {tuple(t) for t in equipos}
    if antes == ahora:
        return 200, {**body, "equipos": guardados}
    if payload.get("reemplazar") is not True:
        return 409, {"error": "los equipos difieren de los guardados; no se cambió nada",
                     "nuevos": [d for g, d in equipos if (g, d) not in antes],
                     "quitados": [d for g, d in guardados if (g, d) not in ahora],
                     "equipos_guardados": guardados}
    try:
        replace_teams(path, row, codigo, sectors, programs)
    except ValueError as e:
        return 409, {"error": str(e)}
    return 200, {"ok": True, "already": False, "reemplazados": True, "site": _site_rel(codigo),
                 "equipos": equipos}


TEAM_BLOCKS = ("SITE_TEAMS", "SITE_FOLDERS", "SITE_ACL")
SITE_LOCK = threading.Lock()   # the site file's two read-modify-writes: «Reemplazar» and the roster line


def team_blocks(text):
    """The three team-derived arrays as write_site emits them, in TEAM_BLOCKS order (None if absent)."""
    out = []
    for name in TEAM_BLOCKS:
        m = re.search(rf"(?ms)^{name}=\(\n.*?^\)\n", text)
        out.append(m.group(0) if m else None)
    return out


def replace_teams(path, row, codigo, sectors, programs):
    """«Reemplazar» (R35): the three arrays the teams derive — SITE_TEAMS, SITE_FOLDERS, SITE_ACL —
    regenerated by write_site itself and spliced in; every other line (the domain, the roster line,
    the welcome tree, local roles) stays. Those three blocks must still be exactly what write_site
    made of the saved teams: a folder or grant added there by hand would be lost, so that case is
    refused instead. A planilla naming a team that goes stops counting as loaded and is checked
    again at «Revisar y ejecutar»."""
    with SITE_LOCK:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        teams, _roles = site_arrays(path)
        antes_sec = team_lines("sector", "sector-", [d for g, d in teams if g.startswith("sector-")])
        antes_prog = team_lines("programa", "prog-", [d for g, d in teams if g.startswith("prog-")])
        with tempfile.TemporaryDirectory() as tmp:
            def fresh(name, sec, prog):
                out = os.path.join(tmp, name)
                with redirect_stdout(io.StringIO()):
                    deis.write_site(row, SNAPSHOT, codigo, sec, prog, path=out)
                with open(out, encoding="utf-8") as fh:
                    return fh.read()
            esperado = fresh("antes.sh", antes_sec, antes_prog)
            nuevo = fresh("nuevo.sh", sectors, programs)
        actual = team_blocks(text)
        if None in actual or actual != team_blocks(esperado):
            raise ValueError("el sitio tiene equipos, carpetas o permisos agregados a mano — "
                             "reemplace los equipos a mano en el archivo del sitio")
        for viejo, otro in zip(actual, team_blocks(nuevo)):
            text = text.replace(viejo, otro, 1)
        write_site_text(path, text)


def write_site_text(path, text):
    """The site file replaced whole, never half-written: a tmp beside it, the operator's mode kept,
    then os.replace — both rewrites («Reemplazar», the SITE_ROSTER line) go through here."""
    tmp_path = path + ".tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        os.chmod(tmp_path, os.stat(path).st_mode & 0o7777)
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def role_names(path):
    """The shared cargos as [id, name] — phase 20's own display names, read off the same lines
    role_categories reads the categories from: the planilla's role-* column as «Grupos válidos» and
    the template show it."""
    with open(path, encoding="utf-8") as fh:
        roles = [list(m) for m in re.findall(r'^ *"(role-[a-z0-9-]+)\|([^|"]*)\|', fh.read(), re.M)]
    if len(roles) < 22:   # registry_groups' floor discipline: a shape change is refused, never a short list
        raise ValueError(f"solo {len(roles)} de los 22 cargos compartidos se pudieron leer: el paquete "
                         "de instalación cambió de forma — reinstálelo")
    return roles


def equipos_actuales():
    """GET /api/equipos — step 8's state, for the screen and after a reload: the saved teams (none
    before the first save), every cargo the planilla's role-* column accepts (phase 20's and the
    site's own), and whether «Revisar» would accept the loaded planilla (a replacement can make it
    stale: a team it names gone, a new sector's cargo unsealed)."""
    codigo = centro_actual()[1].get("codigo")
    if not codigo:
        return 200, {"codigo": None}
    path = site_path(codigo)
    guardados = os.path.exists(path)
    cargada = False
    try:
        cargos = role_names(PHASE20)
        teams, roles = site_arrays(path) if guardados else ([], [])
        if guardados:   # «Siguiente» only where «Revisar» accepts it (zero writes, zero execs)
            cargada = _api_generar({"codigo": codigo, "modo": "revision"})[0] == 200
    except OSError as e:
        return 500, {"error": f"no se pudo leer un archivo del centro ({why(e)})"}
    except ValueError as e:
        return 409, {"error": str(e)}
    return 200, {"codigo": codigo, "guardados": guardados, "equipos": [list(t) for t in teams],
                 "cargos": cargos + [[g, d] for g, d, _c in roles], "planilla_cargada": cargada}


def plantilla():
    """GET /api/plantilla — the planilla template for this centre (R38, a15): the header and two
    example people using the centre's own sector and program ids and two shared cargos, «sí» once,
    UTF-8 with a BOM so Excel opens the accents right (the upload strips it). Uploaded as is, it
    validates."""
    st, eq = equipos_actuales()
    if st != 200:
        return st, eq
    if not eq.get("guardados"):
        return 409, {"error": "primero guarde los equipos: la plantilla usa sus códigos"}
    sec = [g for g, _ in eq["equipos"] if g.startswith("sector-")]
    prog = [g for g, _ in eq["equipos"] if g.startswith("prog-")]
    cargos = [g for g, _ in eq["cargos"]]   # role_names refuses a short list, so never empty
    enf = "role-enfermeria" if "role-enfermeria" in cargos else cargos[0]
    med = "role-medico" if "role-medico" in cargos else cargos[-1]
    filas = [ROSTER_HEADER,
             ("ana.rojas", "Ana María", "Rojas Fuentes", "ana.rojas@example.cl",
              " ".join(sec[:1] + prog[:1] + [enf]), "sí"),
             ("pedro.munoz", "Pedro", "Muñoz Tapia", "pedro.munoz@example.cl",
              " ".join((sec[1:2] or sec[:1]) + [med]), "no")]
    return 200, {"csv": "\ufeff" + "".join(";".join(f) + "\n" for f in filas),
                 "nombre": f"planilla-{eq['codigo']}.csv"}


def registry_groups(path):
    """The shared group ids, READ out of phase 20 — "THIS FILE IS THE GROUP REGISTRY" is that
    file's own first rule — using the same two shapes divergence.sh's sed expressions read (the
    quoted `role-…|…` / `cat-…|…` array entries, the literal `ensure_group <id>` lines), so both
    readers break on the same shape change. The floor guard is divergence's own: fewer than 20
    parsed ids means the shape moved and every roster group would read as unknown — refuse the
    whole validation instead of crying wolf on every line."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        raise ValueError("no se pueden leer los grupos compartidos: el paquete de instalación está "
                         "incompleto — reinstálelo")
    ids = {m.group(1) for m in re.finditer(r'^ *"((?:role|cat)-[a-z0-9-]*)\|', text, re.M)}
    ids |= {m.group(1) for m in re.finditer(r"^ensure_group ([a-z0-9-]*)", text, re.M)}
    if len(ids) < 20:
        raise ValueError(f"solo {len(ids)} de los 27 grupos compartidos se pudieron leer: el paquete "
                         "de instalación cambió de forma — reinstálelo antes de validar la planilla")
    return ids



def role_categories(path, site_roles):
    """role id -> the cat-* every holder of the role also joins (a8): the third field of phase
    20's 22 shared roles plus the site's own SITE_ROLES. Nextcloud groups do not nest, so the
    roster frame adds the category itself. Only the four categories parse, so fewer than 22 means
    the registry's shape moved or a category is misspelled — refused, registry_groups' floor
    discipline. A site role never overrides a shared one (20-groups refuses a bad site category)."""
    with open(path, encoding="utf-8") as fh:
        cats = dict(re.findall(r'^ *"(role-[a-z0-9-]+)\|[^|"]*\|'
                               r'(cat-(?:jefaturas|clinicos|tecnicos|administrativos))"', fh.read(), re.M))
    if len(cats) < 22:
        raise ValueError(f"solo {len(cats)} de los 22 roles compartidos declaran su categoría en "
                         f"{path} — cambió de forma; corríjalo antes de ejecutar")
    for gid, _display, category in site_roles:
        cats.setdefault(gid, category)
    return cats


def site_arrays(site):
    """SITE_TEAMS and SITE_ROLES out of the site.sh /api/sitio wrote — line-based on the shape
    write_site emits: `NAME=(` alone on a line, then one `id|display[|category]` entry per line
    (shlex-quoted whole, so one token per line), closed by a lone `)`; `SITE_ROLES=()` inline is
    write_site's empty default. The file is the operator's from /api/sitio onward (hand-edited,
    by design), so anything this cannot read EXACTLY is refused, never guessed at — fail closed,
    datadir_load's discipline: a roster validated against a mis-read site would seed against a
    different truth, which is a divergence event, not a cosmetic one."""
    root = os.path.join(deis.HERE, "..")
    rel = os.path.relpath(site, root)
    try:
        with open(site, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        raise ValueError(f"no se puede leer {rel}")
    teams, roles = [], []
    box = None  # (list, arity, name, lineno) while inside a SITE_* array
    for no, ln in zip(range(1, len(lines) + 1), lines):
        s = ln.strip()
        if box is None:
            if s == "SITE_TEAMS=(":
                box = (teams, 2, "SITE_TEAMS", no)
            elif s == "SITE_ROLES=(":
                box = (roles, 3, "SITE_ROLES", no)
            # `SITE_TEAMS=()` / `SITE_ROLES=()` — write_site's inline empty — needs no parse
            continue
        if s == ")":
            box = None
            continue
        if not s:
            continue  # write_site's own empty-list shape: `SITE_TEAMS=(\n  \n)` carries a blank line
        try:
            tok = shlex.split(s)
        except ValueError:
            tok = []
        if len(tok) != 1 or tok[0].count("|") + 1 != box[1]:
            raise ValueError(f"{rel}: la línea {no} dentro de {box[2]} no se puede leer — se "
                             "espera una entrada 'id|nombre' por línea (los roles del sitio "
                             "llevan 'id|nombre|categoría')")
        box[0].append(tuple(tok[0].split("|")))
    if box is not None:
        raise ValueError(f"{rel}: {box[2]} se abre en la línea {box[3]} y no se cierra")
    return teams, roles


def standing_uids(teams, roles):
    """The accounts phase 50 will create for this site (org L5-11: DELEGATED — the derivation
    lives once, in provisioning/standings.sh, sourced and called through bash; this python copy
    used to re-implement it and could only drift). A roster uid colliding with one of them is
    one account existing twice — once as a POSITION, once as a person — which the divergence
    gate would flag forever; refused here, at the earliest moment. The `admin` account is added
    on top: the wizard's own, not a phase-50 position (divergence declares it separately)."""
    import pathlib, shlex, subprocess
    standings = pathlib.Path(__file__).resolve().parent.parent / "provisioning" / "standings.sh"
    _ = standings  # sourced via cwd below; kept for the path check in --self-test parity
    import shlex
    teams_lit = " ".join(shlex.quote(f"{gid}|{display}") for gid, display in teams)
    roles_lit = " ".join(shlex.quote(f"{gid}|{display}|{category}") for gid, display, category in roles)
    snippet = ["bash", "-c",
               f'declare -a SITE_TEAMS=({teams_lit}); declare -a SITE_ROLES=({roles_lit}); '
               'source provisioning/standings.sh; standing_uids']
    cwd = pathlib.Path(__file__).resolve().parent.parent
    try:
        out = subprocess.run(snippet, cwd=cwd, capture_output=True, text=True, check=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        raise ValueError("no se pudieron derivar los cargos del sitio — revise que bash y el paquete "
                         "de aprovisionamiento estén completos") from e
    reserved = {
        "admin": "la cuenta administradora de la suite",
    }
    for uid in out.stdout.split():
        reserved.setdefault(uid, "un cargo que la instalación crea sola")
    return reserved


def roster_parse(text, reserved, universe):
    """Validate the roster CSV text. Returns (rows, errors): rows = validated
    (uid, nombre, apellidos, correo, grupos, primer_admin) tuples in file order; errors =
    (linea, mensaje) pairs for the UI's line-numbered screen (S6). Every line's problem is
    reported at once — the operator fixes the whole planilla in one pass, not one upload per
    mistake. `primer_admin` accepts si/sí (accent-blind, like the register search — es-CL spells
    it with the accent and the spreadsheet will carry it). Blank lines — an Excel artifact, not
    data — are skipped; a cell with an embedded newline (Alt+Enter) is REFUSED, because a row
    that spans lines is a row whose line numbers stop meaning anything to the person reading
    the error."""
    errors, rows, seen, si_lines = [], [], {}, []
    reader = csv.reader(io.StringIO(text, newline=""), delimiter=";")
    try:
        head = next(reader, None)
        while head is not None and (not head or (len(head) == 1 and not head[0].strip())):
            head = next(reader, None)  # leading blank lines — same artifact, before the header
        if head is None or tuple(c.strip() for c in head) != ROSTER_HEADER:
            return [], [(1, "la cabecera debe ser " + ";".join(ROSTER_HEADER))]
        prev = reader.line_num
        for row in reader:
            start, end = prev + 1, reader.line_num
            prev = end
            if end != start:
                errors.append((start, "la fila ocupa varias líneas — hay saltos de línea dentro "
                              "de una celda (Alt+Enter en Excel); quítelos"))
                continue
            if not row or (len(row) == 1 and not row[0].strip()):
                continue  # a blank line mid-file — same artifact
            if len(row) != len(ROSTER_HEADER):
                errors.append((start, f"la fila debe tener {len(ROSTER_HEADER)} campos "
                              f"separados por «;», tiene {len(row)}"))
                continue
            uid, nombre, apellidos, correo, grupos, primer = (c.strip() for c in row)
            ok = True
            if not UID_RE.fullmatch(uid):
                errors.append((start, f"el usuario «{uid}» no es válido: minúsculas, con "
                              "letras, números, punto, guion o guion bajo"))
                ok = False
            elif uid in seen:
                errors.append((start, f"el usuario «{uid}» está repetido — ya aparece en la "
                              f"línea {seen[uid]}"))
                ok = False
            elif uid in reserved:
                errors.append((start, f"el usuario «{uid}» es {reserved[uid]}: quítelo de la planilla"))
                ok = False
            else:
                seen[uid] = start
            if not nombre or not apellidos:
                errors.append((start, "el nombre y los apellidos no pueden estar vacíos"))
                ok = False
            if correo and not EMAIL_RE.fullmatch(correo):
                errors.append((start, f"el correo «{correo}» no es válido"))
                ok = False
            gids = grupos.split()
            if not gids:
                errors.append((start, "indique al menos un sector, programa o cargo"))
                ok = False
            for g in sorted(set(gids)):
                if g == "admin":
                    errors.append((start, "el grupo «admin» se asigna con la columna "
                                  "primer_admin, no en grupos"))
                    ok = False
                elif g not in universe:
                    errors.append((start, f"el grupo «{g}» {UNKNOWN_GROUP} (vea "
                                  "«Grupos válidos»)"))
                    ok = False
            p = deis.fold(primer)
            if p not in ("si", "no"):
                errors.append((start, f"primer_admin debe ser «sí» o «no»; la fila dice "
                              f"«{primer}»"))
                ok = False
            elif p == "si":
                si_lines.append(start)
            if ok:
                rows.append((uid, nombre, apellidos, correo, tuple(sorted(set(gids))), p == "si"))
    except csv.Error:
        return [], [(1, "la planilla no se puede leer como CSV: revise las comillas y que el "
                        "separador sea «;»")]
    if rows and len(si_lines) != 1:
        errors.append((0, "ninguna fila tiene primer_admin = sí: marque exactamente una (la persona "
                          "que administrará la suite)" if not si_lines else
                       f"{len(si_lines)} filas tienen primer_admin = sí "
                       f"({', '.join(f'línea {n}' for n in si_lines)}): debe ser una"))
    elif not rows and not errors:
        errors.append((2, "la planilla no trae usuarios — agregue filas bajo la cabecera"))
    return rows, errors


def roster_refusal(errors, teams, shared, roles):
    """The planilla's 400, the same at the upload and at «Revisar»: every line error, plus the valid
    groups when one is unknown (R38) — the list, not a guess."""
    body = {"ok": False, "errores": [{"linea": n, "error": m} for n, m in errors]}
    if any(UNKNOWN_GROUP in m for _n, m in errors):
        body["grupos_validos"] = ([g for g, _ in teams] + sorted(g for g in shared if g.startswith("role-"))
                                  + [g for g, _, _ in roles])
    return 400, body


def sealed_map(path):
    """The sealed sheet as a uid -> (password, display, primer) map — the read half of
    seal_credentials, factored out because the executor reads the same sheet to feed the roster
    driver (a uid with no sealed row must refuse BEFORE any exec, never reach ensure_user with a
    blank password). Refuses exactly like seal_credentials: a file that does not read as this
    program's own output raises (env-init's rule — a file we do not own is never interpreted)."""
    sealed = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                for row in csv.reader(fh, delimiter=";"):
                    if not row or row[0].startswith("#") or row[0] == "usuario":
                        continue  # our own header/comment lines
                    if (len(row) != 4 or not UID_RE.fullmatch(row[0])
                            or not re.fullmatch("[0-9a-f]{24}", row[2])
                            or row[3] not in ("si", "no")):
                        raise ValueError(path)
                    sealed[row[0]] = (row[2], row[1], row[3])
        except (OSError, csv.Error):
            raise ValueError(path)
    return sealed


def seal_credentials(codigo, rows, path):
    """Converge the sealed credentials sheet (FRD S5): one row per roster uid, password generated
    ONCE. Cumulative by design — a sealed uid keeps its password FOREVER (a re-run must never
    regenerate what an account may already log in with: ensure_user ignores existing accounts,
    so a regenerated row would be a sheet that lies), and a uid that leaves the roster and
    returns finds its original row intact. An existing file that does not read EXACTLY like
    this program's own output is refused (env-init's rule — a file we do not own is never
    overwritten); the operator corrects or moves it by hand. 0600 before content, written to a
    temp file, fsync'd, then renamed into place: the sheet is the only copy of anyone's first
    password, so there is never a window where it is empty or half-written. The whole
    read-modify-write runs under SEAL_LOCK at the call site — the threaded server would
    otherwise let two double-submitted posts interleave on the one tmp inode."""
    sealed = sealed_map(path)
    out, fresh = {}, 0
    for uid, nombre, apellidos, _correo, _gids, primer in rows:
        if uid in sealed:
            pw = sealed[uid][0]
        else:
            pw = secrets.token_hex(SEAL_BYTES)
            fresh += 1
        out[uid] = (pw, f"{nombre} {apellidos}", "si" if primer else "no")
    for uid, kept in sealed.items():  # uids that left the roster keep their record
        if uid not in out:
            out[uid] = kept
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"# APS Conecta — contraseñas de primer ingreso. Establecimiento DEIS {codigo}.\n")
        # B-034: kept, never deleted — the executor needs a sealed row for every account it creates
        fh.write("# Entregue a cada persona su fila. Conserve este archivo: la re-provisión "
                 "semanal lo lee.\n")
        fh.write("usuario;nombre;contraseña;primer_admin\n")
        w = csv.writer(fh, delimiter=";", lineterminator="\n")
        for uid, (pw, display, primer) in out.items():
            w.writerow([uid, display, pw, primer])
        fh.flush()
        os.fsync(fd)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return fresh, len(out)


def api_usuarios(payload):
    """POST /api/usuarios {"codigo", "csv"} — validate the clinic's roster against what the site
    and the shared registry declare, and on green converge the three things the seed reads: the
    canonical roster at SITE_ROSTER's path, the SITE_ROSTER line itself (the #106 hook write_site
    emits empty), and the sealed credentials sheet. Line-numbered errors for the UI screen (S6);
    every password a row will ever need is generated HERE, once — the executor (slice 16) only
    ever reads the sealed sheet, so a re-run cannot regenerate what an account may already log
    in with."""
    codigo = payload.get("codigo")
    if not isinstance(codigo, str) or not CODIGO.fullmatch(codigo):
        return 400, {"error": "el código DEIS debe ser de 4 a 6 dígitos"}
    site = site_path(codigo)
    if not os.path.exists(site):
        return 404, {"error": "primero guarde los equipos (sectores y programas) de este centro"}
    csv_text = payload.get("csv")
    if not isinstance(csv_text, str) or not csv_text.strip():
        return 400, {"error": "falta la planilla: envíe el texto CSV en el campo «csv»"}
    try:
        shared = registry_groups(PHASE20)
        teams, roles = site_arrays(site)
    except ValueError as e:
        return 400, {"error": str(e)}
    try:
        reserved = standing_uids(teams, roles)
    except ValueError as e:
        return 500, {"error": str(e)}
    universe = shared | {gid for gid, _ in teams} | {gid for gid, _, _ in roles}

    rows, errors = roster_parse(csv_text.lstrip("\ufeff"), reserved, universe)
    if errors:
        return roster_refusal(errors, teams, shared, roles)

    # — where the roster lives: the SITE_ROSTER line names it (empty = the default this sets).
    # The write surface is sites/<codigo>/ by construction (the /api/sitio discipline): a
    # hand-set or traversing SITE_ROSTER pointing elsewhere is refused, never followed.
    root = os.path.join(deis.HERE, "..")
    rel = os.path.relpath(site, root)
    with open(site, encoding="utf-8") as fh:
        site_text = fh.read()
    try:
        roster_abs, roster_rel, need_set, default_rel = roster_paths(site_text, root, rel, codigo)
    except RosterPathError as e:
        return e.status, {"error": str(e)}

    # The seal runs FIRST, before any mutation: it is the one step that can refuse on
    # pre-existing state (a sheet this program did not write), and its 409 leaves the site and
    # the roster untouched — the operator clears the sheet and re-posts the same planilla.
    # (A seal that succeeds followed by a failed roster write is harmless the other way: the
    # sheet is cumulative, so a uid whose row arrived early finds it again on the retry.)
    # SEAL_LOCK serializes the read-modify-write — a double-submitted POST must not interleave
    # two seals on the one tmp inode (R1's double-submit arm).
    # a8: each cargo account (phase 50's positions) gets its own first password in the same sheet,
    # sealed with the planilla's — the executor never generates one
    cargos = [(uid, "Cargo", uid, "", (), False) for uid in reserved if uid != "admin"]
    try:
        with SEAL_LOCK:
            fresh, sealed = seal_credentials(codigo, rows + cargos, CRED_PATH)
    except ValueError:
        return 409, {"error": f"{CRED_PATH} existe pero no se puede leer como una hoja sellada "
                              "por el Provisionador — corríjalo a mano, o muévalo si no es suyo, antes de "
                              "volver a cargar la planilla"}
    except OSError as e:
        return 500, {"error": f"no se pueden sellar las credenciales en {CRED_PATH}: {e}"}

    os.makedirs(os.path.dirname(roster_abs), exist_ok=True)
    with open(roster_abs, "w", encoding="utf-8", newline="\n") as fh:
        w = csv.writer(fh, delimiter=";", lineterminator="\n")
        w.writerow(ROSTER_HEADER)
        for uid, nombre, apellidos, correo, gids, primer in rows:
            w.writerow([uid, nombre, apellidos, correo, " ".join(gids),
                        "si" if primer else "no"])
    if need_set:
        # Surgical: exactly the SITE_ROSTER line, byte-identical elsewhere — the file is the
        # operator's, hand-edited from /api/sitio onward, so a rewrite that touched anything
        # else would silently revert a hand edit (the silent-green class).
        with SITE_LOCK:   # «Reemplazar» rewrites the same file
            with open(site, encoding="utf-8") as fh:
                actual = fh.read()
            write_site_text(site, re.sub(r"(?m)^SITE_ROSTER=.*$", f"SITE_ROSTER={default_rel}",
                                         actual, count=1))
    primer_uid = next((uid for uid, _n, _a, _c, _g, p in rows if p), None)
    if primer_uid is None:
        # roster_parse enforces exactly-one; this is the belt-and-braces arm — a future edit that
        # breaks that rule must answer JSON, never crash a thread mid-request (the tamper-test
        # caught exactly this: an unguarded next() dropped the connection).
        return 500, {"error": "invariante rota: una planilla válida sin primer_admin = sí — "
                              "repórtelo como error del instalador"}
    return 200, {"ok": True, "usuarios": len(rows), "primer_admin": primer_uid,
                 "roster": roster_rel, "credenciales": CRED_PATH,
                 "contrasenas_nuevas": fresh, "contrasenas_selladas": sealed,
                 "filas": [[uid, f"{nombre} {apellidos}", list(gids), primer]
                           for uid, nombre, apellidos, _c, gids, primer in rows]}


def why(e):  # the OS's own text is English: the common cases in Spanish, else the errno name
    return {errno.ENOENT: "no existe", errno.EACCES: "sin permiso", errno.EISDIR: "es un directorio",
            errno.ENOSPC: "disco lleno"}.get(e.errno, errno.errorcode.get(e.errno, "error de archivo"))


def veredicto(body):
    """(head, items) of an execution — the verdict as «aps-conecta estado» states it: record_state
    writes both, the browser shows the head (a16: the gate's notes carry operator vocabulary)."""
    if body.get("divergencia_vacia"):
        return "✓ la instancia coincide con lo declarado", []
    if "divergencia_vacia" in body:
        items = [ln[4:] for ln in body.get("divergencia", "").splitlines()
                 if ln.startswith("    ") and not ln.startswith("     ")]
        if items:
            return "✗ deriva: la instancia tiene lo que no se declaró", items
        # the gate stopped before its list (a FATAL): its own last lines are the cause
        return ("✗ la revisión de divergencia no terminó",
                [ln.strip() for ln in body.get("divergencia", "").splitlines() if ln.strip()][-3:])
    return "✗ la ejecución no terminó", [body.get("error", "")]


def plan_clinico(codigo, teams, rows, cargos):
    """The review step's plan in clinic terms (R40): the centre by name, its sectors and programs,
    every person the planilla declares (the first administrator marked), the cargo accounts it adds,
    and what the clinic gets (R37) — no path, no file, no key."""
    row = find_row(codigo)
    opciones = opciones_actuales()
    sin_talk = opciones is not None and not opciones[0]   # step 7 left Talk off: phase 12 installs no spreed
    return {"centro": {"codigo": codigo,
                       "nombre": row["nombre"] if row else f"el establecimiento DEIS {codigo}",
                       "comuna": row["comuna"] if row else ""},
            "sectores": [d for g, d in teams if g.startswith("sector-")],
            "programas": [d for g, d in teams if g.startswith("prog-")],
            "personas": [[uid, f"{nombre} {apellidos}", list(gids), primer]
                         for uid, nombre, apellidos, _c, gids, primer in rows],
            "cuentas_de_cargo": len(cargos),
            "componentes": [[nombre, que] for app, nombre, que in COMPONENTES
                            if not (sin_talk and app == "spreed")]}


def record_state(body):
    """The last execution's verdict, for «aps-conecta estado» and the admins' notification (a10): a
    head line — the time in Santiago and the verdict — then each item with its fix (the gate's own
    Spanish lines), or the cause of a run that stopped before the gate. 0644 and whole (tmp, then
    rename): readable without sudo, never half a state."""
    from datetime import datetime
    from zoneinfo import ZoneInfo
    head, items = veredicto(body)
    when = datetime.now(ZoneInfo("America/Santiago")).strftime("%Y-%m-%d %H:%M")
    text = f"{when} (hora de Santiago) · {head}\n" + "".join(f"  · {i}\n" for i in items if i)
    os.makedirs(os.path.dirname(ESTADO_PATH), exist_ok=True)
    with open(ESTADO_PATH + ".tmp", "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(ESTADO_PATH + ".tmp", 0o644)
    os.replace(ESTADO_PATH + ".tmp", ESTADO_PATH)


def api_generar(payload):
    """POST /api/generar — the step itself is _api_generar. An execution that ran (its output is in
    the body) also leaves its verdict in ESTADO_PATH, whoever ran it: the web installer, the silent
    install or the weekly timer (a10)."""
    status, body = _api_generar(payload)
    # a refusal before the run is a red run too (its cause is the record); another run in progress
    # is not this instance's state
    if payload.get("modo") == "ejecutar" and ("salida" in body or (status != 200 and "en curso" not in
                                                                    body.get("error", ""))):
        try:
            record_state(body)
        except Exception as e:  # the file mirrors the verdict; the verdict itself stands
            print(f"  ✗ no se pudo escribir {ESTADO_PATH} "
                  f"({why(e) if isinstance(e, OSError) else type(e).__name__})", file=sys.stderr)
    return status, body


def avance(line):
    """An executor line → the browser's progress (a14), in the console's own words: a finished phase
    by its title, the planilla once its accounts are in. Only a run the browser started is followed:
    the silent install and the weekly timer share this path and have no page to feed."""
    if EJECUCION["estado"] != "en_curso":
        return
    m = re.match(r"✓ phase (\S+)$", line.rstrip("\n"))
    if m:
        EJECUCION["hechos"].append(PHASE_TITLES.get(m.group(1), m.group(1)))
    elif re.match(r"== roster: \d+ usuario", line):
        EJECUCION["hechos"].append(PASO_PLANILLA)


def iniciar_ejecucion(payload, server):
    """POST /api/generar {"modo": "ejecutar"} from the browser: the run starts on a worker and the
    answer leaves at once (202) — no request is held open for minutes (a14); GET /api/ejecucion
    follows it. A second start while one runs is refused, as api_generar itself refuses it."""
    codigo = payload.get("codigo")
    if not isinstance(codigo, str) or not CODIGO.fullmatch(codigo):
        return 400, {"error": "el código DEIS debe ser de 4 a 6 dígitos"}
    with EJEC_GUARD:
        if SUITE["estado"] == "en_curso":   # the run needs the suite the wizard is about to start
            return 409, {"error": "el asistente se está preparando — espere a que termine"}
        if EJECUCION["estado"] == "en_curso" or EXEC_LOCK.locked():
            return 409, {"error": "ya hay una ejecución en curso — espere a que termine"}
        EJECUCION.update(estado="en_curso", hechos=[], veredicto=None)
        try:
            threading.Thread(target=ejecutar_web, args=(codigo, server), daemon=True).start()
        except RuntimeError as e:   # no thread to run it on: nothing started, nothing left frozen
            EJECUCION.update(estado="sin_ejecutar")
            return 500, {"error": f"no se pudo iniciar la ejecución ({e})"}
    return 202, {"ok": True, "en_curso": True}


def ejecutar_web(codigo, server):
    """The worker: api_generar as the silent install runs it (resumen: the console gets the Spanish
    summary, the log the rest; the state file its verdict, a10), the verdict kept for the poll, and
    a green one closes the installer (SEC-2) — from here, never from api_generar, which --paso
    generar and the weekly timer share."""
    try:
        status, body = api_generar({"codigo": codigo, "modo": "ejecutar", "resumen": True})
    except Exception as e:   # never a silent dead worker: the console and the state file get the cause
        status, body = 500, {"error": f"la ejecución se detuvo ({type(e).__name__}: {e})"}
        print(f"  ✗ {body['error']}", file=sys.stderr)
        try:
            record_state(body)
        except Exception:   # the console line above already carries it
            pass
    verde = status == 200 and body.get("divergencia_vacia") is True
    try:
        if "divergencia_vacia" in body:   # the gate ran: its row is done, whatever it found
            EJECUCION["hechos"].append(PASO_GATE)
        if verde:   # DONE before the poll can read green: /listo answers, a second start is refused (SEC-2)
            server.close_after_success()
    finally:   # whatever the close does, the run never stays «en curso»
        EJECUCION.update(estado="terminada", veredicto={"verde": verde, "titulo": veredicto(body)[0]})


def estado_ejecucion():
    """GET /api/ejecucion — the page's poll, once a second: the run as a snapshot (a14). The field is
    «ejecucion», not «estado»: the page's api() already carries the HTTP status under that name."""
    e = dict(EJECUCION)
    return 200, {"ejecucion": e["estado"], "hechos": list(e["hechos"]), "pasos": PASOS_EJECUCION,
                 "veredicto": e["veredicto"]}


def _api_generar(payload):
    """POST /api/generar {"codigo", "modo": "revision"|"ejecutar"} — the FRD's review/dry-run AND
    the executor, one endpoint (the FRD's four-endpoint budget; slice 15's R1 reconciliation
    owns it here). Both modes re-derive the whole world first — site, registry universe, the
    canonical roster, the sealed sheet — so a hand edit between upload and run answers a 4xx
    with the same line-numbered errors /api/usuarios produces, never a half-seeded instance
    (fail closed). modo=revision answers the plan and performs ZERO execs and ZERO writes (the
    locked performance line); modo=ejecutar converges .env, runs the seed (phases 05→60 in glob
    order, fixtures ON), feeds the roster to provisioning/usuarios.sh (the #106 reader: python
    parses, bash rides the lib.sh helpers so the verbs are the seed's own), and hands off to the
    divergence gate — its exit code is the verdict the response carries, data never an error."""
    codigo = payload.get("codigo")
    if not isinstance(codigo, str) or not CODIGO.fullmatch(codigo):
        return 400, {"error": "el código DEIS debe ser de 4 a 6 dígitos"}
    modo = payload.get("modo", "revision")
    if modo not in ("revision", "ejecutar"):
        return 400, {"error": "el modo debe ser «revision» o «ejecutar»"}
    site = site_path(codigo)
    if not os.path.exists(site):
        return 404, {"error": "primero guarde los equipos (sectores y programas) de este centro"}
    root = os.path.join(deis.HERE, "..")
    rel = os.path.relpath(site, root)
    with open(site, encoding="utf-8") as fh:
        site_text = fh.read()
    try:
        shared = registry_groups(PHASE20)
        teams, roles = site_arrays(site)
        cats = role_categories(PHASE20, roles)
    except ValueError as e:
        return 400, {"error": str(e)}
    try:
        reserved = standing_uids(teams, roles)
    except ValueError as e:
        return 500, {"error": str(e)}
    universe = shared | {gid for gid, _ in teams} | {gid for gid, _, _ in roles}
    try:
        roster_abs, roster_rel, _need, _default = roster_paths(site_text, root, rel, codigo)
    except RosterPathError as e:
        return e.status, {"error": str(e)}
    if not os.path.exists(roster_abs):
        return 409, {"error": "no hay planilla cargada — primero valide la planilla de usuarios"}
    with open(roster_abs, encoding="utf-8") as fh:
        rows, errors = roster_parse(fh.read(), reserved, universe)
    if errors:
        # a hand edit of the canonical roster answers the upload screen's own line errors
        return roster_refusal(errors, teams, shared, roles)
    try:
        sealed = sealed_map(CRED_PATH)
    except ValueError:
        return 409, {"error": f"{CRED_PATH} existe pero no se puede leer como una hoja sellada "
                              "por el Provisionador — corríjalo a mano, o muévalo si no es suyo, antes de "
                              "volver a cargar la planilla"}
    missing = [uid for uid, _n, _a, _c, _g, _p in rows if uid not in sealed]
    if missing:
        # the seal happened at upload; a hand-added row with no sealed password must never
        # reach ensure_user — a blank password on user:add is a locked-out account on day one
        return 409, {"error": "la planilla nombra usuarios sin contraseña sellada: "
                              + ", ".join(missing)
                              + " — vuelva a cargar la planilla para sellarlos"}
    cargos = [uid for uid in reserved if uid != "admin"]
    unsealed = [uid for uid in cargos if uid not in sealed]
    if unsealed:
        # a sector or a local jefatura added to the site after the planilla was loaded
        return 409, {"error": "el sitio declara cargos sin contraseña sellada: " + ", ".join(unsealed)
                              + " — vuelva a cargar la planilla para sellarlos"}
    primer_uid = next((uid for uid, _n, _a, _c, _g, p in rows if p), None)
    if primer_uid is None:  # the belt-and-braces arm — the 500 template, never a crash
        return 500, {"error": "invariante rota: una planilla válida sin primer_admin = sí — "
                              "repórtelo como error del instalador"}
    phases = sorted(p for p in os.listdir(os.path.join(root, "provisioning", "phases"))
                    if p[:1].isdigit() and p.endswith(".sh"))
    est = env_state(root)
    if est["site"] not in (None, codigo):
        # D13 refuses at review time too — the operator learns before pulling the trigger
        return 409, {"error": f"el .env nombra el establecimiento SITE={est['site']}, no "
                              f"{codigo} — un install sirve a un establecimiento; migre "
                              "deliberadamente"}

    if modo == "revision":
        return 200, {"ok": True, "modo": "revision", "sitio": rel, "roster": roster_rel,
                     "fases": phases, "usuarios": len(rows), "primer_admin": primer_uid,
                     "contrasenas_selladas": len(sealed),
                     "env": {"SITE": codigo if est["site"] == codigo
                             else "se escribirá " + codigo,
                             "SEED_FIXTURES": "1 (sin cambio)" if est["seed_fixtures"] == "1"
                             else "se forzará a 1",
                             "FIXTURE_USER_PASSWORD": "presente" if est["fixture"]
                             else "se generará"},
                     "divergencia": "se comprueba al final de la ejecución",
                     **plan_clinico(codigo, teams, rows, cargos)}

    # ── ejecutar: one run at a time; the seed and the driver and the gate in order ──
    if not EXEC_LOCK.acquire(blocking=False):
        return 409, {"error": "ya hay una ejecución en curso — espere a que termine e inténtelo "
                              "de nuevo"}
    log = None
    try:
        if payload.get("resumen") is True:
            log = open(os.path.join(root, ".install.log"), "w", encoding="utf-8", buffering=1)
        resumen = summary(log) if log else None

        def show(line):   # the browser's progress (a14), then the console's own view
            avance(line)
            return resumen(line) if resumen else line
        try:
            env_report = env_converge(root, codigo)
        except ValueError as e:
            return 409, {"error": str(e)}
        rc, seed_out = run_tee(["bash", "provisioning/seed.sh"], cwd=root,
                               timeout=TIMEOUTS["seed"],
                               env={**os.environ, "STANDING_PASSWORDS":
                                    " ".join(f"{u}:{sealed[u][0]}" for u in cargos)}, show=show)
        if rc is None:
            return 500, {"error": f"la preparación excedió el límite de {TIMEOUTS['seed']} s — "
                                  "revise la salida y el estado de la instancia",
                          "salida": seed_out}
        if rc != 0:
            fatals = [ln for ln in seed_out.splitlines() if ln.startswith("FATAL:")]
            # the cause the phase printed, not the runner's «phase X failed» line that follows it
            fatal = next((f for f in fatals if not re.match(r"FATAL: phase \S+ failed$", f)),
                         fatals[-1] if fatals else "la preparación falló")
            # the gate never runs after a failed phase (the locked research flow)
            return 500, {"error": fatal, "salida": seed_out}
        records = []
        for uid, nombre, apellidos, _correo, gids, primer in rows:
            # a8: every planilla user is staff and joins the category of each of their roles
            groups = sorted(set(gids) | {"all-staff"} | {cats[g] for g in gids if g in cats})
            records += [uid, f"{nombre} {apellidos}", sealed[uid][0], " ".join(groups),
                        "si" if primer else "no"]
        records.append("")  # the driver's terminator
        rc, roster_out = run_tee(["bash", "provisioning/usuarios.sh"], cwd=root,
                                  timeout=TIMEOUTS["roster"],
                                  stdin_text="\n".join(records) + "\n", show=show)
        if rc is None:
            return 500, {"error": f"la planilla excedió el límite de {TIMEOUTS['roster']} s — "
                                  "revise la salida y el estado de la instancia",
                          "salida": seed_out + roster_out}
        if rc != 0:
            fatal = next((ln for ln in reversed(roster_out.splitlines())
                          if ln.startswith("FATAL:")), "la planilla falló")
            return 500, {"error": fatal, "salida": seed_out + roster_out}
        rc, gate_out = run_tee(["bash", "scripts/divergence.sh", "--gate"], cwd=root,
                               timeout=TIMEOUTS["gate"], show=show)
        if rc is None:
            return 500, {"error": f"la divergencia excedió el límite de {TIMEOUTS['gate']} s",
                          "salida": seed_out + roster_out + gate_out}
        # the gate's exit code is the verdict, carried as data — a red gate is a finding the
        # operator must see, never an execution error
        return 200, {"ok": True, "modo": "ejecutar", "sitio": rel, "fases": phases,
                     "usuarios": len(rows), "env": env_report,
                     "salida": seed_out + roster_out,
                     "divergencia_vacia": rc == 0, "divergencia": gate_out}
    finally:
        if log:
            log.close()
        EXEC_LOCK.release()


class RosterPathError(Exception):
    """A SITE_ROSTER line the roster leg cannot follow — carried as (status, es-CL message),
    because the refusal is part of the contract (409 outside the site dir, 500 no line at all)."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def roster_paths(site_text, root, rel, codigo):
    """Where the roster lives: the SITE_ROSTER line names it (empty = the default, which the
    uploading leg sets). The write surface is sites/<codigo>/ by construction (the /api/sitio
    discipline): a hand-set or traversing SITE_ROSTER pointing elsewhere is refused, never
    followed. Factored out of api_usuarios at slice 16 because the executor resolves the same
    path to READ the canonical roster — one resolution, one containment rule."""
    m = re.search(r"^SITE_ROSTER=(.*)$", site_text, re.M)
    if m is None:
        raise RosterPathError(500, f"{rel} no lleva línea SITE_ROSTER — regenérelo con el paso "
                                   "de sectores y programas")
    raw = m.group(1).strip()
    try:
        parts = shlex.split(raw) if raw else []
    except ValueError:
        parts = None
    default_rel = os.path.join("sites", codigo, "usuarios.csv")
    if not raw or parts == [""]:
        return os.path.join(root, default_rel), default_rel, True, default_rel
    if parts is None or len(parts) != 1:
        raise RosterPathError(409, f"la línea SITE_ROSTER de {rel} no se puede leer — debe ser "
                                   "una sola ruta, entre comillas si lleva espacios")
    roster_rel = parts[0]
    roster_abs = os.path.normpath(os.path.join(root, roster_rel))
    box = os.path.normpath(os.path.join(root, "sites", codigo)) + os.sep
    if not roster_abs.startswith(box):
        raise RosterPathError(409, f"SITE_ROSTER apunta fuera de sites/{codigo}/ — el "
                                   "Provisionador solo escribe dentro del directorio del "
                                   "establecimiento")
    return roster_abs, roster_rel, False, default_rel


def env_state(root):
    """The .env posture, read-only — the dry-run's preview and the converge's pre-check share it.
    Values are never returned: SITE's line value only ever feeds the D13 comparison, and the
    fixture password only ever answers «presente» (print-WHERE-never-WHAT, the env-init rule)."""
    path = os.path.join(root, ".env")
    site, fixture, seed_fixtures = None, False, None
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for ln in fh:
                if ln.startswith("SITE="):
                    site = ln[5:].strip().strip("\"'")
                elif ln.startswith("FIXTURE_USER_PASSWORD="):
                    fixture = True
                elif ln.startswith("SEED_FIXTURES="):
                    seed_fixtures = ln[14:].strip()
    return {"path": path, "site": site, "fixture": fixture, "seed_fixtures": seed_fixtures}


def env_converge(root, codigo):
    """Converge .env for a run. The locked slice-14 note: env.sh's loader OVERWRITES exported
    vars, so exporting SITE at the subprocess buys nothing — the file is the only carrier, and
    this is the write. SITE: absent → appended; equal → untouched; DIFFERENT → refused (D13: one
    establishment per install; re-pointing an install is a deliberate migration, never a side
    effect — the /api/sitio converge-or-refuse rule). SEED_FIXTURES is forced to 1 — the
    executor's locked posture runs the fixtures ON, and a .env carrying 0 would skip phase 50's
    standing accounts while the roster still seeded, leaving the clinic without its cargos.
    FIXTURE_USER_PASSWORD: absent → generated (CSPRNG 24-hex, env-init's size) and appended —
    present → NEVER touched (env-init's rule: a secret we did not invent is never rewritten);
    a placeholder that survived a hand-copy dies at the seed's own require_real_secrets with its
    own fix hint, carried in the 500's log. A fresh AIO install has no .env at all: this creates
    it minimal — exactly the keys the seed's own gates demand (the wizard owns the stack; the
    compose-era keys are unused there) — 0600 before content."""
    st = env_state(root)
    if st["site"] not in (None, codigo):
        raise ValueError(f"el .env nombra el establecimiento SITE={st['site']}, no {codigo} — "
                         "un install sirve a un establecimiento (D13); migre deliberadamente")
    lines = []
    if os.path.exists(st["path"]):
        with open(st["path"], encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    report = {"SITE": "ya era " + codigo if st["site"] == codigo else "escrito",
              "SEED_FIXTURES": "1, sin cambio" if st["seed_fixtures"] == "1" else "forzado a 1",
              "FIXTURE_USER_PASSWORD": "presente" if st["fixture"] else "generada"}
    if st["site"] is None:
        lines.append(f"SITE={codigo}")
    if st["seed_fixtures"] != "1":
        lines = [ln for ln in lines if not ln.startswith("SEED_FIXTURES=")] + ["SEED_FIXTURES=1"]
    if not st["fixture"]:
        lines.append(f"FIXTURE_USER_PASSWORD={secrets.token_hex(SEAL_BYTES)}")
    text = "\n".join(lines) + "\n"
    if os.path.exists(st["path"]) and open(st["path"], encoding="utf-8").read() == text:
        return report  # converged already — byte-stable, mtime-stable (the re-run arm)
    fd = os.open(st["path"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    os.chmod(st["path"], 0o600)  # the assert: an inherited 0644 from an old hand-copy is fixed
    return report



def summary(log):
    """The silent install's console (R42): every executor line goes whole to the log, and the
    console gets one Spanish line per finished phase plus the roster's count — never the seed's
    English vocabulary."""
    def show(line):
        log.write(line)
        m = re.match(r"✓ phase (\S+)$", line.rstrip("\n"))
        if m:
            return f"  ✓ {PHASE_TITLES.get(m.group(1), m.group(1))}\n"
        m = re.match(r"== roster: (\d+) usuario", line)
        return f"  ✓ Planilla: {m.group(1)} personas\n" if m else None
    return show


def run_tee(argv, cwd, timeout, stdin_text=None, env=None, show=None):
    """One executor subprocess, its stdout BOTH on the provisionador's own stdout (the FRD's
    host-side record: the operator watching the terminal where `aps-conecta provision` printed
    the banner sees the phases live — slice 14's line-buffered stdout makes that real) and
    captured for the response. Returns (rc, text); rc is None when the bound killed the run
    (B-015 — every subprocess bounded, never a hang). p.kill() targets bash; a wedged docker-CLI
    grandchild is docker's own timeout's business — the ceiling this comment names."""
    out = []

    def pump():
        for line in p.stdout:
            out.append(line)
            shown = line if show is None else show(line)  # the silent install's summary (R42)
            if shown:
                sys.stdout.write(shown)
        p.stdout.close()

    # NO start_new_session on purpose: Ctrl+C at the provisionador's terminal must reach the
    # running seed (SIGINT propagates to the process group; a detached session would orphan the
    # phases mid-write). The timeout's p.kill() targets bash only — a wedged docker-CLI
    # grandchild is docker's own timeout's business (the ceiling the docstring names).
    p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE if stdin_text is not None else None,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    t = threading.Thread(target=pump, daemon=True)
    t.start()
    if stdin_text is not None:
        try:
            p.stdin.write(stdin_text)
        except BrokenPipeError:
            pass
        p.stdin.close()
    try:
        rc = p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        t.join(timeout=5)
        return None, "".join(out)
    t.join(timeout=5)
    return rc, "".join(out)


class ClientError(Exception):
    """A request the server refuses before any endpoint runs — carried as (status, es-CL message)."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


# ── The UI (slice 17, FRD S6; L3 S1: the approved Instalador UI, variant A «Capítulos») ──────────
# Server-rendered screens over the JSON APIs. No frameworks, no sessions — the login cookie CARRIES
# the token (HttpOnly, SameSite=Strict, Secure: the installer serves HTTPS with its own certificate).
# The screens are SHELLS: the frame — the backdrop rail of the registry's steps, the chapter header
# — is server-rendered; the interactive data arrives through the same /api routes a CLI would use.
# The token never rides a request (the link's fragment is never sent); the screens use relative
# links only, so no page names its own address either (the FRD's Paso-1 rule generalized).
#
# THE FONT DECISION (reversed in L3 S1): the approved design is Fraunces + Nunito Sans; the theme's
# own woff2 files are served from /recursos/ — local bytes, zero egress, never a font CDN.

TOKEN_COOKIE = "aps_token"  # the name; the VALUE is the token itself (the credential, compared
                            # constant-time in authorized()'s cookie arm — same code path)

esc = html.escape

# The brand mark (patch 070's lockup) — inline SVG, so the rail and the backdrop make no request.
LOCKUP = (
    '<span class="lockup" translate="no"><svg class="marca-svg" viewBox="8 5 48 50" aria-hidden="true">'
    '<path d="M32 12 L45 23 M32 12 L19 23 M45 23 L38 39 M19 23 L26 39 M38 39 L26 39 M38 39 L45 51 '
    'M26 39 L19 51" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" opacity=".5"/>'
    '<path d="M11 33 Q23 27 32 33 T53 30" fill="none" stroke="#f28f36" stroke-width="2" '
    'stroke-linecap="round"/><g fill="#fff"><circle cx="45" cy="23" r="2.5"/><circle cx="19" cy="23" '
    'r="2.5"/><circle cx="38" cy="39" r="2.3"/><circle cx="26" cy="39" r="2.3"/><circle cx="45" '
    'cy="51" r="2.1"/><circle cx="19" cy="51" r="2.1"/></g><path d="M32 7.2 L33.25 10.75 L36.8 12 '
    'L33.25 13.25 L32 16.8 L30.75 13.25 L27.2 12 L30.75 10.75 Z" fill="#f28f36"/></svg>'
    '<span><b>APS Conecta Gestión</b><small>Instalador web</small></span></span>')


def page_css():
    """Variant A «Capítulos» (the approved Instalador UI, stage V): the D1 tokens (FRD: primary
    #7f21fe 5.57:1, background #5315a8, hover #6b01fa, error #ea003e, gold #e06f00 large-only, ink
    #101828, muted #485363) plus the design's own, the brand fonts from /recursos/, the backdrop
    rail and chapter column, and the legacy screen classes (.tarjeta, .aviso, tables, forms)
    restyled to the editorial look. Light-only (BRANDING §2). One function, inlined into <head>."""
    return """<style>
@font-face{font-family:"Fraunces";src:url(/recursos/fraunces.woff2) format("woff2");font-weight:400 800;font-style:normal;font-display:swap}
@font-face{font-family:"Fraunces";src:url(/recursos/fraunces-italica.woff2) format("woff2");font-weight:400 800;font-style:italic;font-display:swap}
@font-face{font-family:"Nunito Sans";src:url(/recursos/nunito-sans.woff2) format("woff2");font-weight:400 800;font-style:normal;font-display:swap}
:root{--primario:#7f21fe;--fondo:#5315a8;--encima:#6b01fa;--error:#ea003e;--oro:#e06f00;
--tinta:#101828;--apagado:#485363;--blanco:#fff;--papel:#faf7ff;--linea:#e1d7f4;--velo:#f1e9ff;
--ok:#0b7a4b;--marca:#f28f36;--tenue-b:rgba(255,255,255,.88);
--f-display:"Fraunces","Iowan Old Style",Georgia,serif;
--f-cuerpo:"Nunito Sans","Segoe UI",system-ui,sans-serif;
--f-mono:ui-monospace,"SFMono-Regular","Cascadia Mono",Menlo,Consolas,monospace;
--t-xs:.8125rem;--t-s:.9375rem;--t-m:1.0625rem;--t-l:1.375rem;--t-titulo:clamp(2.1rem,3.6vw,3.25rem);
--gutter:max(16px,4vw);
--riel:radial-gradient(circle at 28% 26%,rgba(164,119,255,.45),transparent 65%),
radial-gradient(circle at 82% 88%,rgba(38,9,79,.55),transparent 55%),linear-gradient(135deg,#893dff,#5315a8)}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--papel);color:var(--tinta);font:400 var(--t-m)/1.6 var(--f-cuerpo)}
h1,h2,h3{font-family:var(--f-display);font-weight:650;line-height:1.12;margin:0;letter-spacing:-.01em;text-wrap:balance}
p{margin:0;max-width:62ch}
a{color:var(--primario)}
button,input,select,textarea{font:inherit;color:inherit}
:focus-visible{outline:3px solid var(--primario);outline-offset:3px}
.sobre-telon :focus-visible{outline-color:#fff}
h1[tabindex]:focus{outline:none}
.saltar{position:fixed;left:12px;top:-4rem;z-index:70;background:#fff;color:var(--fondo);padding:.7rem 1rem;font-weight:700;border-radius:3px}
.saltar:focus{top:12px}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{transition:none!important;animation:none!important}}
.ceja{font:700 var(--t-xs)/1.3 var(--f-cuerpo);letter-spacing:.09em;text-transform:uppercase;color:var(--apagado)}
.para{color:var(--apagado);max-width:60ch}
.sobre-telon .para{color:#fff}
.pila{display:flex;flex-direction:column;gap:1.25rem;min-width:0}
.fila{display:flex;flex-wrap:wrap;gap:.75rem 1rem;align-items:center}
.btn,button{display:inline-flex;align-items:center;gap:.55rem;padding:.85rem 1.3rem;margin-top:.9rem;border:0;
border-radius:3px;background:var(--primario);color:#fff;font:700 var(--t-s)/1 var(--f-cuerpo);cursor:pointer;
text-decoration:none;transition:background-color .15s ease}
.btn:hover,button:hover{background:var(--encima)}
button:disabled{background:#cfc5e6;cursor:not-allowed}
.btn-blanco,.telon button{background:#fff;color:var(--fondo)}
.btn-blanco:hover,.telon button:hover{background:var(--velo)}
.marca-svg{width:2.6rem;height:2.7rem;flex:none}
.lockup{display:flex;align-items:center;gap:.75rem;color:#fff}
.lockup b{display:block;font:650 1.2rem/1.1 var(--f-display)}
.lockup small{display:block;font:600 .75rem/1.2 var(--f-cuerpo);letter-spacing:.08em;text-transform:uppercase;opacity:.78}
.marco{display:grid;grid-template-columns:18rem minmax(0,1fr);min-height:100dvh}
.riel{position:sticky;top:0;height:100dvh;overflow:auto;color:#fff;padding:2rem 1.4rem 1.5rem;background:var(--riel);
display:flex;flex-direction:column;gap:2rem}
.riel ol{list-style:none;margin:0;padding:0;display:grid;gap:.15rem}
.riel li{display:grid;grid-template-columns:2.1rem minmax(0,1fr);gap:.65rem;align-items:start;padding:.55rem .5rem;border-radius:3px}
.riel .n{width:2.1rem;height:2.1rem;border:1.5px solid rgba(255,255,255,.55);border-radius:50%;display:grid;
place-items:center;font:700 .95rem/1 var(--f-display)}
.riel .hecho .n{border-color:transparent;background:rgba(255,255,255,.16)}
.riel .ahora{background:rgba(255,255,255,.13)}
.riel .ahora .n{background:#fff;color:var(--fondo);border-color:#fff}
.riel .t{display:block;font-weight:700;font-size:.95rem;line-height:1.3}
.riel .d{display:block;font:700 .68rem/1.4 var(--f-cuerpo);letter-spacing:.09em;text-transform:uppercase;color:var(--tenue-b)}
.riel .grupo{font:700 .7rem/1 var(--f-cuerpo);letter-spacing:.12em;text-transform:uppercase;color:var(--tenue-b);padding:1rem .5rem .35rem}
.riel .pie{margin-top:auto;font-size:.8rem;color:var(--tenue-b);line-height:1.5}
.riel-movil{display:none}
.hoja{padding:clamp(2.25rem,5vw,4.5rem) var(--gutter) 7rem clamp(1.5rem,6vw,6.5rem);min-width:0}
.apertura{display:grid;grid-template-columns:auto minmax(0,1fr);gap:.25rem 2rem;align-items:end;margin-bottom:2.25rem}
.apertura .numeral{font:800 clamp(6rem,11vw,10.5rem)/.78 var(--f-display);color:var(--primario);letter-spacing:-.04em}
.apertura h1{font-size:var(--t-titulo)}
.apertura .para{grid-column:1/-1;margin-top:1.1rem}
.cuerpo{max-width:50rem;display:flex;flex-direction:column;gap:2rem}
.tarjeta{border-top:1px solid var(--linea);padding-top:1.25rem}
.tarjeta h2{font-size:var(--t-l);margin-bottom:.6rem;color:var(--fondo)}
.tarjeta p{margin:.4rem 0}
label{display:block;margin:.9rem 0 .35rem;font:700 var(--t-xs)/1.3 var(--f-cuerpo);letter-spacing:.07em;
text-transform:uppercase;color:var(--apagado)}
input[type=text],input[type=password],input[type=search],input[type=file]{width:100%;padding:.7rem .8rem;
min-height:2.75rem;background:#fff;color:var(--tinta);border:1.5px solid #cdbfe9;border-radius:3px;font-size:var(--t-s)}
.aviso,.error,.ok{border-left:3px solid var(--oro);padding:.1rem 0 .1rem 1rem;margin:.8rem 0;max-width:62ch}
.error{border-left-color:var(--error)}
.ok{border-left-color:var(--ok)}
table{border-collapse:collapse;width:100%;font-size:var(--t-s)}
th{text-align:left;font:700 var(--t-xs)/1.3 var(--f-cuerpo);letter-spacing:.07em;text-transform:uppercase;
color:var(--apagado);padding:.5rem .75rem .5rem 0;border-bottom:1.5px solid var(--linea)}
td{padding:.55rem .75rem .55rem 0;border-bottom:1px solid var(--linea);vertical-align:top}
code{font:600 .85em var(--f-mono);background:var(--velo);color:var(--fondo);padding:0 .35rem;border-radius:2px}
pre{font:400 .84rem/1.6 var(--f-mono);overflow-x:auto}
.telon{min-height:100dvh;color:#fff;background:var(--fondo) url(/recursos/fondo.svg) 78% 50%/cover no-repeat;
padding:clamp(2rem,6vw,5.5rem) var(--gutter) 7rem clamp(1.5rem,7vw,7rem)}
.telon .pila{max-width:38rem;gap:1.6rem}
.telon h1{font-size:clamp(2.6rem,5.2vw,4.6rem);font-weight:700}
.telon .grande{font-size:var(--t-l)}
.telon label{color:var(--tenue-b)}
.telon .error,.telon .aviso{color:#fff}
.lema{font:italic 500 clamp(1.25rem,2.2vw,1.7rem)/1.35 var(--f-display);color:#fff;max-width:30ch}
.lema::before{content:"«";color:var(--marca)}
.lema::after{content:"»";color:var(--marca)}
.colofon{font-size:.85rem;color:var(--tenue-b);display:grid;gap:.2rem;border-top:1px solid rgba(255,255,255,.28);
padding-top:1rem;max-width:34rem}
.colofon a{color:#fff}
.lista-sigue{margin:0;padding-left:1.1rem;display:grid;gap:.35rem}
.vh{position:absolute!important;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.filtros{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:.9rem}
.filtros>:first-child{grid-column:1/-1}
.campo{display:flex;flex-direction:column;gap:.35rem;min-width:0}
.campo>label,.campo>.etq{margin:0;font:700 var(--t-xs)/1.3 var(--f-cuerpo);letter-spacing:.07em;
text-transform:uppercase;color:var(--apagado)}
.control{width:100%;padding:.7rem .8rem;background:#fff;color:var(--tinta);min-height:2.75rem;
border:1.5px solid #cdbfe9;border-radius:3px;font-size:var(--t-s)}
.control:focus-visible{outline-offset:1px;border-color:var(--primario)}
.control:disabled{background:var(--papel);color:var(--apagado)}
.combo{position:relative}
.combo-btn{width:100%;margin:0;text-align:left;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:.75rem;
align-items:center;padding:.8rem .9rem;background:#fff;color:var(--tinta);border:1.5px solid var(--primario);
font:inherit;line-height:1.4}
.combo-btn:hover{background:#fff}
.combo-btn b{display:block;font-weight:800;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.combo-btn small,.combo-lista small{color:var(--apagado);font-size:var(--t-xs)}
.combo-btn::after{content:"▾";color:var(--primario);font-size:1.1rem}
.combo-panel{position:absolute;z-index:20;left:0;right:0;top:calc(100% + 4px);background:#fff;
border:1.5px solid var(--primario);border-radius:3px;box-shadow:0 14px 34px rgba(83,21,168,.2);padding:.6rem}
.combo-panel .control{border-color:var(--linea)}
.combo-lista{list-style:none;margin:.5rem 0 0;padding:0;max-height:18rem;overflow:auto;overscroll-behavior:contain}
.combo-lista li button{width:100%;margin:0;text-align:left;background:none;color:inherit;border:0;
padding:.5rem .55rem;border-radius:2px;display:block;font:inherit;line-height:1.4}
.combo-lista li button:hover,.combo-lista li button:focus-visible{background:var(--velo);outline-offset:-2px}
.combo-lista li button[aria-selected="true"]{background:var(--velo);box-shadow:inset 3px 0 0 var(--primario)}
.combo-lista b{display:block;font-weight:700;font-size:var(--t-s)}
.combo-grupo{font:700 .72rem/1.3 var(--f-cuerpo);letter-spacing:.08em;text-transform:uppercase;
color:var(--apagado);padding:.6rem .55rem .2rem}
.combo-pie{font-size:var(--t-xs);color:var(--apagado);padding:.5rem .55rem 0;border-top:1px solid var(--linea);margin-top:.4rem}
.dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:.45rem 1.25rem;margin:0;font-size:var(--t-s)}
.dl dt{color:var(--apagado)}
.dl dd{margin:0;font-weight:600}
.nota{font-size:var(--t-xs)}
@media (max-width:420px){.filtros{grid-template-columns:minmax(0,1fr)}}
textarea.control{min-height:7.5rem;resize:vertical;line-height:1.55}
.dos{display:grid;grid-template-columns:repeat(auto-fit,minmax(14rem,1fr));gap:.9rem}
.chips{display:flex;flex-wrap:wrap;gap:.3rem;min-height:1.6rem}
.chip{font:600 .8rem/1.6 var(--f-mono);background:var(--velo);color:var(--fondo);padding:0 .45rem;border-radius:2px}
details summary{cursor:pointer;font-weight:700;margin-top:.8rem}
.lista-ids{list-style:none;margin:.3rem 0 0;padding:0;display:grid;gap:.35rem;font-size:var(--t-s)}
.enlace-btn{background:none;border:0;padding:.7rem 0;margin:0;color:var(--primario);font:700 var(--t-s)/1.2 var(--f-cuerpo);cursor:pointer}
.enlace-btn:hover{background:none;color:var(--encima)}
code{overflow-wrap:anywhere}
[hidden]{display:none!important}
.barra{height:6px;background:var(--linea);border-radius:3px;overflow:hidden;margin:.6rem 0 1rem}
.barra>i{display:block;height:100%;width:100%;background:var(--primario);transform:scaleX(var(--p,0));
transform-origin:left;transition:transform .2s linear}
.lista-estado{list-style:none;margin:0;padding:0;display:grid;gap:.4rem;font-size:var(--t-s)}
.lista-estado li{display:grid;grid-template-columns:1.4rem minmax(0,1fr);gap:.5rem;align-items:baseline}
.lista-estado .ic{font-weight:800;color:var(--apagado)}
.lista-estado .hecho .ic{color:var(--ok)}
.lista-estado .ahora .ic{color:var(--oro)}
.lista-estado .ahora{font-weight:700}
.progreso-linea{font-weight:700;min-height:1.6em;margin-top:1rem}
.dl dd.normal{font-weight:400}
#x-plan h3.ceja{margin:1.6rem 0 .5rem}
#x-plan .nota{margin-top:1.2rem}
label.casilla{display:flex;gap:.55rem;align-items:center;font:400 var(--t-s)/1.4 var(--f-cuerpo);
letter-spacing:0;text-transform:none;color:var(--tinta);margin:.7rem 0}
.frase{font:600 var(--t-m)/1.4 var(--f-mono);overflow-wrap:anywhere}
@media (max-width:860px){
.marco{grid-template-columns:minmax(0,1fr)}
.riel{display:none}
.riel-movil{display:flex;position:sticky;top:0;z-index:6;justify-content:space-between;align-items:center;gap:1rem;
color:#fff;background:var(--riel);padding:.7rem var(--gutter);font:700 .85rem/1.3 var(--f-cuerpo)}
.riel-movil .ticks{display:flex;gap:4px}
.riel-movil .ticks i{width:9px;height:9px;border-radius:50%;border:1.5px solid rgba(255,255,255,.6)}
.riel-movil .ticks i.h{background:rgba(255,255,255,.55);border-color:transparent}
.riel-movil .ticks i.a{background:#fff;border-color:#fff}
.hoja{padding:1.75rem var(--gutter) 7rem}
}
</style>"""


def page_js():
    """The one script every page rides, loaded in <head> before any screen script (R34): the
    fragment's code read and wiped first, the API wrapper (the cookie flows automatically —
    same-origin fetch sends it; the Bearer arm stays for CLI use), the planilla reader with the
    DECODE-OR-WARN rule (a cp1252 hand-off mojibakes under readAsText; the file is read as BYTES,
    decoded UTF-8, and on failure decoded windows-1252 WITH a visible warning — the API contract is
    a UTF-8 string, so the decode is the UI's to own), the centre reader (no code rides a URL), and
    focus on the chapter title for screen readers."""
    return """<script>
// The link's code rides the URL fragment (#acceso=…), which no request carries; it leaves the
// address bar before anything else runs — it is a credential (a13).
const ACCESO = new URLSearchParams(location.hash.slice(1)).get("acceso");
if (ACCESO !== null) history.replaceState(null, "", location.pathname + location.search);
// a link pasted into an open page changes only the fragment — reload, so the line above reads it
addEventListener("hashchange", () => {
  if (new URLSearchParams(location.hash.slice(1)).get("acceso") !== null) location.reload();
});
addEventListener("DOMContentLoaded", () => {
  const h = document.querySelector("h1[tabindex]");
  if (h) h.focus({preventScroll: true});
});
async function api(ruta, cuerpo){
  let r;
  try {
    r = await fetch(ruta, {method: cuerpo ? "POST" : "GET",
      headers: {"Content-Type": "application/json"},
      body: cuerpo ? JSON.stringify(cuerpo) : undefined});
  } catch { return {estado: 0, error: "sin respuesta del instalador: revise la red y recargue la página"}; }
  const t = await r.text();
  try { return {estado: r.status, ...JSON.parse(t)}; }
  catch { return {estado: r.status, error: t}; }
}
async function leerPlanilla(archivo){
  // DECODE-OR-WARN: bytes first, UTF-8, then windows-1252 with a visible warning.
  const bytes = await archivo.arrayBuffer();
  try { return {texto: new TextDecoder("utf-8", {fatal: true}).decode(bytes)}; }
  catch { return {texto: new TextDecoder("windows-1252").decode(bytes),
                  aviso: "El archivo no estaba en UTF-8; se leyó como Windows-1252. " +
                         "Guárdelo como «CSV UTF-8» en Excel antes de la próxima vez."}; }
}
function escapear(s){ const d = document.createElement("div"); d.textContent = s ?? ""; return d.innerHTML; }
function zona(id){ return document.getElementById(id); }
async function centro(){
  // this install's centre lives on the server (L3 S2: no code rides a URL); none yet names the way back
  const r = await api("/api/centro");
  if (r.estado === 200 && r.codigo) return r.codigo;
  zona("m").innerHTML = '<div class="error">' + escapear(r.error || "Falta el centro.") +
    (r.estado === 200 ? ' <a href="/centro">Elegir el centro</a>' : "") + "</div>";
  return null;
}
</script>"""


def head(title):
    """Every page's <head>: the CSS and the one script load here, before any screen script (R34)."""
    return (f'<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>{esc(title)} — Instalador APS Conecta</title>'
            f'<link rel="icon" href="/recursos/favicon.svg" type="image/svg+xml">{page_css()}{page_js()}')


def shell(step_id, body, aviso=None):
    """A browser step's page, variant A «Capítulos»: the backdrop rail — the registry's steps, the
    server ones done, the current one marked (aria-current) — beside the chapter: numeral, «Paso n
    de N · en su navegador», the step's title and purpose, then the screen. A step may span screens
    until its own lap folds them into one (L3 S2–S4)."""
    n = next(i for i, x in enumerate(STEPS, 1) if x["id"] == step_id)
    s, total = STEPS[n - 1], len(STEPS)

    def paso(i, x):
        clase = "hecho" if i < n else "ahora" if i == n else ""
        actual = ' aria-current="step"' if i == n else ""
        marca = "✓" if i < n else str(i)
        return (f'<li class="{clase}"{actual}><span class="n" aria-hidden="true">{marca}</span>'
                f'<span><span class="t">{esc(x["titulo"])}</span>'
                f'<span class="d">{esc(x["donde"])}</span></span></li>')

    servidor = "".join(paso(i, x) for i, x in enumerate(STEPS, 1) if x["donde"] == "servidor")
    navegador = [(i, x) for i, x in enumerate(STEPS, 1) if x["donde"] != "servidor"]
    rail_nav = "".join(paso(i, x) for i, x in navegador)
    ticks = "".join(f'<i class="{"h" if i < n else "a" if i == n else ""}"></i>'
                    for i in range(1, total + 1))
    aviso_html = f'<div class="aviso">{aviso}</div>' if aviso else ""
    titulo = esc(s["titulo"])
    page_title = f"Paso {n} de {total} · {s['titulo']}"
    donde = esc(s["donde"])
    return f"""<!DOCTYPE html>
<html lang="es"><head>{head(page_title)}</head><body>
<a class="saltar" href="#contenido">Saltar al contenido</a>
<div class="marco"><nav class="riel sobre-telon" aria-label="Pasos de la instalación">{LOCKUP}
<div><div class="grupo">En este servidor</div><ol>{servidor}</ol>
<div class="grupo">En su navegador</div><ol start="{navegador[0][0]}">{rail_nav}</ol></div>
<p class="pie">Sesión: {esc(HOSTNAME)} · {esc(LAN_IP)}</p></nav>
<div class="riel-movil sobre-telon"><span>Paso {n} de {total} · {donde.capitalize()}</span>
<span class="ticks" aria-hidden="true">{ticks}</span></div>
<main class="hoja" id="contenido"><header class="apertura"><span class="numeral" aria-hidden="true">{n}</span>
<div><p class="ceja">Paso {n} de {total} · en su {donde}</p><h1 tabindex="-1">{titulo}</h1></div>
<p class="para">{esc(s["para"])}</p></header>
<div class="cuerpo">{aviso_html}{body}</div></main></div>
</body></html>"""


def telon(title, contenido):
    """The full backdrop — sign-in, welcome and «Listo»: the admin arrives and leaves through it,
    the same backdrop staff later see on the suite's login (BRANDING §3: nothing painted over it)."""
    return f"""<!DOCTYPE html>
<html lang="es"><head>{head(title)}</head><body>
<a class="saltar" href="#contenido">Saltar al contenido</a>
<main class="telon sobre-telon" id="contenido"><div class="pila">{LOCKUP}{contenido}
<div class="colofon"><span>AGPL-3.0-or-later · <a href="https://{REPO}" rel="noopener">{REPO}</a></span>
<span>Desarrollado por Dani Espinoza Charrier · APS Conecta</span></div></div></main>
</body></html>"""


def screen_login():
    return telon("Instalador web", """<h1 tabindex="-1">Instalador web</h1>
<p class="para grande">Abra el enlace que muestra la consola del servidor: la sesión se inicia sola.</p>
<form id="f"><label for="codigo">Código de acceso (lo que sigue a «#acceso=»)</label>
<input type="password" id="codigo" autocomplete="off" required>
<button type="submit">Entrar</button></form>
<div id="m"></div>
<script>
async function entrar(codigo) {
  const r = await api("/api/login", {token: codigo});
  if (r.estado === 200) { location.replace("/bienvenida"); return; }
  zona("m").innerHTML = '<div class="error">Código incorrecto o vencido. Use el enlace de la consola.</div>';
}
if (ACCESO) entrar(ACCESO);
zona("f").addEventListener("submit", (e) => { e.preventDefault(); entrar(zona("codigo").value); });
</script>""")


def screen_bienvenida():
    n_srv = sum(1 for x in STEPS if x["donde"] == "servidor")
    primero = STEPS[n_srv]
    return telon("Bienvenida", f"""<h1 tabindex="-1">Bienvenida</h1>
<p class="para grande">Sesión iniciada desde {esc(HOSTNAME)}. Pasos 1–{n_srv} completos; quedan
{len(STEPS) - n_srv} en este navegador.</p>
<p class="lema">{MOTTO}</p>
<div class="fila"><a class="btn btn-blanco" href="/centro">{esc(primero["titulo"])} →</a></div>""")


def installed_centre():
    """The one establishment this install serves (one install, one establishment — D13), by name;
    a generic noun when there is none or it is unreadable — centro_actual's own answer."""
    return centro_actual()[1].get("nombre") or "el establecimiento"


def screen_listo():
    dominio = dominio_actual()
    acceso = f" Acceso del personal: <b>https://{esc(dominio)}</b>." if dominio else ""
    return telon("Listo", f"""<h1 tabindex="-1">Listo</h1>
<p class="para grande">Suite instalada en {esc(installed_centre())}.{acceso}</p>
<p class="para">Instalador cerrado: enlace inválido, puerto {PORT} cerrado.</p>
<ul class="lista-sigue para"><li>Credenciales: en la consola del servidor; una fila por persona.</li>
<li>Re-provisión semanal: la activa la consola al cerrar el instalador.</li></ul>
<p class="lema">{MOTTO}</p>""")


def screen_contenedores():
    """Step 7, «Iniciar la suite» (L3 S5) — the approved design's: the five APS apps with their
    versions (a12) and Talk sized to this server (R26); then the wizard, filled by the host (domain,
    timezone, office, Talk, the daily backup) and started by the operator there (S1b: kept,
    pre-filled) with the passphrase shown here; then the containers by name, once a second (R48),
    to «Siguiente». A reload finds the step where it is."""
    body = """<section class="tarjeta"><h2>Aplicaciones</h2>
<div id="m">Consultando el servidor…</div><div id="s-apps"></div>
<p class="nota">Se activan al ejecutar, junto a Documentos, Oficina, Calendario y Contactos.</p></section>
<section class="tarjeta"><h2>Talk</h2><div id="s-talk"></div></section>
<section class="tarjeta"><h2>Asistente</h2>
<form id="s-form" hidden><label for="s-dom">Dominio del servidor</label>
<input id="s-dom" class="control" autocomplete="off" spellcheck="false" placeholder="gestion.su-establecimiento.cl">
<label class="casilla"><input type="checkbox" id="s-sinval"> Omitir la validación del dominio (servidor sin acceso desde Internet)</label>
<div class="fila"><button type="submit" id="s-ir">Preparar el asistente</button></div></form>
<div id="s-error"></div>
<ul class="lista-estado" id="s-prep" aria-live="polite"></ul>
<p class="nota" id="s-nota" hidden>La primera vez, el asistente descarga su imagen: varios minutos.</p>
<div id="s-datos" hidden></div>
<div id="s-prog" hidden><p class="progreso-linea" id="s-linea" aria-live="polite"></p>
<div class="barra" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-label="Avance del inicio"><i id="s-barra"></i></div>
<ul class="lista-estado" id="s-lista"></ul></div>
<div class="fila" id="s-sig-fila" hidden><button type="button" id="s-sig">Siguiente: equipos y personas</button></div>
</section>
<script>
(async () => {
  let reloj = null, visto = "", vistoDatos = "", aviso = "";
  const fila = (n, v, activo) => '<li class="' + (v.cabe ? "hecho" : "") + '"><span class="ic">' + (v.cabe ? "✓" : "✗") +
    "</span><span><b>" + n + ": " + (v.cabe ? "cabe" : "no cabe") + "</b> (" + escapear(v.texto) + ")" +
    (activo === undefined ? (v.cabe ? " — se activa." : " — queda desactivada.") :   // once prepared: what it was given
      activo ? " — activado." : " — desactivado.") + "</span></li>";
  const coma = (x) => String(x).replace(".", ",");
  function pintar(s) {
    zona("m").innerHTML = "";
    zona("s-apps").innerHTML = "<table><tr><th>Aplicación</th><th>Versión</th><th>Función</th></tr>" +
      s.apps.map(([n, v, q]) => "<tr><td><b>" + escapear(n) + "</b></td><td>" + escapear(v) + "</td><td>" +
        escapear(q) + "</td></tr>").join("") + "</table>";
    zona("s-talk").innerHTML = "<p>Servidor: " + coma(s.servidor.gib) + " GiB, " + s.servidor.nucleos +
      " núcleos. Suite: ~" + s.servidor.suite_gib + " GiB.</p>" + '<ul class="lista-estado">' +
      fila("Talk", s.talk, s.preparada ? s.opciones.talk : undefined) +
      fila("Grabación", s.grabacion, s.preparada ? s.opciones.grabacion : undefined) + "</ul>";
    // a suite that exists — prepared here, or already started — is followed, never prepared again
    const p = s.preparacion, hechos = new Set(p.hechos),
      sigue = s.preparada || s.en_marcha || s.contenedores.some(([, e]) => e !== "en espera");
    zona("s-form").hidden = sigue || p.estado === "en_curso";
    zona("s-ir").disabled = false;
    zona("s-error").innerHTML = (p.estado === "error" ? '<div class="error">' + escapear(p.motivo) + "</div>" : "") + aviso;
    zona("s-prep").innerHTML = p.estado === "en_curso" ? p.pasos.map((t) => '<li class="' +
      (hechos.has(t) ? "hecho" : "") + '"><span class="ic">' + (hechos.has(t) ? "✓" : "○") + "</span><span>" +
      escapear(t) + "</span></li>").join("") : "";
    zona("s-nota").hidden = p.estado !== "en_curso";
    zona("s-datos").hidden = !s.preparada;   // only what the wizard was given, never a guess
    const datos = s.preparada ? JSON.stringify([s.dominio, s.opciones, s.frase, s.asistente]) : "";
    if (datos && datos !== vistoDatos) {   // rebuilt only when it changes: a selection or a click survives the poll
      vistoDatos = datos;
      zona("s-datos").innerHTML = '<dl class="dl"><dt>Dominio</dt><dd>' + escapear(s.dominio || "—") +
        "</dd><dt>Zona horaria</dt><dd>Santiago</dd><dt>Oficina</dt><dd>Euro-Office</dd><dt>Talk</dt><dd>" +
        (s.opciones.talk ? "Activado" : "Desactivado") + "; grabación " +
        (s.opciones.grabacion ? "activada" : "desactivada") +
        "</dd><dt>Respaldo</dt><dd>Diario a las 04:00 hora de Santiago, en este servidor</dd></dl>" +
        (s.frase ? '<div class="aviso"><strong>Frase de contraseña del asistente:</strong> <span ' +
          'class="frase" translate="no">' + escapear(s.frase) + "</span><br>El asistente la pide para ingresar.</div>" +
          '<div class="fila"><a class="btn" id="s-abrir" target="_blank" rel="noopener">Abrir el asistente ' +
          'e iniciar</a><span class="nota">Nueva pestaña; el avance, aquí.</span></div>' : "");
      const abrir = document.getElementById("s-abrir");
      if (abrir) abrir.href = s.asistente;   // through the DOM: an attribute, never markup
    }
    const clave = JSON.stringify(s.contenedores) + s.instalada;
    if (sigue && clave !== visto) {
      visto = clave;
      const n = s.contenedores.length, k = s.contenedores.filter(([, e]) => e === "en marcha").length;
      zona("s-prog").hidden = false;
      zona("s-linea").textContent = s.instalada ? (k === n ? "✓ Suite en marcha: " + n + " contenedores." :
        "✓ Suite en marcha: " + k + " de " + n + " contenedores; el resto se revisa en el asistente.") :
        s.en_marcha ? "Instalando la suite…" : s.contenedores.some(([, e]) => e !== "en espera") ?
        "Contenedores en marcha: " + k + " de " + n : "Esperando «Iniciar» en el asistente: primero descarga " +
        "las imágenes (varios minutos).";
      zona("s-barra").style.setProperty("--p", k / n);
      zona("s-barra").parentNode.setAttribute("aria-valuenow", Math.round(100 * k / n));
      zona("s-lista").innerHTML = s.contenedores.map(([c, e]) => '<li class="' + (e === "en marcha" ? "hecho" :
        e === "iniciando" ? "ahora" : "") + '"><span class="ic">' + (e === "en marcha" ? "✓" : e === "iniciando" ?
        "●" : e === "detenido" ? "✗" : "○") + "</span><span>" + escapear(c) + " · " + escapear(e) + "</span></li>").join("");
    }
    zona("s-sig-fila").hidden = !s.instalada;
    return sigue;
  }
  async function seguir() {   // one short GET a second while something moves (R48)
    clearTimeout(reloj);
    const s = await api("/api/suite");
    if (s.estado !== 200) {
      zona("m").innerHTML = '<div class="error">' + escapear(s.error) + "</div>";
      reloj = setTimeout(seguir, 2000); return;
    }
    const sigue = pintar(s);
    if (s.preparacion.estado === "en_curso" || (sigue && !s.instalada)) reloj = setTimeout(seguir, 1000);
  }
  zona("s-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    zona("s-ir").disabled = true;
    aviso = "";
    const r = await api("/api/suite", {dominio: zona("s-dom").value.trim(), validar: !zona("s-sinval").checked});
    if (r.estado !== 202) {   // said, never swallowed: a bad domain, the freeze, one already going
      aviso = '<div class="' + (r.estado === 409 ? "aviso" : "error") + '">' + escapear(r.error) + "</div>";
      zona("s-error").innerHTML = aviso;
      zona("s-ir").disabled = false;
      if (r.estado === 409) seguir();   // a preparation already going is followed
      return;
    }
    seguir();
  });
  zona("s-sig").addEventListener("click", () => { location.href = "/equipos"; });
  seguir();
})();
</script>"""
    return shell("suite", body)

def screen_centro():
    """Step 6, «Elegir el centro» (L3 S2) — the approved design's Centro without its map (L5):
    Región › Comuna › Tipo filters and an accent-blind, every-term search over the whole register,
    one payload filtered in the browser; the card says what the site file will say. «Confirmar
    centro» hands the code to the server — no code rides a URL. A filter that excludes the chosen
    centre clears it: never a centre the operator did not pick."""
    body = """<div class="pila">
<div class="filtros">
<div class="campo"><label for="f-reg">Región</label><select id="f-reg" class="control"></select></div>
<div class="campo"><label for="f-com">Comuna</label><select id="f-com" class="control"></select></div>
<div class="campo"><label for="f-tipo">Tipo de centro</label><select id="f-tipo" class="control"></select></div>
</div>
<div class="campo combo"><span class="etq" id="l-centro">Centro</span>
<button type="button" class="combo-btn" id="c-btn" aria-haspopup="listbox" aria-expanded="false"
aria-labelledby="l-centro c-btn"><span><b>Cargando el registro…</b></span></button>
<div class="combo-panel" id="c-panel" hidden>
<label class="vh" for="c-q">Buscar un centro</label>
<input id="c-q" class="control" type="search" placeholder="Nombre, código DEIS, comuna o dirección…"
autocomplete="off" spellcheck="false">
<ul class="combo-lista" id="c-lista" role="listbox" aria-labelledby="l-centro"></ul>
<div class="combo-pie" id="c-pie" aria-live="polite"></div></div></div>
<dl class="dl" id="c-ficha"></dl>
<div id="m"></div>
<div class="fila"><button type="button" id="c-ok" disabled>Confirmar centro</button></div>
<p class="para nota" id="c-nota"></p></div>
<script>
(async () => {
  const $ = (s) => document.querySelector(s);
  const [d, actual] = await Promise.all([api("/api/centros"), api("/api/centro")]);
  if (d.estado !== 200) {
    $("#c-btn").innerHTML = "<span><b>Registro no disponible</b></span>";
    zona("m").innerHTML = '<div class="error">' + escapear(d.error) + "</div>"; return;
  }
  // deis.fold's twin — NFD, combining marks stripped, lower case: «ramon» finds «Ramón»
  const fold = (s) => s.normalize("NFD").replace(/[\\u0300-\\u036f]/g, "").toLowerCase();
  const miles = (n) => n.toLocaleString("es-CL");
  const CEN = d.centros.map(([c, t, n, dir, co, ss, dep]) => ({c, t, n, d: dir, co, ss, dep,
    reg: d.comunas[co][1], k: fold(n + " " + c + " " + d.tipos[t][0] + " " + d.comunas[co][0] + " " + dir)}));
  const POR = new Map(CEN.map((x) => [x.c, x]));
  const F = {reg: -1, com: -1, tipo: -1};   // R36: every type until the operator narrows it
  let elegido = null;
  const pasa = (x, ign) => (ign === "reg" || F.reg < 0 || x.reg === F.reg) &&
    (ign === "com" || F.com < 0 || x.co === F.com) && (ign === "tipo" || F.tipo < 0 || x.t === F.tipo);
  function selects() {
    const base = CEN.filter((x) => F.tipo < 0 || x.t === F.tipo);   // región counts ignore the comuna
    $("#f-reg").innerHTML = `<option value="-1">Todas las regiones (${miles(base.length)})</option>` +
      d.regiones.map((n, i) => `<option value="${i}"${i === F.reg ? " selected" : ""}>${escapear(n)} (${miles(base.filter((x) => x.reg === i).length)})</option>`).join("");
    const bc = CEN.filter((x) => pasa(x, "com"));
    $("#f-com").disabled = F.reg < 0;
    $("#f-com").innerHTML = F.reg < 0 ? '<option value="-1">Elija primero la región</option>' :
      `<option value="-1">Todas las comunas (${miles(bc.length)})</option>` +
      d.comunas.map(([n, r], i) => r === F.reg ? `<option value="${i}"${i === F.com ? " selected" : ""}>${escapear(n)} (${miles(bc.filter((x) => x.co === i).length)})</option>` : "").join("");
    const bt = CEN.filter((x) => pasa(x, "tipo"));
    $("#f-tipo").innerHTML = `<option value="-1">Todos los tipos (${miles(bt.length)})</option>` +
      d.tipos.map(([t, n], i) => { const k = bt.filter((x) => x.t === i).length;
        return `<option value="${i}"${i === F.tipo ? " selected" : ""}${k ? "" : " disabled"}>${escapear(t)} · ${escapear(n)} (${k})</option>`; }).join("");
  }
  const linea = (x) => `${escapear(d.tipos[x.t][0])} · ${escapear(d.comunas[x.co][0])} · DEIS ${escapear(x.c)}`;
  const opcion = (x) => `<li role="presentation"><button type="button" role="option" data-c="${escapear(x.c)}" aria-selected="${x.c === elegido}"><b>${escapear(x.n)}</b><small>${linea(x)}</small></button></li>`;
  function lista() {
    const qs = fold($("#c-q").value).split(/\\s+/).filter(Boolean);   // every term, like deis.matches
    const hay = (x) => qs.every((t) => x.k.includes(t));
    const dentro = CEN.filter((x) => pasa(x) && hay(x));
    const fuera = qs.join("").length >= 3 ? CEN.filter((x) => !pasa(x) && hay(x)) : [];
    const MAX = 60;
    let h = dentro.length ? dentro.slice(0, MAX).map(opcion).join("") : '<li class="combo-grupo" role="presentation">Sin resultados</li>';
    if (fuera.length) h += `<li class="combo-grupo" role="presentation">Fuera de los filtros (${fuera.length > 20 ? "20 de " : ""}${miles(fuera.length)})</li>` + fuera.slice(0, 20).map(opcion).join("");
    $("#c-lista").innerHTML = h;
    $("#c-pie").textContent = dentro.length > MAX ? `${MAX} de ${miles(dentro.length)}; filtre o busque.` :
      `${miles(dentro.length)} centro${dentro.length === 1 ? "" : "s"}.`;
  }
  function ficha() {
    const x = elegido && POR.get(elegido);
    $("#c-ok").disabled = !x;
    if (!x) {
      $("#c-btn").innerHTML = "<span><b>Elija un centro</b><small>Por región y comuna, o por nombre, código DEIS o dirección.</small></span>";
      $("#c-ficha").innerHTML = ""; return;
    }
    $("#c-btn").innerHTML = `<span><b>${escapear(x.n)}</b><small>${linea(x)}</small></span>`;
    $("#c-ficha").innerHTML = [["Tipo", d.tipos[x.t][1]], ["Código DEIS", x.c], ["Dirección", x.d],
      ["Comuna", d.comunas[x.co][0]], ["Región", d.regiones[x.reg]], ["Servicio de Salud", d.servicios[x.ss]],
      ["Dependencia", d.dependencias[x.dep]]].map(([a, b]) => `<dt>${a}</dt><dd>${escapear(b)}</dd>`).join("");
  }
  const abrir = () => { $("#c-panel").hidden = false; $("#c-btn").setAttribute("aria-expanded", "true"); lista(); $("#c-q").focus(); };
  const cerrar = () => { if ($("#c-panel").hidden) return; $("#c-panel").hidden = true; $("#c-btn").setAttribute("aria-expanded", "false"); };
  function elegir(c) {
    const x = POR.get(c); elegido = c;
    F.reg = x.reg; F.com = x.co; if (F.tipo >= 0 && F.tipo !== x.t) F.tipo = -1;
    selects(); ficha(); cerrar();
  }
  $("#c-btn").addEventListener("click", () => ($("#c-panel").hidden ? abrir() : cerrar()));
  $("#c-btn").addEventListener("keydown", (e) => { if (e.key === "ArrowDown" && $("#c-panel").hidden) { e.preventDefault(); abrir(); } });
  $("#c-q").addEventListener("input", lista);
  $("#c-q").addEventListener("keydown", (e) => {   // Enter takes the first result
    const b = e.key === "Enter" && document.querySelector("#c-lista [data-c]");
    if (b) { e.preventDefault(); elegir(b.dataset.c); $("#c-btn").focus(); }
  });
  $("#c-lista").addEventListener("click", (e) => { const b = e.target.closest("[data-c]"); if (b) { elegir(b.dataset.c); $("#c-btn").focus(); } });
  $("#c-panel").addEventListener("keydown", (e) => {
    const ops = [...document.querySelectorAll("#c-lista [data-c]")], i = ops.indexOf(document.activeElement);
    if (e.key === "Escape") { cerrar(); $("#c-btn").focus(); }
    if (e.key === "ArrowDown") { e.preventDefault(); (ops[i + 1] || ops[0])?.focus(); }
    if (e.key === "ArrowUp") { e.preventDefault(); i <= 0 ? $("#c-q").focus() : ops[i - 1].focus(); }
  });
  document.addEventListener("pointerdown", (e) => { if (!e.target.closest(".combo")) cerrar(); });
  for (const [id, k] of [["#f-reg", "reg"], ["#f-com", "com"], ["#f-tipo", "tipo"]]) $(id).addEventListener("change", (e) => {
    F[k] = +e.target.value; if (k === "reg") F.com = -1;
    if (elegido && !pasa(POR.get(elegido))) { elegido = null; ficha(); }   // never a centre nobody picked
    selects(); if (!$("#c-panel").hidden) lista();
  });
  $("#c-ok").addEventListener("click", async () => {
    if (actual.fijo) { location.href = "/contenedores"; return; }   // fixed: nothing to hand over
    $("#c-ok").disabled = true;
    const r = await api("/api/centro", {codigo: elegido});
    if (r.estado === 200) { location.href = "/contenedores"; return; }
    $("#c-ok").disabled = false;
    zona("m").innerHTML = '<div class="error">' + escapear(r.error) + "</div>";
  });
  $("#c-nota").textContent = `Registro DEIS ${d.registro}: ${miles(CEN.length)} establecimientos de atención primaria.`;
  selects(); ficha();
  if (actual.estado !== 200) {
    zona("m").innerHTML = '<div class="error">' + escapear(actual.error) + "</div>";
  } else if (actual.codigo) {
    if (POR.has(actual.codigo)) elegir(actual.codigo);
    if (actual.fijo) {   // fixed by the site file: nothing to clear, nothing to pick
      for (const s of ["#f-reg", "#f-com", "#f-tipo", "#c-btn"]) $(s).disabled = true;
      $("#c-ok").disabled = false;
      zona("m").innerHTML = '<div class="aviso">Esta instalación ya sirve a ' +
        escapear(actual.nombre) + ": una instalación, un solo establecimiento.</div>";
    }
  }
})();
</script>"""
    return shell("centro", body)


def screen_equipos():
    """Step 8, «Cargar equipos y personas» (L3 S3) — the approved design's one screen. Sectores and
    programas one per line, with the group code each derives under it (the server derives it:
    «vista», the exact ids the site will carry), saved with a visible answer (R35: the same, a
    conflict to resolve, or a replacement — never a silent 200). Then the planilla: the centre's own
    template, the upload with every error at once, the valid groups by name when one is unknown
    (R38), and the people it declares. A reload rebuilds the screen from GET /api/equipos."""
    body = """<section class="tarjeta"><h2>Sectores y programas</h2>
<p>Uno por línea. Debajo de cada lista, el código de grupo que usa la planilla.</p>
<div class="dos">
<div class="campo"><label for="e-sec">Sectores</label><textarea id="e-sec" class="control" rows="5" spellcheck="false"></textarea><div class="chips" id="e-sec-g"></div></div>
<div class="campo"><label for="e-prog">Programas</label><textarea id="e-prog" class="control" rows="5" spellcheck="false"></textarea><div class="chips" id="e-prog-g"></div></div>
</div>
<div id="e-conf" aria-live="polite"></div>
<div class="fila"><button type="button" id="e-guardar">Guardar equipos</button></div></section>
<section class="tarjeta"><h2>Planilla de personas</h2>
<p>CSV UTF-8 separado por «;», una fila por persona:
<code>usuario;nombre;apellidos;correo;grupos;primer_admin</code>. Sin contraseñas;
<b>primer_admin</b> = sí en una sola fila. Los cargos (dirección, jefaturas) se crean solos;
«Todo el personal» y la categoría de cada cargo se agregan solos.</p>
<p class="fila" id="e-plant-fila" hidden><a id="e-plant" href="/api/plantilla" download>Descargar plantilla</a>
<span class="nota">Con los grupos de este centro.</span></p>
<form id="f"><label for="archivo">Archivo CSV</label>
<input type="file" id="archivo" accept=".csv,text/csv" required>
<button type="submit" disabled>Cargar planilla</button></form>
<div id="m" aria-live="polite">Cargando los equipos…</div>
<details id="e-validos-box"><summary>Grupos válidos</summary><div id="e-validos" class="dos"></div></details>
<div id="e-tabla"></div></section>
<script>
(async () => {
  const codigo = await centro();
  if (!codigo) return;
  const lineas = (s) => s.split("\\n").map((x) => x.trim()).filter(Boolean);
  const chip = (g) => '<span class="chip" translate="no">' + escapear(g) + "</span>";
  const de = (lista, pre) => lista.filter(([g]) => g.startsWith(pre));
  let estado = {}, reloj = null, serie = 0;
  function pintarValidos() {
    const eq = estado.equipos || [];
    zona("e-validos").innerHTML = [["Sectores", de(eq, "sector-")], ["Programas", de(eq, "prog-")],
      ["Cargos", estado.cargos || []]].map(([t, l]) => '<div><h3 class="ceja">' + t + '</h3><ul class="lista-ids">' +
      (l.length ? l.map(([g, n]) => "<li>" + chip(g) + " " + escapear(n) + "</li>").join("") : "<li>—</li>") +
      "</ul></div>").join("");
    zona("e-plant-fila").hidden = !estado.guardados;
  }
  async function leer() {
    estado = await api("/api/equipos");
    if (estado.estado !== 200) {
      zona("m").innerHTML = '<div class="error">' + escapear(estado.error) + "</div>"; return false;
    }
    pintarValidos(); return true;
  }
  function vista() {   // the ids the site will carry, derived by the server as it will write them
    clearTimeout(reloj);
    reloj = setTimeout(async () => {
      const n = ++serie;
      const r = await api("/api/sitio", {codigo, sectors: lineas(zona("e-sec").value),
        programs: lineas(zona("e-prog").value), vista: true});
      if (n !== serie) return;   // a later keystroke's answer wins
      const eq = r.estado === 200 ? r.equipos : [];   // a refused list shows no ids
      zona("e-sec-g").innerHTML = de(eq, "sector-").map(([g]) => chip(g)).join("");
      zona("e-prog-g").innerHTML = de(eq, "prog-").map(([g]) => chip(g)).join("");
    }, 250);
  }
  const guardadosTexto = () => '<div class="ok">Guardados: ' + de(estado.equipos || [], "sector-").length +
    " sectores, " + de(estado.equipos || [], "prog-").length + " programas.</div>";
  function llenar() {   // the lists say what the site holds
    zona("e-sec").value = de(estado.equipos || [], "sector-").map(([, n]) => n).join("\\n");
    zona("e-prog").value = de(estado.equipos || [], "prog-").map(([, n]) => n).join("\\n");
    vista();
  }
  async function guardar(reemplazar) {
    zona("e-guardar").disabled = true;
    const r = await api("/api/sitio", {codigo, sectors: lineas(zona("e-sec").value),
      programs: lineas(zona("e-prog").value), reemplazar: reemplazar === true});
    zona("e-guardar").disabled = false;
    if (r.estado === 200) {
      if (!(await leer())) return;
      zona("e-conf").innerHTML = guardadosTexto() + (r.reemplazados ? '<div class="aviso">Equipos ' +
        "reemplazados." + (estado.planilla_cargada ? "" : " La planilla nombra equipos quitados: " +
        "cárguela de nuevo.") + "</div>" : "");
      if (r.reemplazados) pintarPlanilla();   // the old upload's table and «Siguiente» go
      return;
    }
    if (r.estado === 409 && r.nuevos) {
      zona("e-conf").innerHTML = '<div class="aviso"><strong>Distintos de los equipos guardados.</strong> ' +
        (r.nuevos.length ? "Nuevos: " + r.nuevos.map(escapear).join(", ") + ". " : "") +
        (r.quitados.length ? "Quitados: " + r.quitados.map(escapear).join(", ") + ". " : "") +
        'Sin cambios hasta elegir.<div class="fila"><button type="button" id="e-reemp">Reemplazar</button>' +
        '<button type="button" class="enlace-btn" id="e-cons">Conservar</button></div></div>';
      zona("e-reemp").onclick = () => { zona("e-reemp").disabled = true; guardar(true); };
      zona("e-cons").onclick = () => { llenar(); zona("e-conf").innerHTML = guardadosTexto(); };
      return;
    }
    zona("e-conf").innerHTML = '<div class="error">' + escapear(r.error) + "</div>";
  }
  function pintarPlanilla() {   // what the server says of the loaded planilla, after a load or a replace
    zona("m").innerHTML = estado.planilla_cargada ?
      '<div class="ok">Planilla cargada. Cárguela de nuevo para cambiarla.</div>' : "";
    zona("e-tabla").innerHTML = "";
    if (estado.planilla_cargada) siguiente();
  }
  function siguiente() {   // the handler is ATTACHED, never inlined (B-022)
    zona("m").insertAdjacentHTML("beforeend",
      '<p><button type="button" id="e-sig">Siguiente: revisar y ejecutar</button></p>');
    zona("e-sig").onclick = () => { location.href = "/revision"; };
  }
  const editar = () => { zona("e-conf").innerHTML = ""; vista(); };   // an old answer no longer applies
  zona("e-sec").addEventListener("input", editar);
  zona("e-prog").addEventListener("input", editar);
  zona("e-guardar").addEventListener("click", () => guardar(false));
  zona("archivo").addEventListener("change", (e) => {
    zona("f").querySelector("button").disabled = !e.target.files.length;
  });
  zona("f").addEventListener("submit", async (e) => {
    e.preventDefault();
    const b = zona("f").querySelector("button"); b.disabled = true;
    const {texto, aviso} = await leerPlanilla(zona("archivo").files[0]);
    const r = await api("/api/usuarios", {codigo, csv: texto});
    b.disabled = false;
    const av = aviso ? '<div class="aviso">' + aviso + "</div>" : "";
    if (r.estado === 200) {
      zona("m").innerHTML = av + '<div class="ok">Planilla válida: ' + r.usuarios +
        " personas · administración: <code>" + escapear(r.primer_admin) + "</code>. Las contraseñas " +
        "de primer ingreso quedan selladas y se entregan al final (paso 9).</div>";
      zona("e-tabla").innerHTML = "<table><tr><th>Usuario</th><th>Nombre</th><th>Grupos</th><th>Primera adm.</th></tr>" +
        r.filas.map(([u, n, g, p]) => "<tr><td>" + escapear(u) + "</td><td>" + escapear(n) + "</td><td>" +
          g.map(chip).join(" ") + "</td><td>" + (p ? "sí" : "no") + "</td></tr>").join("") + "</table>";
      zona("e-validos-box").open = false;   // the people, not the list, once it validates
      siguiente();
      return;
    }
    const errores = r.errores || [{linea: 0, error: r.error || "error inesperado"}];
    zona("m").innerHTML = av + '<div class="error">Corrija la planilla y vuelva a cargarla:</div>' +
      "<table><tr><th>Línea</th><th>Error</th></tr>" + errores.map((x) => "<tr><td>" + (x.linea || "—") +
      "</td><td>" + escapear(x.error) + "</td></tr>").join("") + "</table>";
    zona("e-tabla").innerHTML = "";
    if (r.grupos_validos) zona("e-validos-box").open = true;
  });
  if (!(await leer())) return;
  llenar();
  pintarPlanilla();
  if (estado.guardados) zona("e-conf").innerHTML = guardadosTexto();
})();
</script>"""
    return shell("equipos", body)


def screen_revision():
    """Step 9, «Revisar y ejecutar» (L3 S4) — the approved design's: the plan in clinic terms (R40):
    the centre, its sectors and programs, every person, the cargo accounts, the components (R37) and
    the maintenance; then «Ejecutar», which starts the run on the server and follows it with one short
    GET a second (a14): the steps in the console's own words, then the verdict. A reload finds the
    run where it is; green is «Listo»; red shows its head line and where the detail is (a16: the
    gate's notes stay in the console)."""
    body = """<section class="tarjeta"><h2>Plan</h2>
<div id="m">Preparando la revisión…</div>
<div id="x-plan"></div></section>
<section class="tarjeta"><h2>Ejecutar</h2>
<p>Crea los grupos, las carpetas y las cuentas, y aplica la marca: unos minutos. El avance se ve aquí
y en la consola del servidor.</p>
<div class="fila"><button type="button" id="x-ir" disabled>Ejecutar</button></div>
<div id="x-error"></div>
<div id="x-prog" hidden><p class="progreso-linea" id="x-linea" aria-live="polite"></p>
<div class="barra" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-label="Avance de la ejecución"><i id="x-barra"></i></div>
<ul class="lista-estado" id="x-lista"></ul><div id="x-fin"></div></div></section>
<script>
(async () => {
  const codigo = await centro();
  if (!codigo) return;
  const lista = (xs) => xs.length ? xs.map(escapear).join(" · ") : "—";
  const chip = (g) => '<span class="chip" translate="no">' + escapear(g) + "</span>";
  let reloj = null, planOk = false, visto = "", fallos = 0;
  function pintar(e) {   // the run as the server sees it, repainted only when it moved (one live line)
    const clave = e.ejecucion + "|" + e.hechos.join("|");
    if (clave === visto) return;
    visto = clave;
    const hechos = new Set(e.hechos), fin = e.ejecucion === "terminada";
    const ahora = fin ? -1 : e.pasos.findIndex((p) => !hechos.has(p));
    const parte = e.pasos.filter((p) => hechos.has(p)).length / e.pasos.length;
    zona("x-prog").hidden = false;
    zona("x-linea").textContent = fin ? e.veredicto.titulo : (e.pasos[ahora] || e.pasos[e.pasos.length - 1]) + "…";
    zona("x-barra").style.setProperty("--p", parte);
    zona("x-barra").parentNode.setAttribute("aria-valuenow", Math.round(100 * parte));
    zona("x-lista").innerHTML = e.pasos.map((p, i) => {
      const st = hechos.has(p) ? "hecho" : i === ahora ? "ahora" : "";
      return '<li class="' + st + '"><span class="ic">' + (st === "hecho" ? "✓" : st === "ahora" ? "●" : "○") +
        "</span><span>" + escapear(p) + "</span></li>";
    }).join("");
    zona("x-fin").innerHTML = fin && !e.veredicto.verde ? '<div class="error">El detalle y el arreglo, en la ' +
      "consola del servidor: <code>aps-conecta estado</code>. Corrija y vuelva a ejecutar.</div>" : "";
  }
  async function seguir() {   // one short GET a second (a14): no request held open
    clearTimeout(reloj);
    const e = await api("/api/ejecucion");
    if (e.estado === 0 || e.estado >= 500) {   // a dropped answer is retried; a closed installer says so
      if (++fallos >= 3) zona("x-error").innerHTML = '<div class="aviso">Sin respuesta del ' +
        "instalador. Si la ejecución terminó bien, el instalador ya se cerró: el resultado está en la " +
        "consola del servidor (<code>aps-conecta estado</code>).</div>";
      reloj = setTimeout(seguir, 2000); return;
    }
    if (e.estado !== 200) { zona("x-error").innerHTML = '<div class="error">' + escapear(e.error) + "</div>"; return; }
    if (fallos) { fallos = 0; zona("x-error").innerHTML = ""; }
    if (e.ejecucion !== "sin_ejecutar") pintar(e);
    if (e.ejecucion === "en_curso") { zona("x-ir").disabled = true; reloj = setTimeout(seguir, 1000); return; }
    if (e.ejecucion === "terminada" && e.veredicto.verde) { location.replace("/listo"); return; }
    zona("x-ir").disabled = !planOk;
    if (e.ejecucion === "terminada") zona("x-ir").textContent = "Volver a ejecutar";
  }
  zona("x-ir").addEventListener("click", async () => {
    zona("x-ir").disabled = true;
    zona("x-error").innerHTML = "";
    const r = await api("/api/generar", {codigo, modo: "ejecutar"});
    if (r.estado === 202 || r.estado === 409) {   // started, or one already going: follow it
      if (r.estado === 409) zona("x-error").innerHTML = '<div class="aviso">' + escapear(r.error) + "</div>";
      seguir(); return;
    }
    zona("x-error").innerHTML = '<div class="error">' + escapear(r.error) + "</div>";
    zona("x-ir").disabled = false;
  });
  const r = await api("/api/generar", {codigo, modo: "revision"});
  if (r.estado !== 200) {
    const errores = r.errores ? r.errores.map((x) => (x.linea ? "Línea " + x.linea + ": " : "") + x.error)
      : [r.error];
    zona("m").innerHTML = '<div class="error">' + errores.map(escapear).join("<br>") + "</div>" +
      (r.errores ? '<p><a href="/equipos">Volver a «Cargar equipos y personas»</a></p>' : "");
    seguir(); return;   // a run already going is still shown
  }
  zona("m").innerHTML = "";
  zona("x-plan").innerHTML = '<dl class="dl"><dt>Centro</dt><dd>' + escapear(r.centro.nombre) + ", " +
      escapear(r.centro.comuna) + " · DEIS " + escapear(r.centro.codigo) + "</dd>" +
    "<dt>Sectores (" + r.sectores.length + ")</dt><dd>" + lista(r.sectores) + "</dd>" +
    "<dt>Programas (" + r.programas.length + ")</dt><dd>" + lista(r.programas) + "</dd>" +
    "<dt>Cuentas de cargo</dt><dd>" + r.cuentas_de_cargo + " (dirección y jefaturas; se crean solas)</dd></dl>" +
    '<h3 class="ceja">Personas (' + r.personas.length + ")</h3><table><tr><th>Usuario</th><th>Nombre</th>" +
    "<th>Grupos</th><th>Primera adm.</th></tr>" + r.personas.map(([u, n, g, p]) => "<tr><td>" +
      escapear(u) + "</td><td>" + escapear(n) + "</td><td>" + g.map(chip).join(" ") + "</td><td>" +
      (p ? "<b>sí</b>" : "no") + "</td></tr>").join("") + "</table>" +
    '<h3 class="ceja">Componentes</h3><dl class="dl">' + r.componentes.map(([n, q]) => "<dt>" +
      escapear(n) + '</dt><dd class="normal">' + escapear(q) + "</dd>").join("") + "</dl>" +
    '<p class="nota">Mantención automática: domingo 03:00 (configuración) · día 4, 05:00 (mapa) · ' +
    "hora de Santiago.</p>";
  planOk = true;
  seguir();
})();
</script>"""
    return shell("ejecutar", body)


# The screens a signed-in browser reaches — path → renderer. A plain route table: each screen names
# its own registry step (shell(step_id, …)); the step list itself is STEPS, read from the host CLI.
ROUTES = {
    "/bienvenida": screen_bienvenida,
    "/centro": screen_centro,
    "/contenedores": screen_contenedores,
    "/equipos": screen_equipos,
    "/revision": screen_revision,
}


def contenedores():
    """(status, {name: docker status}) — the one bounded `docker ps -a` over nextcloud-aio-*: 5 s,
    read-only. A missing docker binary or a dead daemon answers a fix-hint 500, never a hang."""
    try:
        out = subprocess.run(
            ["docker", "ps", "-a", "--filter", "name=nextcloud-aio-",
             "--format", "{{.Names}}\t{{.Status}}"],  # \t: docker's template escape — real tabs out
            capture_output=True, text=True, timeout=5)
    except FileNotFoundError:
        return 500, {"error": "no se encontró el comando docker — ¿está instalado y en el PATH?"}
    except subprocess.TimeoutExpired:
        return 500, {"error": "docker no respondió en 5 s — revise el servicio con: systemctl status docker"}
    if out.returncode != 0:
        return 500, {"error": f"docker no pudo listar los contenedores: {out.stderr.strip()}"}
    tab = chr(9)  # docker's --format emits a real tab — split on it, never on the two-char escape
    return 200, dict(ln.split(tab, 1) for ln in out.stdout.splitlines() if tab in ln)


def estado_contenedor(status):
    """docker's status → the page's word: absent, starting (created, restarting, health still
    starting), up, or stopped."""
    if status is None:
        return "en espera"
    if status.startswith("Up"):
        return "iniciando" if "health: starting" in status else "en marcha"
    return "iniciando" if status.startswith(("Created", "Restarting")) else "detenido"


def recursos(meminfo="/proc/meminfo"):
    """This server's memory (GiB, one decimal) and cores — what Talk's verdict reads (R26)."""
    with open(meminfo, encoding="utf-8") as fh:
        kib = next(int(ln.split()[1]) for ln in fh if ln.startswith("MemTotal:"))
    return round(kib / 1048576, 1), os.cpu_count() or 1


def puerto_libre(puerto):
    """True when nothing holds the port Talk publishes — TCP and UDP, on every address."""
    for tipo in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        with socket.socket(socket.AF_INET, tipo) as s:
            if tipo == socket.SOCK_STREAM:   # a TIME_WAIT left by a closed connection holds nothing
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind(("0.0.0.0", puerto))
            except OSError:
                return False
    return True


def gib(x):
    return f"{x:g}".replace(".", ",") + " GiB"   # es-CL: a decimal comma


def veredicto_talk(memoria, nucleos, puerto_ok):
    """R26 — whether Talk and its recording fit this server, and why: ((cabe, texto), (cabe, texto))."""
    libre = memoria - SUITE_GIB - RESERVA_GIB
    if not puerto_ok:
        talk = (False, f"el puerto {PUERTO_TALK} está ocupado")
    elif libre >= TALK_GIB:
        talk = (True, f"~{TALK_GIB} GiB")
    else:
        talk = (False, f"requiere ~{TALK_GIB} GiB libres; quedan {gib(max(libre, 0))}")
    if not talk[0]:
        grabacion = (False, "requiere Talk")
    elif nucleos - SUITE_NUCLEOS < GRABACION_NUCLEOS:
        grabacion = (False, f"requiere {GRABACION_NUCLEOS} núcleos libres; hay {nucleos} en total")
    elif libre < TALK_GIB + GRABACION_GIB:
        grabacion = (False, f"requiere ~{TALK_GIB + GRABACION_GIB} GiB libres; quedan {gib(libre)}")
    else:
        grabacion = (True, f"~{GRABACION_GIB} GiB y {GRABACION_NUCLEOS} núcleos")
    return talk, grabacion


def apps_aps():
    """The five APS apps with their versions (a12): the catalogue's name and use, each VENDOR's version."""
    nombres = {app: (nombre, que) for app, nombre, que in COMPONENTES}
    filas = []
    for app in APPS_APS:
        with open(os.path.join(ROOT_DIR, "provisioning", "apps", app, "VENDOR"), encoding="utf-8") as fh:
            version = next((ln.split("=", 1)[1].strip() for ln in fh if ln.startswith("version=")), "")
        filas.append([nombres[app][0], version, nombres[app][1]])
    return filas


def dominio_actual():
    """The domain the wizard took (the host records it once every post succeeded): the site file's
    SITE_DOMINIO and «Listo»'s access line; "" before step 7, or for a record that is not a domain."""
    try:
        with open(os.path.join(AIO_STATE, "dominio"), encoding="utf-8") as fh:
            dominio = fh.read().strip()
    except OSError:
        return ""
    return dominio if DOMINIO.fullmatch(dominio) else ""


def opciones_actuales():
    """The Talk options the wizard was given (the host records them with the domain): (talk, grabacion),
    or None before step 7 — what the page shows and the containers it waits for."""
    try:
        with open(os.path.join(AIO_STATE, "opciones"), encoding="utf-8") as fh:
            m = re.fullmatch(r"talk=([01]) grabacion=([01])\s*", fh.read())
    except OSError:
        return None
    return (m.group(1) == "1", m.group(2) == "1") if m else None


def suite_instalada():
    """Nextcloud answers installed — one bounded `occ status`, asked only once the suite's containers run."""
    try:
        out = subprocess.run(["docker", "exec", "--user", "www-data", "nextcloud-aio-nextcloud", "php",
                              "/var/www/html/occ", "status", "--output=json"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return '"installed":true' in out.stdout.replace(" ", "")


def talk_ahora(vistos):
    """Talk's verdict now (R26). The port is probed unless the wizard was given Talk: then its own proxy
    holds 3478 and a probe could race it."""
    memoria, nucleos = recursos()
    opciones = opciones_actuales()
    libre = ("nextcloud-aio-talk" in vistos or (opciones is not None and opciones[0])
             or puerto_libre(PUERTO_TALK))
    return veredicto_talk(memoria, nucleos, libre)


def estado_suite():
    """GET /api/suite — step 7 as the server sees it: the server's size and Talk's verdict (R26), the
    five apps (a12), the wizard's preparation, then the suite's containers (R48). The passphrase is
    served while it is needed: prepared, not yet installed."""
    st, vistos = contenedores()
    if st != 200:
        return st, vistos
    memoria, nucleos = recursos()
    talk, grabacion = talk_ahora(vistos)
    opciones = opciones_actuales()
    con_talk, con_grabacion = opciones if opciones else (talk[0], grabacion[0])
    base = [[nombre, estado_contenedor(vistos.get(c))] for c, nombre in CONTENEDORES_SUITE]
    extra = [[nombre, estado_contenedor(vistos.get(c))]
             for (c, nombre), si in zip(CONTENEDORES_TALK, (con_talk, con_grabacion)) if si]
    en_marcha = all(e == "en marcha" for _n, e in base)
    instalada = en_marcha and suite_instalada()
    frase = ""
    if opciones is not None and not instalada:
        try:
            with open(os.path.join(AIO_STATE, "master.pw"), encoding="utf-8") as fh:
                frase = fh.read().strip()
        except OSError:
            pass
    s = dict(SUITE)
    return 200, {"servidor": {"gib": memoria, "nucleos": nucleos, "suite_gib": SUITE_GIB},
                 "talk": {"cabe": talk[0], "texto": talk[1]},
                 "grabacion": {"cabe": grabacion[0], "texto": grabacion[1]},
                 "apps": apps_aps(), "dominio": dominio_actual(), "preparada": opciones is not None,
                 "opciones": {"talk": con_talk, "grabacion": con_grabacion},
                 "preparacion": {"estado": s["estado"], "hechos": list(s["hechos"]), "motivo": s["motivo"],
                                 "pasos": [t for _p, t in PASOS_SUITE]},
                 "frase": frase, "asistente": f"https://{LAN_IP}:8080",
                 "contenedores": base + extra, "en_marcha": en_marcha, "instalada": instalada}


def iniciar_suite(payload):
    """POST /api/suite {"dominio", "validar"} — the host fills the wizard on a worker (a minute; more
    when the wizard's image is new) and the page follows it: Talk and its recording as the server
    allows (R26), the daily backup at 04:00 Santiago time with the installer's own files in its scope (R24)."""
    dominio = payload.get("dominio")
    if not isinstance(dominio, str) or not DOMINIO.fullmatch(dominio) or "." not in dominio:
        return 400, {"error": "escriba el dominio del servidor, por ejemplo gestion.su-establecimiento.cl"}
    if re.fullmatch(r"[0-9.]+", dominio):
        return 400, {"error": "use un nombre de dominio, no una dirección IP"}
    st, vistos = contenedores()
    if st != 200:
        return st, vistos
    talk, grabacion = talk_ahora(vistos)
    argv = (SUITE_CMD + ["--dominio", dominio, "--respaldo", RESPALDO_DIR]
            + (["--talk"] if talk[0] else []) + (["--grabacion"] if grabacion[0] else [])
            + ([] if payload.get("validar") is not False else ["--sin-validar-dominio"]))
    with SUITE_GUARD:
        if SUITE["estado"] == "en_curso":
            return 409, {"error": "el asistente ya se está preparando — espere a que termine"}
        SUITE.update(estado="en_curso", hechos=[], motivo="")
        try:   # a reason left by an earlier run is not this run's
            os.remove(os.path.join(AIO_STATE, "motivo"))
        except OSError:
            pass
        try:
            threading.Thread(target=preparar_suite, args=(argv,), daemon=True).start()
        except RuntimeError as e:   # no thread to run it on: nothing started
            SUITE.update(estado="sin_preparar")
            return 500, {"error": f"no se pudo preparar el asistente ({e})"}
    return 202, {"ok": True}


def preparar_suite(argv):
    """The worker: the host's own wizard drive (its state where this server reads it), its ✓ lines
    turned into the page's steps; a refusal's reason is the host's one-line record (no path)."""
    def show(line):
        for prefijos, titulo in PASOS_SUITE:
            if line.startswith(prefijos) and titulo not in SUITE["hechos"]:
                SUITE["hechos"].append(titulo)
        return line
    try:
        rc, _salida = run_tee(argv, cwd=ROOT_DIR, timeout=TIMEOUTS["suite"],
                              env={**os.environ, "AIO_STATE": AIO_STATE}, show=show)
    except Exception as e:   # never a silent dead worker
        print(f"  ✗ la preparación del asistente se detuvo: {type(e).__name__}: {e}", file=sys.stderr)
        rc = 1
    if rc == 0:
        try:
            fijar_dominio()
        finally:
            SUITE.update(estado="lista")
        return
    try:
        with open(os.path.join(AIO_STATE, "motivo"), encoding="utf-8") as fh:
            motivo = fh.readline().strip()
    except OSError:
        motivo = ""
    if rc is None:
        motivo = (f"La preparación tardó más de {TIMEOUTS['suite'] // 60} minutos: vuelva a intentarlo "
                  "(el asistente puede seguir arrancando).")
    SUITE.update(estado="error", motivo=motivo or "El asistente no quedó listo: el detalle, en la consola del servidor.")


def fijar_dominio():
    """A site written before step 7 (the operator came back to it) takes the domain the wizard took —
    the host's record, never the browser's word: its empty SITE_DOMINIO line, and only that line."""
    dominio, codigo = dominio_actual(), centro_actual()[1].get("codigo")
    if not dominio or not codigo:
        return
    path = site_path(codigo)
    with SITE_LOCK:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            return
        if text.count('\nSITE_DOMINIO=""\n') == 1:
            write_site_text(path, text.replace('\nSITE_DOMINIO=""\n', f'\nSITE_DOMINIO="{dominio}"\n'))

class Handler(BaseHTTPRequestHandler):
    # Keep-alive: the UI fetches per interaction; every response goes through send_json, the one
    # place Content-Length is set — HTTP/1.1 framing stays honest by construction.
    protocol_version = "HTTP/1.1"
    # A client that opens a connection and stalls must not park a thread forever: the socket read
    # times out and the thread is reclaimed (FINDINGS #10).
    timeout = 30
    server_version = "APS-Conecta-Provisionador"  # no product leak beyond our own name
    sys_version = ""                              # version_string() would append Python's

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            self.redirect("/login")   # R33: the address opens the sign-in page, never JSON
            return
        if path == "/api/salud":
            # Unauthenticated on purpose: the host's probe (check_prov_ports) and a second installer's
            # start need to tell this service from a stranger without a token. Nothing secret rides
            # this — the register's date and size, no establishment data.
            self.send_json(200, {"servicio": SERVICE, "estado": "listo",
                                 "registro": SNAPSHOT, "establecimientos": len(ROWS)})
            return
        if path.startswith("/recursos/"):
            # Public on purpose: the sign-in page needs the fonts. Whitelisted names only.
            asset = ASSETS.get(path[len("/recursos/"):])
            data = None
            if asset is not None:
                try:
                    with open(os.path.join(ROOT_DIR, asset[0]), "rb") as fh:
                        data = fh.read()
                except OSError:
                    pass
            if data is None:
                self.send_json(404, {"error": "recurso desconocido"})
                return
            self.send_bytes(200, asset[1], data, {"Cache-Control": "max-age=86400"})
            return
        if path == "/login":
            if self.authorized():
                self.redirect("/bienvenida")
            else:
                self.send_html(screen_login())
            return
        if path == "/api/plantilla":   # a file to save, not JSON
            if not self.authorized():
                self.send_json(401, {"error": "token ausente o inválido"},
                               {"WWW-Authenticate": "Bearer"})
                return
            status, body = plantilla()
            if status != 200:
                self.send_json(status, body)
                return
            self.send_bytes(200, "text/csv; charset=utf-8", body["csv"].encode("utf-8"),
                            {"Content-Disposition": f'attachment; filename="{body["nombre"]}"'})
            return
        if path in ("/api/suite", "/api/centros", "/api/centro", "/api/equipos", "/api/ejecucion"):
            if not self.authorized():
                self.send_json(401, {"error": "token ausente o inválido"},
                               {"WWW-Authenticate": "Bearer"})
                return
            if path == "/api/suite":
                status, body = estado_suite()
            elif path == "/api/centros":
                status, body = api_centros()
            elif path == "/api/centro":
                status, body = centro_actual()
            elif path == "/api/ejecucion":
                status, body = estado_ejecucion()
            else:
                status, body = equipos_actuales()
            self.send_json(status, body, {"Cache-Control": "no-store"} if path == "/api/suite" else None)
            return
        if path in ROUTES or path == "/listo":
            if not self.authorized():
                # A human gets redirected to the door; an API gets JSON — the split is by route
                # shape (screen routes are the UI, /api routes answer JSON), not by header sniff.
                self.redirect("/login")
            elif path == "/listo" and not DONE.is_set():
                self.redirect("/bienvenida")   # «Listo» exists only after a green execution
            else:
                self.send_html(screen_listo() if path == "/listo" else ROUTES[path]())
            return
        self.send_json(404, {"error": "ruta desconocida"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/login":
            # The ONE pre-auth POST: the login form's (or the link's) code. Same constant-time compare
            # as authorized(); success sets the HttpOnly, SameSite=Strict, Secure cookie (HTTPS, L3 S1)
            # and the response never echoes the token.
            try:
                payload = self.read_json()
            except ClientError as e:
                self.close_connection = True  # same framing rule: 413 never drained its body
                self.send_json(e.status, {"error": str(e)})
                return
            token = payload.get("token")
            if (not isinstance(token, str)
                    or not hmac.compare_digest(token.encode(), TOKEN.encode())):
                self.send_json(401, {"error": "token incorrecto"})
                return
            cookie = (f"{TOKEN_COOKIE}={TOKEN}; Path=/; HttpOnly; Secure; SameSite=Strict; "
                      "Max-Age=43200")
            self.send_json(200, {"ok": True}, {"Set-Cookie": cookie})
            return
        if not self.authorized():
            # Answered before the body was drained: with keep-alive the unread bytes would be
            # parsed as the next request line, so this connection closes instead.
            self.close_connection = True
            self.send_json(401, {"error": "token ausente o inválido"},
                           {"WWW-Authenticate": "Bearer"})
            return
        try:
            payload = self.read_json()
        except ClientError as e:
            self.close_connection = True  # same framing rule: 413 never drained its body
            self.send_json(e.status, {"error": str(e)})
            return
        # «vista» is /api/sitio's read-only preview: on any other path it changes nothing, so it
        # exempts nothing from the freezes below
        cambia = (path in ("/api/generar", "/api/centro", "/api/sitio", "/api/usuarios", "/api/suite")
                  and not (path == "/api/sitio" and payload.get("vista") is True))
        if cambia and DONE.is_set():
            # SEC-2: the installer is done and closing — a reload and a second click inside the grace
            # must neither start a run the shutdown would cut nor change what the run just verified
            self.send_json(409, {"error": "la instalación ya terminó: el instalador se está cerrando"})
            return
        if (cambia and path != "/api/generar"
                and (EXEC_LOCK.locked() or EJECUCION["estado"] == "en_curso")):
            # the centre, the teams and the planilla are the run's input: never changed under it
            self.send_json(409, {"error": "hay una ejecución en curso: espere a que termine"})
            return
        if path == "/api/centro":
            status, body = api_centro(payload)
        elif path == "/api/sitio":
            status, body = api_sitio(payload)
        elif path == "/api/usuarios":
            status, body = api_usuarios(payload)
        elif path == "/api/suite":
            status, body = iniciar_suite(payload)
        elif path == "/api/generar" and payload.get("modo") == "ejecutar":
            status, body = iniciar_ejecucion(payload, self.server)
        elif path == "/api/generar":
            status, body = api_generar(payload)
        else:
            status, body = 404, {"error": "ruta desconocida"}
        self.send_json(status, body)

    def authorized(self):
        # Constant-time: this is a bearer credential, and compare_digest is the stdlib's answer to
        # timing oracles. TWO arms (slice 17): the Bearer header serves API calls and the
        # self-test; the login cookie serves the screens. The cookie's VALUE is the token
        # itself — the server keeps no session (no store to drift or crash), so the credential is
        # the state.
        h = self.headers.get("Authorization", "")
        if h.startswith("Bearer ") and hmac.compare_digest(h[7:].encode(), TOKEN.encode()):
            return True
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == TOKEN_COOKIE and hmac.compare_digest(v.encode(), TOKEN.encode()):
                return True
        return False

    def read_json(self):
        try:
            n = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise ClientError(400, "cabecera Content-Length ausente o inválida")
        if n <= 0:
            raise ClientError(400, "el cuerpo JSON está ausente")
        if n > MAX_BODY:
            raise ClientError(413, f"el cuerpo supera el máximo de {MAX_BODY} bytes")
        data = self.rfile.read(n)
        try:
            payload = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ClientError(400, "el cuerpo debe ser JSON codificado en UTF-8")
        if not isinstance(payload, dict):
            raise ClientError(400, "el cuerpo debe ser un objeto JSON")
        return payload

    def send_bytes(self, status, ctype, data, headers=None):
        # Every response's single exit: the one place Content-Length is set — HTTP/1.1 framing stays
        # honest by construction (keep-alive).
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, status, obj, headers=None):
        self.send_bytes(status, "application/json; charset=utf-8",
                        (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"), headers)

    def send_html(self, page):
        # the es-CL copy carries accents: the charset is declared
        self.send_bytes(200, "text/html; charset=utf-8", page.encode("utf-8"))

    def redirect(self, where):
        self.send_bytes(302, "text/plain; charset=utf-8", b"", {"Location": where})

    def log_message(self, fmt, *args):
        # R42: the console is the operator's — no request lines, and no «Request timed out» trace
        # (stdlib routes both through here). Errors that matter answer the browser in Spanish.
        pass


class Server(ThreadingHTTPServer):
    """The installer's server. Quiet (R42): a failed TLS handshake or a dropped socket is not the
    operator's business — every answer that matters reaches the browser in Spanish. Finished once
    (SEC-2, a13): a green «Revisar y ejecutar» schedules the shutdown that closes the port and with
    it the link; the grace lets the result page load first."""
    grace = 30   # seconds; a13 wants the port closed within a minute of the success

    def handle_error(self, request, client_address):
        pass

    def close_after_success(self):
        DONE.set()
        t = threading.Timer(self.grace, self.shutdown)
        t.daemon = True
        t.start()


def bind_server(host, ports):
    """Try the named ports in order, then port 0 — the OS assigns one. A busy port is a
    fall-through, never an error: the banner prints whatever actually bound, so the operator never
    needs to know 8081 was taken. Only a full failure — not even port 0 — exits non-zero, with the
    fix hint (FRD S5)."""
    err = None
    for port in (*ports, 0):
        try:
            httpd = Server((host, port), Handler)
            return httpd, httpd.server_address[1]
        except OSError as e:
            err = e
    sys.exit(f"FATAL: no se puede escuchar en {host}: probados {', '.join(map(str, ports))} y un "
             f"puerto asignado por el sistema — {err}\n"
             f"Vea qué puertos están ocupados con:  ss -ltn")


def lan_ip():
    """The address other machines on the LAN reach this host by: the source address of the default
    route, asked of the kernel with a UDP connect (no packet leaves). Loopback when there is none."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.0.2.1", 9))   # TEST-NET-1: a route lookup, never a destination
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def openssl(*args):
    """One openssl call; any failure stops the start before a socket opens, with the fix."""
    try:
        r = subprocess.run(["openssl", *args], capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        sys.exit("✗ falta openssl: el instalador web firma su propio certificado\n"
                 "  → sudo apt-get install openssl")
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.exit(f"✗ openssl no respondió: {e}")
    if r.returncode != 0:
        sys.exit(f"✗ openssl no pudo crear el certificado: {r.stderr.strip()[-300:]}")
    return r.stdout


def tls_context(ip):
    """HTTPS with the installer's own certificate (a13: no code, no cookie crosses the LAN in clear).
    The CA is made once and kept; the leaf is re-signed on every start for the address the link
    names (and loopback): P-256, 825 days (Apple's ceiling for TLS server certificates). Returns the
    server context and the leaf's SHA-256 fingerprint for the banner."""
    ca_crt, ca_key, crt, key = (os.path.join(CERT_DIR, n) for n in
                                ("ca.crt", "ca.key", "instalador.crt", "instalador.key"))
    ec = ("-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes")
    mayor = re.match(r"OpenSSL (\d+)\.", openssl("version"))   # `req -x509 -CA` is OpenSSL 3
    if not mayor or int(mayor.group(1)) < 3:
        sys.exit("✗ el instalador web necesita OpenSSL 3 o más reciente (Ubuntu 22.04+, Debian 12+)\n"
                 "  → actualice el sistema operativo del servidor")
    try:
        os.makedirs(CERT_DIR, mode=0o700, exist_ok=True)
        os.chmod(CERT_DIR, 0o700)       # an existing directory keeps the private keys' parent closed too
        if not (os.path.exists(ca_crt) and os.path.exists(ca_key)):
            openssl("req", "-x509", *ec, "-keyout", ca_key, "-out", ca_crt, "-days", "3650",
                    "-subj", f"/O=APS Conecta/CN=APS Conecta {socket.gethostname()}",
                    "-addext", "basicConstraints=critical,CA:TRUE",
                    "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        san = ",".join(f"IP:{a}" for a in dict.fromkeys((ip, "127.0.0.1")))
        openssl("req", "-x509", *ec, "-keyout", key, "-out", crt, "-days", "825",
                "-subj", f"/CN={ip}", "-CA", ca_crt, "-CAkey", ca_key,
                "-addext", f"subjectAltName={san}",
                "-addext", "basicConstraints=critical,CA:FALSE",
                "-addext", "extendedKeyUsage=serverAuth")
        for k in (ca_key, key):
            os.chmod(k, 0o600)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
    except OSError as e:
        sys.exit(f"✗ no se pudo preparar el certificado en {CERT_DIR}: {e.strerror or e}\n"
                 "  → ejecute con permisos de administrador: sudo aps-conecta abrir")
    return ctx, huella(crt)


def huella(crt):
    """A certificate's SHA-256 fingerprint, AA:BB:… — what the browser's warning shows."""
    with open(crt, encoding="ascii") as fh:
        h = hashlib.sha256(ssl.PEM_cert_to_DER_cert(fh.read())).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


def running_installer(ports=PORTS):
    """The port of an installer already serving on this host, or None (R33): two would print two
    links and two codes — the second refuses instead. Identity, not trust: the certificate is not
    checked, the answer's servicio is."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    for p in ports:
        try:
            with urllib.request.urlopen(f"https://127.0.0.1:{p}/api/salud", context=ctx,
                                        timeout=2) as r:
                answer = json.loads(r.read().decode("utf-8"))
                if isinstance(answer, dict) and answer.get("servicio") == SERVICE:
                    return p
        except (OSError, ValueError, http.client.HTTPException):
            continue
    return None


def banner(url, huella_hex):
    """The console's one link (R32, a13): the code rides the fragment; the fingerprint is what the
    browser's certificate warning shows."""
    print("  Abrir en otro equipo de la red:")
    print()
    print(f"      {url}")
    print()
    print("  Sesión iniciada al abrir. Válido hasta terminar la instalación.")
    print(f"  Certificado propio. Huella SHA-256: {huella_hex}")
    print("  No cerrar esta ventana hasta «Listo».")
    print()
    print("Resultado esperando el navegador…")


def serve(httpd):
    """Serve until the installer is done (0), Ctrl+C (130), or anything else (1) — the exit code
    `aps-conecta abrir` reads to wire the timers and print «Listo»."""
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print()   # ends the ^C line; the console says the rest
        # Ctrl+C inside the grace after a green run (the browser already says «Listo»): still done
        return 0 if DONE.is_set() else 130
    finally:
        httpd.server_close()
    return 0 if DONE.is_set() else 1


def run_step(argv):
    """`--paso sitio --archivo FILE` · `--paso usuarios --codigo C --planilla FILE` ·
    `--paso generar --codigo C [--revision] [--resumen]` — the
    installer's steps in this process, with no server: the same api_* functions the browser posts
    to (one home per step, S1b). The weekly re-provision and the silent install call them. Prints
    Spanish ✓/✗ lines; exit 0 done · 1 refused (the reason printed) · 2 usage."""
    opts, i = {}, 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--paso", "--codigo", "--planilla", "--archivo"):
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                print(f"✗ falta el valor de {arg}")
                return 2
            opts[arg] = argv[i + 1]
            i += 2
        elif arg in ("--revision", "--resumen"):
            opts[arg] = True
            i += 1
        else:
            print(f"✗ opción desconocida: {arg} — uso: provisionador.py --paso sitio|usuarios|generar "
                  "[--archivo <site.sh>] [--codigo <código>] [--planilla <archivo.csv>] [--revision] "
                  "[--resumen]")
            return 2
    step, code = opts.get("--paso"), opts.get("--codigo")
    takes = {"sitio": {"--archivo"}, "usuarios": {"--codigo", "--planilla"},
             "generar": {"--codigo", "--revision", "--resumen"}}
    if step not in takes:
        print("✗ paso desconocido — use --paso sitio, usuarios o generar")
        return 2
    if not code and step != "sitio":  # the site file names its own centre
        print("✗ falta el código: --codigo <código>")
        return 2
    extra = set(opts) - {"--paso"} - takes[step]
    if extra:
        print(f"✗ {' '.join(sorted(extra))} no aplica a --paso {step}")
        return 2

    def call(fn, payload):  # a file error is a Spanish ✗ line, not a traceback in the journal
        try:
            return fn(payload)
        except OSError as e:
            return 500, {"error": f"no se pudo acceder a {e.filename or 'un archivo'} ({why(e)})"}
        except UnicodeDecodeError:
            return 500, {"error": "un archivo del establecimiento o el .env no está en UTF-8"}

    def refused(status, body):
        for err in body.get("errores", []):   # a whole-file error (line 0) has no line to name
            linea = f"línea {err['linea']}: " if err["linea"] else ""
            print(f"✗ {linea}{err['error']}")
        if body.get("grupos_validos"):
            print("  grupos válidos: " + " ".join(body["grupos_validos"]))
        if "error" in body or not body.get("errores"):
            print(f"✗ {body.get('error', f'el paso falló (código {status})')}")
        return 1

    if step == "sitio":
        path = opts.get("--archivo")
        if not path:
            print("✗ falta el sitio: --archivo <site.sh>")
            return 2
        try:
            with open(path, encoding="utf-8-sig") as fh:
                text = fh.read()
        except OSError as e:
            print(f"✗ no se pudo leer el sitio {path}: {why(e)}")
            return 1
        except UnicodeDecodeError:
            print(f"✗ el sitio {path} no está en UTF-8")
            return 1
        status, body = call(site_import, {"texto": text})
        if status != 200:
            return refused(status, body)
        print(f"✓ Sitio {'ya cargado' if body.get('already') else 'cargado'}: {body['site']} "
              f"(DEIS {body['codigo']})")
        return 0
    if step == "usuarios":
        path = opts.get("--planilla")
        if not path:
            print("✗ falta la planilla: --planilla <archivo.csv>")
            return 2
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as e:
            print(f"✗ no se pudo leer la planilla {path}: {why(e)}")
            return 1
        except UnicodeDecodeError:
            print(f"✗ la planilla {path} no está en UTF-8")
            return 1
        status, body = call(api_usuarios, {"codigo": code, "csv": text})
        if status != 200:
            return refused(status, body)
        print(f"✓ Planilla validada: {body['usuarios']} usuarios; administrador inicial "
              f"{body['primer_admin']}")
        print(f"✓ Contraseñas selladas en {body['credenciales']}: {body['contrasenas_nuevas']} "
              "nuevas (personas y cargos)")
        return 0
    mode = "revision" if opts.get("--revision") else "ejecutar"
    resumen = bool(opts.get("--resumen"))
    log = os.path.normpath(os.path.join(deis.HERE, "..", ".install.log"))
    status, body = call(api_generar, {"codigo": code, "modo": mode, "resumen": resumen})
    if status != 200:
        if resumen and "salida" in body:  # the executor ran: its whole output is in the log
            print(f"  registro completo: {log}")
        return refused(status, body)
    if mode == "revision":
        print(f"✓ Revisión: {len(body['fases'])} fases, {body['usuarios']} usuarios "
              f"(administrador inicial {body['primer_admin']}); no se ejecutó nada")
        return 0
    if body["divergencia_vacia"]:
        print("✓ divergencia vacía — la instalación coincide con lo declarado")
        return 0
    print(f"✗ divergencia NO vacía — la deriva se muestra {f'en el registro ({log})' if resumen else 'arriba'}; "
          "«sudo aps-conecta abrir» abre el instalador web para corregir")
    return 1


def selftest():
    """The FRD's named self-tests for this slice's surfaces, run against a throwaway tree: the
    register fixture redirects deis.HERE (load() and write_site() both read it at call time), so the
    real sites/ is never touched. The HTTP checks are real round-trips against a real server on an
    OS-assigned port — urllib, no frameworks. Every check is named and counted; a failure prints the
    list and exits 1 (B-014: a gate that cannot go red is not a gate)."""
    global TOKEN, SNAPSHOT, ROWS, CRED_PATH, PHASE20, ESTADO_PATH, CERT_DIR, LAN_IP, HOSTNAME, PORT, CENTRO, AIO_STATE
    n = 0
    bad = []

    def check(name, cond):
        nonlocal n
        n += 1
        print(("  ok:   " if cond else "  FAIL: ") + f"{n:2}. {name}")
        if not cond:
            bad.append(name)

    def seed_died(body, name):
        # B-028: a dead seed aborts WITH ITS OWN OUTPUT. Every later arm dereferences keys a
        # 500 does not carry (the banner slice, body["env"], body["divergencia"]), so
        # continuing past a dead seed trades the FATAL line for a bare ValueError/KeyError —
        # the exact traceback B-028 was filed on. This is the "capture the sandbox seed's own
        # output" the row asked for, standing between generar() and the banner-dependent arms.
        print("---- generar: the seed died — its own output (last 25 lines) ----")
        print("\n".join((body.get("salida") or "").splitlines()[-25:]))
        print(f"---- api error: {body.get('error', '(no error field)')}")
        check(name, False)
        print(f"\nself-test: {len(bad)} de {n} checks fallaron:")
        for _name in bad:
            print(f"  FAIL: {_name}")
        return 1

    old = deis.HERE
    old_cred, old_p20 = CRED_PATH, PHASE20
    old_cert = CERT_DIR
    old_aio = AIO_STATE
    reales = (recursos, puerto_libre)
    # The stub world must not inherit the caller's exported seed knobs (P37, measured under
    # make test on the probe: a prior section's `source env.sh` leaves OFFICE_* exported and
    # env.sh never unsets, so the compose arm's clean fixture .env could not make the OFFICE_PORT
    # gate fire). Scrub the prefixes the phases read; restore in the finally.
    _scrub = tuple(("OFFICE_", "SITE_", "SEED_", "FIXTURE_", "NC_", "APS_", "TILES_", "HTTP_",
                    "APACHE_", "NEXTCLOUD_", "COMPOSE_", "IV_"))
    _scrubbed = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith(_scrub)}
    # The fixture reuses the register's real hostile shapes, measured from the shipped register
    # (2026-07-23): 201079's name holds double quotes, 113314's address holds a backtick, 121567
    # carries accents — the exact rows scripts/test.sh's quoting gate exists for. Plain 110485 is
    # the happy-path row.
    fixture_rows = [
        '110485,PSR,Posta de Salud Rural Loica,Calle Aldea Loica,13505,San Pedro,13,'
        'Metropolitana de Santiago,Servicio de Salud Metropolitano Occidente,Municipal',
        '201079,SAPU,"SAPU ""Dr. Juan Lozic Perez""",Calle Javiera Carrera,12401,Natales,12,'
        'Magallanes y de la Antártica Chilena,Servicio de Salud Magallanes,Municipal',
        '113314,CESFAM,Centro de Salud Familiar Cóndores de Chile,Calle Agusto D`Almar 555,13105,'
        'El Bosque,13,Metropolitana de Santiago,Servicio de Salud Metropolitano Sur,Municipal',
        '121567,PSR,Posta de Salud Rural San Ramón,Calle Caserío de San Ramón,09112,'
        'Padre Las Casas,09,La Araucanía,Servicio de Salud Araucanía Sur,Municipal',
    ]
    fixture_header = ("codigo,tipo,nombre,direccion,comuna_codigo,comuna,region_codigo,region,"
                      "servicio_salud,dependencia")
    try:
        with tempfile.TemporaryDirectory() as tmp:
            # — fail fast: no register, no wizard, no socket
            deis.HERE = os.path.join(tmp, "empty")
            os.makedirs(deis.HERE)
            try:
                load_register()
                check("a missing register fails fast with a fix hint", False)
            except SystemExit as e:
                check("a missing register fails fast with a fix hint",
                      "establecimientos-deis" in str(e))

            deis.HERE = os.path.join(tmp, "scripts")
            os.makedirs(deis.HERE)
            os.makedirs(os.path.join(tmp, "sites"))
            with open(os.path.join(tmp, "sites", "establecimientos-deis-2099-99-99.csv"),
                      "w", encoding="utf-8") as fh:
                fh.write(fixture_header + "\n" + "\n".join(fixture_rows) + "\n")
            load_register()
            check("the register loads from the fixture",
                  SNAPSHOT == "2099-99-99" and len(ROWS) == 4)

            # — the codigo whitelist: the FRD's slug guard, and the path-traversal guard
            check("whitelist accepts a 6-digit codigo", bool(CODIGO.fullmatch("110485")))
            check("whitelist rejects traversal, length and junk",
                  not CODIGO.fullmatch("../etc") and not CODIGO.fullmatch("110485/x")
                  and not CODIGO.fullmatch("1104857") and not CODIGO.fullmatch("11a302")
                  and not CODIGO.fullmatch("") and not CODIGO.fullmatch("-1"))

            # — ask()'s triple construction, replicated (a drift is a divergence event)
            check("triples: variants converge, empties drop",
                  team_lines("sector", "sector-", ["Sector Estrella", "SECTOR estrella", ""])
                  == [("sector-estrella", "Sector Estrella", "Estrella")])
            check("triples: programs carry the prog- prefix",
                  team_lines("programa", "prog-", ["Programa Salud Mental"])
                  == [("prog-salud-mental", "Programa Salud Mental", "Salud Mental")])
            try:
                team_lines("sector", "sector-", [13])
                check("triples: non-string names refused (unit)", False)
            except ValueError:
                check("triples: non-string names refused (unit)", True)

            # — dynamic bind: the FRD's ":8081 pre-occupied" arm. Occupying the first port of the
            # tried list and asserting the server lands elsewhere is the same mechanism, without
            # coupling the test to the literal port (a dev box may legitimately hold 8081).
            with socket.socket() as busy:
                busy.bind(("127.0.0.1", 0))
                busy.listen(1)
                taken = busy.getsockname()[1]
                httpd, got = bind_server("127.0.0.1", (taken,))
                check("bind falls back past an occupied port", got != taken and got > 0)
                httpd.server_close()
            try:
                bind_server("host.invalid.aps-conecta", PORTS)
                check("bind failure exits non-zero with the fix hint", False)
            except SystemExit as e:
                check("bind failure exits non-zero with the fix hint", "ss -ltn" in str(e))

            # — the banner: one link with the code in its fragment (R32, a13)
            buf = io.StringIO()
            with redirect_stdout(buf):
                banner("https://192.0.2.10:8081/login#acceso=tok-selftest", "AB:" * 31 + "CD")
            text = buf.getvalue()
            check("banner: one link with the code in the fragment, the fingerprint, «Listo» as the end — no token line to copy",
                  text.count("https://") == 1 and "https://192.0.2.10:8081/login#acceso=tok-selftest" in text
                  and "Huella SHA-256: " + "AB:" * 31 + "CD" in text
                  and "No cerrar esta ventana hasta «Listo»." in text
                  and "Token" not in text and "127.0.0.1" not in text)

            # — one real server, one real port, real requests: the auth gate and both endpoints
            TOKEN = secrets.token_hex(32)
            httpd, port = bind_server("127.0.0.1", (0,))
            threading.Thread(target=httpd.serve_forever, daemon=True).start()
            base = f"http://127.0.0.1:{port}"

            def call(method, path, obj=None, token=TOKEN):
                req = urllib.request.Request(
                    base + path, method=method,
                    data=json.dumps(obj).encode() if obj is not None else None,
                    headers={"Content-Type": "application/json",
                             **({"Authorization": f"Bearer {token}"} if token else {})})
                try:
                    with urllib.request.urlopen(req, timeout=10) as r:
                        return r.status, json.loads(r.read().decode())
                except urllib.error.HTTPError as e:
                    return e.code, json.loads(e.read().decode())

            st, body = call("GET", "/api/salud", token=None)
            check("GET /api/salud names the service, no token needed (R33)",
                  st == 200 and body["servicio"] == SERVICE and body["registro"] == "2099-99-99"
                  and body["establecimientos"] == 4)
            st, _ = call("POST", "/api/centro", {"codigo": "110485"}, token=None)
            check("POST without a token is refused 401", st == 401)
            st, _ = call("POST", "/api/centro", {"codigo": "110485"}, token="0" * 64)
            check("POST with a wrong token is refused 401", st == 401)
            st, _ = call("POST", "/api/deis", {"q": "loica"})
            check("centro: the free-text search endpoint is gone — the screen filters one payload (L3 S2)",
                  st == 404 and "api_deis" not in globals())
            st, _ = call("POST", "/api/ruta-inexistente", {})
            check("unknown routes answer 404", st == 404)
            st, _ = call("GET", "/api/centros", token=None)
            st2, _ = call("GET", "/api/centro", token=None)
            st3, _ = call("GET", "/api/equipos", token=None)
            st4, _ = call("GET", "/api/plantilla", token=None)
            check("centro: the centre's and step 8's GETs need the token too — the template included",
                  st == 401 and st2 == 401 and st3 == 401 and st4 == 401)
            st, d = call("GET", "/api/centros")
            fila = {c[0]: c for c in d.get("centros", [])}
            ramon = fila.get("121567", [None] * 7)
            check("centros: every register row once, in one payload — regions north to south, every type, the card's fields by index (R36)",
                  st == 200 and d["registro"] == "2099-99-99" and len(d["centros"]) == len(ROWS) == len(fila)
                  and d["regiones"] == ["Metropolitana de Santiago", "La Araucanía",
                                        "Magallanes y de la Antártica Chilena"]
                  and d["tipos"] == [["CESFAM", "Centro de Salud Familiar"], ["PSR", "Posta de Salud Rural"],
                                     ["SAPU", "Servicio de Atención Primaria de Urgencia"]]
                  and ramon[1] == 1 and ramon[2] == "Posta de Salud Rural San Ramón"
                  and ramon[3] == "Calle Caserío de San Ramón"
                  and d["comunas"][ramon[4]] == ["Padre Las Casas", 1]
                  and d["servicios"][ramon[5]] == "Servicio de Salud Araucanía Sur"
                  and d["dependencias"][ramon[6]] == "Municipal")
            st, body = call("GET", "/api/centro")
            st1, _ = call("POST", "/api/centro", {"codigo": "121567"})
            st2, body2 = call("POST", "/api/centro", {"codigo": "113314"})
            st3, body3 = call("GET", "/api/centro")
            check("centro: none chosen is a null code, not an error; before the site file a correction is free; the server holds the choice",
                  st == 200 and body["codigo"] is None and st1 == 200 and st2 == 200
                  and body2["nombre"] == "Centro de Salud Familiar Cóndores de Chile"
                  and st3 == 200 and body3["codigo"] == "113314" and body3["fijo"] is False)
            st, _ = call("POST", "/api/centro", {"codigo": "../etc"})
            st2, _ = call("POST", "/api/centro", {"codigo": "999999"})
            check("centro: a junk code answers 400, one absent from the register 404",
                  st == 400 and st2 == 404)

            st, body = call("POST", "/api/sitio",
                            {"codigo": "113314",
                             "sectors": ["Sector Estrella", "SECTOR estrella"],
                             "programs": ["Programa Salud Mental"]})
            written = site_path("113314")
            check("site.sh written via write_site (the backtick row)",
                  st == 200 and body["ok"] and not body["already"] and os.path.exists(written))
            with open(written, encoding="utf-8") as fh:
                text = fh.read()
            check("site.sh carries the identity and both teams",
                  "SITE_DEIS=113314" in text and "sector-estrella" in text
                  and "prog-salud-mental" in text)
            check("the converged team appears exactly once",
                  text.count("sector-estrella|Sector Estrella") == 1)
            check("the backtick address survives quoting", "Calle Agusto D`Almar 555" in text)
            st, body = call("POST", "/api/sitio", {"codigo": "113314",
                                                   "sectors": ["Estrella"], "programs": ["Salud Mental"]})
            check("teams: saved again the same — any order, with or without the word — converges (R35)",
                  st == 200 and body["ok"] and body["already"]
                  and body["equipos"] == [["prog-salud-mental", "Programa Salud Mental"],
                                          ["sector-estrella", "Sector Estrella"]])
            site_backup = open(written, encoding="utf-8").read()  # revert material (B-014)
            with open(written, "w", encoding="utf-8") as fh:  # a hand-edit past recognition
                fh.write("SITE_DEIS=999999\n")
            st, body = call("POST", "/api/sitio", {"codigo": "113314",
                                                    "sectors": [], "programs": []})
            with open(written, "w", encoding="utf-8") as fh:  # the plant is reverted, not
                fh.write(site_backup)                           # left behind — slice 15 reads this file
            check("a site belonging to another establishment refuses 409",
                  st == 409 and "999999" in body["error"])
            st, _ = call("POST", "/api/sitio", {"codigo": "999999",
                                                 "sectors": [], "programs": []})
            check("a codigo absent from the register answers 404", st == 404)
            st, _ = call("POST", "/api/sitio", {"codigo": "../etc",
                                                 "sectors": [], "programs": []})
            check("a traversal codigo answers 400, never a path", st == 400)
            st, _ = call("POST", "/api/sitio", {"codigo": "110485",
                                                 "sectors": "Sector Uno", "programs": []})
            check("non-list sectors answer 400", st == 400)
            st, _ = call("POST", "/api/sitio", {"codigo": "110485",
                                                 "sectors": [13], "programs": []})
            check("non-string team names answer 400 (HTTP)", st == 400)
            # R35 on a fresh tree: «vista» touches nothing; different teams are a 409 naming the
            # difference; «reemplazar» rewrites the three team blocks and keeps every other line
            real_here, real_cred = deis.HERE, CRED_PATH
            with tempfile.TemporaryDirectory() as eq:
                deis.HERE = os.path.join(eq, "scripts")
                os.makedirs(deis.HERE)
                CRED_PATH = os.path.join(eq, "credenciales.txt")
                try:
                    pedido = {"codigo": "121567", "sectors": ["Norte", "Sector Sur"],
                              "programs": ["Cardiovascular"]}
                    st0, vista = call("POST", "/api/sitio", {**pedido, "vista": True})
                    nada = not os.path.exists(site_path("121567"))
                    st1, _ = call("POST", "/api/sitio", pedido)
                    sitio = site_path("121567")
                    with open(sitio, encoding="utf-8") as fh:
                        editado = fh.read().replace('SITE_DOMINIO=""', 'SITE_DOMINIO="clinica.example"')
                    with open(sitio, "w", encoding="utf-8") as fh:   # a hand edit outside the team blocks
                        fh.write(editado)
                    st2, otro = call("POST", "/api/sitio", {**pedido, "sectors": ["Norte", "Oriente"]})
                    with open(sitio, encoding="utf-8") as fh:
                        intacto = fh.read()
                    st_pl, _ = call("POST", "/api/usuarios", {"codigo": "121567", "csv":
                                    "usuario;nombre;apellidos;correo;grupos;primer_admin\n"
                                    "noe.1;Noé;Uno;;sector-sur role-medico;sí\n"})
                    st3, hecho = call("POST", "/api/sitio", {**pedido, "sectors": ["Norte", "Oriente"],
                                                            "reemplazar": True})
                    with open(sitio, encoding="utf-8") as fh:
                        despues = fh.read()
                    st5, viejo = api_generar({"codigo": "121567", "modo": "revision"})
                    with open(sitio, encoding="utf-8") as fh:   # a grant added by hand inside SITE_ACL
                        con_mano = fh.read().replace("SITE_ACL=(\n", "SITE_ACL=(\n  'Unidades/SOME|role-medico|'\n", 1)
                    with open(sitio, "w", encoding="utf-8") as fh:
                        fh.write(con_mano)
                    st6, mano = call("POST", "/api/sitio", {**pedido, "sectors": ["Norte"], "reemplazar": True})
                    with open(sitio, encoding="utf-8") as fh:
                        tras_mano = fh.read()
                    st4, eqs = call("GET", "/api/equipos")
                finally:
                    deis.HERE, CRED_PATH = real_here, real_cred
            check("teams: «vista» derives the group ids and writes nothing (a16)",
                  st0 == 200 and nada and vista["equipos"] == [
                      ["prog-cardiovascular", "Programa Cardiovascular"],
                      ["sector-norte", "Sector Norte"], ["sector-sur", "Sector Sur"]])
            check("teams: saved again different is a 409 naming what is new and what goes — the file untouched, never a silent 200 (R35, a15)",
                  st1 == 200 and st2 == 409 and otro["nuevos"] == ["Sector Oriente"]
                  and otro["quitados"] == ["Sector Sur"] and intacto == editado)
            check("teams: «reemplazar» rewrites teams, folders and grants, keeping the domain and every other line (R35)",
                  st3 == 200 and hecho.get("reemplazados") is True
                  and "'sector-oriente|Sector Oriente'" in despues and "sector-sur" not in despues
                  and "'Sectores/Sector Oriente'" in despues
                  and "'Sectores/Sector Oriente|sector-oriente|read write delete'" in despues
                  and 'SITE_DOMINIO="clinica.example"' in despues and "SITE_WELCOME=(" in despues
                  and despues.count("SITE_ACL=(") == 1)
            check("teams: a planilla naming a team «Reemplazar» removed is caught at «Revisar», with its line (R35)",
                  st_pl == 200 and st5 == 400
                  and "sector-sur" in " ".join(e["error"] for e in viejo.get("errores", []))
                  and "sector-norte" in viejo.get("grupos_validos", []))
            check("teams: «reemplazar» over a grant added by hand is refused, the file untouched — never a silent loss",
                  st6 == 409 and "a mano" in mano["error"] and tras_mano == con_mano)
            check("equipos: the saved teams, every cargo the planilla accepts with phase 20's names; a planilla naming a team that went no longer counts as loaded (R38, R35)",
                  st4 == 200 and eqs["guardados"] is True and ["sector-oriente", "Sector Oriente"] in eqs["equipos"]
                  and ["role-medico", "Médico General / de Familia"] in eqs["cargos"]
                  and len(eqs["cargos"]) == 22 and eqs["planilla_cargada"] is False)
            st, barra = call("POST", "/api/sitio", {"codigo": "113314", "sectors": ["Norte|x"],
                                                    "programs": [], "vista": True})
            check("teams: a name with «|» is refused before it can break the site file",
                  st == 400 and "«|»" in barra["error"])
            EXEC_LOCK.acquire()
            try:
                st_e, en_curso = call("POST", "/api/sitio", {"codigo": "113314", "sectors": ["Otro"],
                                                             "programs": [], "reemplazar": True})
                st_v, _ = call("POST", "/api/sitio", {"codigo": "113314", "sectors": ["Otro"],
                                                      "programs": [], "vista": True})
            finally:
                EXEC_LOCK.release()
            DONE.set()
            try:
                st_d, hecho = call("POST", "/api/usuarios", {"codigo": "113314", "csv": "x"})
            finally:
                DONE.clear()
            check("the run's input never changes under an execution nor after the install finished — «vista» still answers (SEC-2)",
                  st_e == 409 and "en curso" in en_curso.get("error", "") and st_v == 200
                  and st_d == 409 and "ya terminó" in hecho.get("error", ""))
            st, body = call("POST", "/api/sitio", {"codigo": "121567", "sectors": [], "programs": []})
            st2, body2 = call("POST", "/api/centro", {"codigo": "121567"})
            st3, body3 = call("GET", "/api/centro")
            st4, _ = call("POST", "/api/centro", {"codigo": "113314"})
            check("one install, one establishment: with a site file written, another centre is refused 409 at step 8 and at «Confirmar centro», naming the centre, no path; the written one answers, fixed (D13, a16)",
                  st == 409 and "un solo establecimiento" in body["error"]
                  and "Cóndores de Chile (DEIS 113314)" in body["error"] and "site.sh" not in body["error"]
                  and st2 == 409 and body2 == body and not os.path.exists(site_path("121567"))
                  and st3 == 200 and body3["codigo"] == "113314" and body3["fijo"] is True and st4 == 200
                  and installed_centre() == "Centro de Salud Familiar Cóndores de Chile")
            # the directory IS the code (host/aps-conecta site_codigo): a hand-edited SITE_DEIS does
            # not move the centre, and a code the register lacks is still this install's, named plainly
            real_here = deis.HERE
            with tempfile.TemporaryDirectory() as raro:
                deis.HERE = os.path.join(raro, "scripts")
                try:
                    os.makedirs(deis.HERE)   # sites/ is reached through scripts/..
                    os.makedirs(os.path.join(raro, "sites", "113314"))
                    with open(os.path.join(raro, "sites", "113314", "site.sh"), "w", encoding="utf-8") as fh:
                        fh.write("SITE_DEIS=121567\n")
                    st, editado = call("GET", "/api/centro")
                    os.remove(os.path.join(raro, "sites", "113314", "site.sh"))
                    os.makedirs(os.path.join(raro, "sites", "999999"))
                    with open(os.path.join(raro, "sites", "999999", "site.sh"), "w", encoding="utf-8") as fh:
                        fh.write("SITE_DEIS=999999\n")
                    st2, ajeno = call("GET", "/api/centro")
                    st3, otro = call("POST", "/api/centro", {"codigo": "113314"})
                    listo = installed_centre()
                finally:
                    deis.HERE = real_here
            check("centro: the site directory is the code — a hand-edited SITE_DEIS does not move it; a code the register lacks is still this install's centre, named plainly (review I1, I2)",
                  st == 200 and editado.get("codigo") == "113314" and editado.get("fijo") is True
                  and st2 == 200 and ajeno == {"codigo": "999999", "nombre": "el establecimiento DEIS 999999",
                                               "fijo": True}
                  and st3 == 409 and "otro establecimiento (DEIS 999999)" in otro["error"]
                  and listo == "el establecimiento DEIS 999999")
            # ── slice 15: the roster (FRD S5) — /api/usuarios + the credentials sealing ──
            # The credentials sheet redirects to the fixture (CRED_PATH); phase 20 stays the REAL
            # registry file (repo content, read-only — the shared 27 are not site data) and is
            # swapped to a mangled copy only inside its own negative arm, restored immediately.
            CRED_PATH = os.path.join(tmp, "credenciales.txt")
            ESTADO_PATH = os.path.join(tmp, "estado.txt")
            AIO_STATE = os.path.join(tmp, "aio")
            globals().update(recursos=lambda *_a: (12.0, 4), puerto_libre=lambda _p: True)

            def planilla(*rows):
                out = [";".join(ROSTER_HEADER)] + [";".join(r) for r in rows]
                return "\n".join(out) + "\n"

            def err_lines(body):
                return " ".join(e["error"] for e in body.get("errores", []))

            maria = ("maria.perez", "María", "Pérez Soto", "",
                     "all-staff cat-clinicos role-enfermeria sector-estrella", "no")
            juan = ("juan.soto", "Juan", "Soto Ríos", "juan.soto@example.cl",
                    "all-staff role-medico", "si")
            elena = ("elena.diaz", "Elena", "Díaz Nueve", "",
                     "role-matroneria", "si")
            site_pre = open(site_path("113314"), encoding="utf-8").read()
            cargos_113314 = [u for u in standing_uids(*site_arrays(site_path("113314"))) if u != "admin"]

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": "\ufeff" + planilla(maria, juan)})
            check("roster: a BOM semicolon CSV with accents validates (site team accepted)",
                  st == 200 and body["ok"] and body["usuarios"] == 2
                  and body["primer_admin"] == "juan.soto"
                  and body["contrasenas_selladas"] == 2 + len(cargos_113314))
            sheet = sealed_map(CRED_PATH)
            check("credentials: each cargo account has its own sealed password, sealed with the planilla's (a8)",
                  len(cargos_113314) >= 4
                  and all(sheet.get(u, ("", ""))[1] == f"Cargo {u}" for u in cargos_113314)
                  and len({pw for pw, _d, _p in sheet.values()}) == len(sheet))

            roster_file = os.path.join(tmp, "sites", "113314", "usuarios.csv")
            with open(roster_file, encoding="utf-8") as fh:
                roster_text = fh.read()
            check("roster: the canonical roster is written — no BOM, semicolons, sorted groups",
                  roster_text.startswith("usuario;nombre;apellidos;correo;grupos;primer_admin\n")
                  and "maria.perez;María;Pérez Soto;;all-staff cat-clinicos role-enfermeria"
                      " sector-estrella;no\n" in roster_text
                  and "juan.soto;Juan;Soto Ríos;juan.soto@example.cl;all-staff role-medico;si\n"
                      in roster_text)

            site_post = open(site_path("113314"), encoding="utf-8").read()
            pre, post = site_pre.splitlines(), site_post.splitlines()
            changed = [(i, a, b) for i, (a, b) in enumerate(zip(pre, post), 1) if a != b]
            check("roster: SITE_ROSTER is set surgically — every other line byte-identical",
                  changed == [(pre.index('SITE_ROSTER=""') + 1, 'SITE_ROSTER=""',
                               "SITE_ROSTER=sites/113314/usuarios.csv")])

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": planilla(maria, juan)})
            check("roster: a re-run converges — roster and site byte-identical, zero new passwords",
                  st == 200 and body["contrasenas_nuevas"] == 0
                  and open(roster_file, encoding="utf-8").read() == roster_text
                  and open(site_path("113314"), encoding="utf-8").read() == site_post)

            def sheet_rows():
                with open(CRED_PATH, encoding="utf-8") as fh:
                    text = fh.read()
                return [r for r in csv.reader(io.StringIO(text), delimiter=";")
                        if r and not r[0].startswith("#") and r[0] != "usuario"]

            cred_rows = sheet_rows()
            pws = {r[0]: r[2] for r in cred_rows}
            check("credentials: sealed 0600, a row per uid (the planilla's and the cargos'), 24-hex, display carries the accents",
                  oct(os.stat(CRED_PATH).st_mode & 0o777) == "0o600"
                  and set(pws) == {"maria.perez", "juan.soto"} | set(cargos_113314)
                  and all(re.fullmatch("[0-9a-f]{24}", p) for p in pws.values())
                  and any(r[1] == "María Pérez Soto" for r in cred_rows))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                    "csv": "usuario;nombre;apellidos;correo;grupos\nx;y\n"})
            check("roster: a wrong header names the exact contract (línea 1)",
                  st == 400 and body["errores"][0]["linea"] == 1
                  and "usuario;nombre;apellidos;correo;grupos;primer_admin"
                      in body["errores"][0]["error"])

            bad_rows = ("usuario;nombre;apellidos;correo;grupos;primer_admin\n"
                        "cinco;campos;aquí\n"
                        '"con\nsalto";Nombre;Apellido;;all-staff;no\n')
            st, body = call("POST", "/api/usuarios", {"codigo": "113314", "csv": bad_rows})
            got = {e["linea"] for e in body.get("errores", [])}
            check("roster: field-count and multiline-cell errors carry their line numbers",
                  st == 400 and 2 in got and 3 in got
                  and "tiene 3" in err_lines(body) and "varias líneas" in err_lines(body))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("María.Pérez", "María", "Pérez", "", "all-staff", "no"),
                                  ("Juan.SOTO", "Juan", "Soto", "", "all-staff", "no"))})
            check("roster: uid charset — uppercase and accents refused (a uid is not a name)",
                  st == 400 and err_lines(body).count("no es válido") == 2)

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("ana.1", "Ana", "Uno", "", "all-staff", "no"),
                                  ("ana.1", "Ana", "Dos", "", "all-staff", "no"))})
            check("roster: duplicate uids name both lines",
                  st == 400 and "repetido" in err_lines(body)
                  and "línea 2" in err_lines(body))

            # the operator's hand edit, exactly as the site file documents it: a local SAR jefatura
            with open(site_path("113314"), encoding="utf-8") as fh:
                st_txt = fh.read()
            with open(site_path("113314"), "w", encoding="utf-8") as fh:
                fh.write(st_txt.replace("SITE_ROLES=()",
                        'SITE_ROLES=(\n  "role-jefe-sar|Jefe/a de SAR|cat-jefaturas"\n)'))
            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("director", "Dir", "Fijo", "", "all-staff", "no"),
                                  ("jefe.estrella", "Jefe", "Sector", "", "all-staff", "no"),
                                  ("jefe.sar", "Jefe", "SAR", "", "all-staff", "no"),
                                  ("admin", "Ad", "Min", "", "all-staff", "no"))})
            msgs = err_lines(body)
            # org L5-11: the reasons now come from the shared derivation (one vocabulary for
            # director/sector-derived/role-derived) plus admin's own wizard line.
            check("roster: standing uids refused — the shared derivation's cargos and the wizard admin",
                  st == 400
                  and msgs.count("un cargo que la instalación crea sola") == 3
                  and "cuenta administradora" in msgs
                  and all(f"«{uid}»" in msgs
                          for uid in ("director", "jefe.estrella", "jefe.sar", "admin")))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pedro.2", "Pedro", "Dos", "pedro2@example.cl",
                                   "role-medico sar-desconocido admin", "no"))})
            msgs = err_lines(body)
            check("roster: unknown groups and admin-in-grupos are line errors",
                  st == 400 and "«sar-desconocido» no existe" in msgs
                  and "columna primer_admin" in msgs
                  and "sector-estrella" in body["grupos_validos"] and "role-medico" in body["grupos_validos"]
                  and "all-staff" not in body["grupos_validos"])

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("luis.3", "Luis", "Tres", "no-es-correo",
                                   "all-staff", "no"))})
            check("roster: a malformed correo errors (empty correo was green above)",
                  st == 400 and "«no-es-correo» no es válido" in err_lines(body))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("sofia.4", "Sofía", "Cuatro", "", "", "no"))})
            check("roster: empty grupos names what a group is",
                  st == 400 and "al menos un sector, programa o cargo" in err_lines(body))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("elena.5", "Elena", "Cinco", "", "all-staff", "SÍ"))})
            check("roster: primer_admin accepts sí, accent-blind (es-CL spells it so)",
                  st == 200 and body["primer_admin"] == "elena.5")

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pepe.6", "Pepe", "Seis", "", "all-staff", "no"))})
            check("roster: zero primer_admin = sí is a whole-file error (no line) naming it",
                  st == 400 and "primer_admin = sí" in err_lines(body)
                  and body["errores"][-1]["linea"] == 0)

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pepe.6", "Pepe", "Seis", "", "all-staff", "si"),
                                  ("rosa.7", "Rosa", "Siete", "", "all-staff", "si"))})
            msgs = err_lines(body)
            check("roster: two primer_admin=si name both lines",
                  st == 400 and "primer_admin = sí" in msgs
                  and "línea 2" in msgs and "línea 3" in msgs)

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pepe.6", "Pepe", "Seis", "", "all-staff", "ja"))})
            check("roster: primer_admin junk values are refused",
                  st == 400 and "«sí» o «no»" in err_lines(body))
            st, body = call("POST", "/api/usuarios", {"codigo": "113314", "csv": planilla(
                ("director", "Dir", "Fijo", "", "role-medico", "no"),
                ("sofia.4", "Sofía", "Cuatro", "", "", "no"),
                ("pedro.2", "Pedro", "Dos", "", "grupo-x", "quizás"))})
            textos = err_lines(body)
            check("roster: a sample of planilla messages (a cargo, no groups, an unknown group, a junk flag, no admin) speaks clinic terms — no phase, script, path or all-staff (a16, R38, R44)",
                  st == 400 and len(body["errores"]) >= 4
                  and not any(t in textos for t in ("fase", ".sh", "/", "all-staff", "standings")))
            saved_path = os.environ["PATH"]
            os.environ["PATH"] = os.path.join(tmp, "empty")   # no bash: the cargos cannot be derived
            try:
                st, body = call("POST", "/api/usuarios", {"codigo": "113314", "csv": planilla(maria)})
                st_g, body_g = api_generar({"codigo": "113314", "modo": "revision"})
            finally:
                os.environ["PATH"] = saved_path
            check("roster: the cargos' derivation failing is a Spanish 500 at the upload and at «Revisar», never a dropped connection",
                  st == 500 and "no se pudieron derivar los cargos" in body.get("error", "")
                  and st_g == 500 and "no se pudieron derivar los cargos" in body_g.get("error", ""))
            # the template round-trips (a15): on a fresh tree with its own sealed sheet
            real_here, real_cred = deis.HERE, CRED_PATH
            with tempfile.TemporaryDirectory() as pl:
                deis.HERE = os.path.join(pl, "scripts")
                os.makedirs(deis.HERE)
                os.symlink(os.path.join(ROOT_DIR, "provisioning"), os.path.join(pl, "provisioning"))
                CRED_PATH = os.path.join(pl, "credenciales.txt")
                try:
                    previo_centro = CENTRO
                    call("POST", "/api/centro", {"codigo": "113314"})
                    st0, antes = call("GET", "/api/plantilla")
                    call("POST", "/api/sitio", {"codigo": "113314", "sectors": ["Norte"],
                                                "programs": ["Cardiovascular"]})
                    req = urllib.request.Request(base + "/api/plantilla",
                                                 headers={"Authorization": f"Bearer {TOKEN}"})
                    with urllib.request.urlopen(req, timeout=10) as r:
                        crudo, tipo, disp = (r.read(), r.headers.get("Content-Type", ""),
                                             r.headers.get("Content-Disposition", ""))
                    st2, subida = call("POST", "/api/usuarios", {"codigo": "113314",
                                                                 "csv": crudo.decode("utf-8")})
                    st3, eq3 = call("GET", "/api/equipos")
                    st4, _ = call("POST", "/api/sitio", {"codigo": "113314", "sectors": ["Norte", "Sur"],
                                                         "programs": ["Cardiovascular"], "reemplazar": True})
                    st5, eq5 = call("GET", "/api/equipos")
                finally:
                    deis.HERE, CRED_PATH, CENTRO = real_here, real_cred, previo_centro
            check("template: before the teams it says why; then this centre's ids, «sí», a BOM — and it uploads back clean (R38, a15)",
                  st0 == 409 and "guarde los equipos" in antes["error"]
                  and crudo.startswith(b"\xef\xbb\xbf") and "text/csv" in tipo
                  and 'filename="planilla-113314.csv"' in disp
                  and "sector-norte prog-cardiovascular role-enfermeria;sí" in crudo.decode("utf-8")
                  and st2 == 200 and subida["primer_admin"] == "ana.rojas"
                  and [f[0] for f in subida["filas"]] == ["ana.rojas", "pedro.munoz"])
            check("equipos: «planilla cargada» means «Revisar» accepts it — true after the upload, false once a new sector's cargo is unsealed (review Q2)",
                  st3 == 200 and eq3.get("planilla_cargada") is True
                  and st4 == 200 and st5 == 200 and eq5.get("planilla_cargada") is False)

            st, body = call("POST", "/api/usuarios", {"codigo": "110485",
                                                      "csv": planilla(maria)})
            check("roster: a site never written answers 404 with the next step",
                  st == 404 and "primero guarde los equipos" in body.get("error", ""))

            st, _ = call("POST", "/api/usuarios", {"codigo": "113314", "csv": planilla(maria)},
                         token=None)
            check("roster: the router rides the bearer gate — 401 without a token", st == 401)

            junk20 = os.path.join(tmp, "20-groups-junk.sh")
            with open(junk20, "w", encoding="utf-8") as fh:
                fh.write('phase_begin "20-groups" "junk"\nensure_group all-staff "x"\n')
            PHASE20 = junk20
            try:
                st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                          "csv": planilla(maria, juan)})
            finally:
                PHASE20 = old_p20
            check("roster: a shape-changed phase 20 refuses validation instead of crying wolf",
                  st == 400 and "cambió de forma" in body.get("error", "")
                  and "all-staff" not in body["error"] and ".sh" not in body["error"])
            check("roster: the real shared registry parses 27 groups (positive control)",
                  len(registry_groups(old_p20)) == 27)

            def set_roster_line(val):
                with open(site_path("113314"), encoding="utf-8") as fh:
                    t = fh.read()
                with open(site_path("113314"), "w", encoding="utf-8") as fh:
                    fh.write(re.sub(r"(?m)^SITE_ROSTER=.*$", f"SITE_ROSTER={val}", t, count=1))

            set_roster_line('"../fuera.csv"')
            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": planilla(maria, juan)})
            check("roster: a SITE_ROSTER outside the site dir answers 409 — nothing written there",
                  st == 409 and "fuera de sites/113314/" in body.get("error", "")
                  and not os.path.exists(os.path.normpath(os.path.join(tmp, "..", "fuera.csv"))))
            set_roster_line('""')  # back to the converge default for the arms below

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": planilla(maria, elena)})
            now_pws = {r[0]: r[2] for r in sheet_rows()}
            check("credentials: a new uid gets a password; a returning uid keeps its sealed one",
                  st == 200 and body["contrasenas_nuevas"] == 1
                  and now_pws["maria.perez"] == pws["maria.perez"]
                  and re.fullmatch("[0-9a-f]{24}", now_pws["elena.diaz"]))
            check("credentials: cumulative — uids that left the roster keep their rows",
                  "elena.5" in now_pws and "juan.soto" in now_pws
                  and now_pws["juan.soto"] == pws["juan.soto"]
                  and "elena.5" not in open(roster_file, encoding="utf-8").read())

            err_cap = io.StringIO()
            with redirect_stderr(err_cap):
                st, body_nolog = call("POST", "/api/usuarios", {"codigo": "113314",
                        "csv": planilla(maria, elena)})
            seen_all = json.dumps(body_nolog) + err_cap.getvalue()
            check("credentials: no password byte reaches any response or log line — paths only",
                  all(p not in seen_all for p in now_pws.values())
                  and body_nolog.get("credenciales") == CRED_PATH)

            good_sheet = open(CRED_PATH, encoding="utf-8").read()
            with open(CRED_PATH, "w", encoding="utf-8") as fh:
                fh.write("esto;no;es;una;hoja;sellada\n")
            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": planilla(maria, elena)})
            check("credentials: a sheet this program did not write is refused 409, left intact",
                  st == 409 and "no se puede leer" in body.get("error", "")
                  and open(CRED_PATH, encoding="utf-8").read() == "esto;no;es;una;hoja;sellada\n")
            with open(CRED_PATH, "w", encoding="utf-8") as fh:  # restore the real sheet
                fh.write(good_sheet)

            set_roster_line('"sites/113314/planilla-mia.csv"')
            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": planilla(maria, elena)})
            check("roster: a hand-set SITE_ROSTER inside the site dir is honored, line untouched",
                  st == 200 and body["roster"] == "sites/113314/planilla-mia.csv"
                  and os.path.exists(os.path.join(tmp, "sites", "113314", "planilla-mia.csv"))
                  and 'SITE_ROSTER="sites/113314/planilla-mia.csv"' in
                      open(site_path("113314"), encoding="utf-8").read())

            with open(site_path("113314"), encoding="utf-8") as fh:
                st_txt = fh.read()
            with open(site_path("113314"), "w", encoding="utf-8") as fh:
                fh.write(st_txt.replace("SITE_TEAMS=(",
                        'SITE_TEAMS=(\n  entrada sin comillas con espacios', 1))
            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": planilla(maria, elena)})
            check("roster: an unreadable SITE_TEAMS block fails closed (400), never guessed",
                  st == 400 and "SITE_TEAMS" in body.get("error", "")
                  and "no se puede leer" in body.get("error", ""))
            with open(site_path("113314"), "w", encoding="utf-8") as fh:
                fh.write(st_txt)  # restore

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": planilla()})
            check("roster: a header-only planilla errors — a roster with no users is not a roster",
                  st == 400 and "no trae usuarios" in err_lines(body))

            # CRLF is the Windows Excel hand-off, and a mid-file blank line is what Excel leaves
            # behind — the line numbers must survive both (retained evidence for the R1 verifier's
            # evidence-trail warning: this arm runs on every self-test, not in a throwaway driver).
            crlf = ("usuario;nombre;apellidos;correo;grupos;primer_admin\r\n"
                    "ana.9;Ana;Nueve;;all-staff;si\r\n"
                    "\r\n"
                    "bobo.10;Bob;Diez;mal;all-staff;no\r\n")
            rows2, errors2 = roster_parse(crlf, {"director": "x"}, {"all-staff"})
            check("roster: CRLF and mid-file blank lines keep the line numbers honest",
                  rows2 == [("ana.9", "Ana", "Nueve", "", ("all-staff",), True)]
                  and errors2 == [(4, "el correo «mal» no es válido")])
            # ── slice 16: the executor (FRD S5) — /api/generar, the roster driver, the gate ──
            # The stub oracle (the test.sh #143 pattern as a PATH binary, stateful for the
            # driver's noops — a stateless stub would fake the idempotent arms red) answers the
            # whole seed/phases/driver/gate world. The fixture assembles a REAL repo tree around
            # the register fixture (provisioning/ copied sans the 89 MB apps/, which is
            # symlinked; themes/ and .env.example copied; env.sh copied into tmp/scripts/) —
            # deis.HERE redirects every path, so the real tree is never touched; the PATH
            # injection and the FAKE_DOCKER_* knobs are restored in the outer finally.
            import shutil
            shutil.copytree(os.path.join(HERE, "..", "provisioning"), os.path.join(tmp, "provisioning"),
                            ignore=shutil.ignore_patterns("apps"))
            os.symlink(os.path.join(HERE, "..", "provisioning", "apps"),
                       os.path.join(tmp, "provisioning", "apps"))
            shutil.copytree(os.path.join(HERE, "..", "themes"), os.path.join(tmp, "themes"))
            shutil.copy(os.path.join(HERE, "..", ".env.example"), os.path.join(tmp, ".env.example"))
            shutil.copy(os.path.join(HERE, "..", "scripts", "env.sh"), os.path.join(tmp, "scripts", "env.sh"))
            shutil.copy(os.path.join(HERE, "..", "scripts", "divergence.sh"),
                       os.path.join(tmp, "scripts", "divergence.sh"))
            stubdir = os.path.join(tmp, "bin")
            os.makedirs(stubdir)
            for name, src, mode in (("docker", STUB_DOCKER, 0o755), ("curl", "#!/usr/bin/env bash\nexit 1\n", 0o755)):
                path = os.path.join(stubdir, name)
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(src)
                os.chmod(path, mode)
            stublog = os.path.join(tmp, "stub.log")
            stubstate = os.path.join(tmp, "stub.state")
            stubctl = os.path.join(tmp, "stub.ctl")
            old_path = os.environ["PATH"]
            os.environ["PATH"] = stubdir + ":" + old_path
            os.environ["FAKE_DOCKER_LOG"] = stublog
            os.environ["FAKE_DOCKER_STATE"] = stubstate
            os.environ["FAKE_DOCKER_CONTROL"] = stubctl
            open(stubstate, "w").close()

            def stub_log_text():
                with open(stublog, encoding="utf-8") as fh:
                    return fh.read()

            def generar(mode, codigo="113314"):
                buf = io.StringIO()
                with redirect_stdout(buf):   # the executor's host-side tee — captured, not printed
                    return api_generar({"codigo": codigo, "modo": mode})

            snap = {p: hashlib.md5(open(p, "rb").read()).hexdigest()
                    for p in (site_path("113314"), CRED_PATH,
                              os.path.join(deis.HERE, "..", "sites", "113314", "planilla-mia.csv"))}
            execs = [0]
            real_popen = subprocess.Popen
            # org L5-11: standing_uids() delegates to provisioning/standings.sh through a real
            # bash — that exec is part of re-deriving the world, not a write. Everything else
            # revision does stays in-process, so the zero line is asserted EXCLUDING it.
            def _counting_popen(*a, **k):
                argv0 = a[0] if a else ()
                delegation = isinstance(argv0, list) and "standings.sh" in " ".join(map(str, argv0))
                execs.__setitem__(0, execs[0] + (0 if delegation else 1))
                return real_popen(*a, **k)
            subprocess.Popen = _counting_popen
            st, body = generar("revision")
            subprocess.Popen = real_popen
            same = all(hashlib.md5(open(p, "rb").read()).hexdigest() == h for p, h in snap.items())
            check("generar: revision answers the plan — zero execs, zero writes",
                  st == 200 and body["modo"] == "revision" and body["usuarios"] == 2
                  and body["primer_admin"] == "elena.diaz" and body["contrasenas_selladas"] >= 2
                  and len(body["fases"]) == 14 and execs[0] == 0 and same
                  and body["env"]["FIXTURE_USER_PASSWORD"] == "se generará")

            def stepped(argv):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    rc = run_step(argv)
                return rc, buf.getvalue()

            execs[0] = 0
            subprocess.Popen = _counting_popen
            try:
                rc, out = stepped(["--paso", "generar", "--codigo", "113314", "--revision"])
            finally:
                subprocess.Popen = real_popen
            check("--paso generar --revision: the plan in one Spanish line, nothing executed, exit 0",
                  rc == 0 and execs[0] == 0
                  and "✓ Revisión: 14 fases, 2 usuarios (administrador inicial elena.diaz)" in out)
            st, plan = api_generar({"codigo": "113314", "modo": "revision"})
            visibles = json.dumps({k: plan.get(k) for k in ("centro", "sectores", "programas", "personas",
                                                            "componentes")}, ensure_ascii=False)
            check("revisión: the plan in clinic terms — the centre by name, its sectors and programs, every person with the first administrator marked, the components; no path, file or key (R40, R37, a16)",
                  st == 200 and plan["centro"]["nombre"] == "Centro de Salud Familiar Cóndores de Chile"
                  and plan["centro"]["comuna"] == "El Bosque" and plan["sectores"] == ["Sector Estrella"]
                  and plan["programas"] == ["Programa Salud Mental"]
                  and sorted(p[0] for p in plan["personas"]) == ["elena.diaz", "maria.perez"]
                  and [p[0] for p in plan["personas"] if p[3]] == ["elena.diaz"]
                  and plan["cuentas_de_cargo"] > 0 and len(plan["componentes"]) == len(COMPONENTES)
                  and "/" not in visibles and ".sh" not in visibles and "SITE_" not in visibles)
            apps = set(os.listdir(os.path.join(ROOT_DIR, "provisioning", "apps")))
            check("componentes: every app the suite ships is a listed component or declared plumbing — a new app forces the choice (R37)",
                  {a for a, _n, _q in COMPONENTES} | set(PLUMBING_APPS) == apps
                  and not {a for a, _n, _q in COMPONENTES} & set(PLUMBING_APPS))
            check("veredicto: one head for «aps-conecta estado» and the browser — green, drift, a gate that stopped, a run that stopped",
                  veredicto({"divergencia_vacia": True})[0].startswith("✓")
                  and veredicto({"divergencia_vacia": False, "divergencia": "    algo\n"}) ==
                      ("✗ deriva: la instancia tiene lo que no se declaró", ["algo"])
                  and veredicto({"divergencia_vacia": False, "divergencia": "FATAL: x\n"})[0].startswith(
                      "✗ la revisión de divergencia no terminó")
                  and veredicto({"error": "e"}) == ("✗ la ejecución no terminó", ["e"]))
            EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)
            st, nada = call("GET", "/api/ejecucion")
            avance("✓ phase 05-security\n")   # no run the browser started: nothing to follow
            fuera = list(EJECUCION["hechos"])
            EJECUCION.update(estado="en_curso")
            for ln in ("▶ phase 05-security\n", "✓ phase 05-security\n", "otra línea\n",
                       "✓ phase 14-office\n", "== roster: 3 usuario(s)\n"):
                avance(ln)
            check("ejecución: none yet answers «sin_ejecutar» with the 16 steps; a browser run's executor lines become the console's own titles, any other run's are not followed (a14)",
                  st == 200 and nada["ejecucion"] == "sin_ejecutar" and nada["pasos"] == PASOS_EJECUCION
                  and len(PASOS_EJECUCION) == 16 and fuera == []
                  and EJECUCION["hechos"] == ["Seguridad de sesión", "Oficina en línea", "Cuentas del personal"])
            EJECUCION.update(estado="sin_ejecutar", hechos=[])
            verdadero, suelta = globals()["api_generar"], threading.Event()

            def lento(_p):   # a run that reports one phase, then waits to be released
                avance("✓ phase 05-security\n")
                suelta.wait(5)
                return 200, {"modo": "ejecutar", "divergencia_vacia": False, "divergencia": "    algo de más\n"}
            globals()["api_generar"] = lento
            try:
                st1, _ = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar"})
                st2, otra = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar"})
                time.sleep(0.2)
                st3, durante = call("GET", "/api/ejecucion")
                st_sitio, frena = call("POST", "/api/sitio", {"codigo": "113314", "sectors": ["Sector Estrella"],
                                                              "programs": ["Programa Salud Mental"]})
                st_vista, _ = call("POST", "/api/centro", {"codigo": "113314", "vista": True})
                suelta.set()
                for _ in range(50):
                    st4, final = call("GET", "/api/ejecucion")
                    if final["ejecucion"] == "terminada":
                        break
                    time.sleep(0.1)
            finally:
                globals()["api_generar"] = verdadero
            check("ejecución: «Ejecutar» answers at once (202) and runs on a worker; a second start is refused while it runs; the poll shows the progress, then a red verdict that keeps the installer open (a14, SEC-2)",
                  st1 == 202 and st2 == 409 and "en curso" in otra["error"]
                  and st3 == 200 and durante["ejecucion"] == "en_curso"
                  and durante["hechos"] == ["Seguridad de sesión"]
                  and final["ejecucion"] == "terminada" and final["veredicto"]["verde"] is False
                  and final["veredicto"]["titulo"].startswith("✗ deriva") and not DONE.is_set()
                  and final["hechos"] == ["Seguridad de sesión", "Comprobación final"])
            check("ejecución: the run's input is frozen from the 202 on — before the executor's lock, «vista» or not",
                  st_sitio == 409 and "en curso" in frena["error"] and st_vista == 409)
            EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)
            st_mal, _ = call("POST", "/api/generar", {"codigo": "12", "modo": "ejecutar"})
            EXEC_LOCK.acquire()   # a run this page did not start holds the executor
            try:
                st_ocup, ocup = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar"})
                st_suite_ocup, _ = call("POST", "/api/suite", {"dominio": "gestion.clinica.example"})
            finally:
                EXEC_LOCK.release()
            check("ejecución: a bad code is refused 400; a run already holding the executor refuses the start 409; nothing starts",
                  st_mal == 400 and st_ocup == 409 and "en curso" in ocup["error"]
                  and EJECUCION["estado"] == "sin_ejecutar")
            check("suite: «Preparar el asistente» is refused while a run holds the executor", st_suite_ocup == 409)
            verdadero_gen = globals()["api_generar"]
            globals()["api_generar"] = lambda _p: (200, {"modo": "ejecutar", "divergencia_vacia": False, "divergencia": ""})
            SUITE.update(estado="en_curso")
            try:
                st_prep, prep = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar"})
                for _ in range(50):
                    if EJECUCION["estado"] != "en_curso":
                        break
                    time.sleep(0.05)
            finally:
                SUITE.update(estado="sin_preparar")
                globals()["api_generar"] = verdadero_gen
                EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)
            check("ejecución: refused while the wizard is being prepared — the run needs the suite the wizard is about to start",
                  st_prep == 409 and "asistente" in prep.get("error", ""))

            def roto(_p):
                raise RuntimeError("prueba")
            globals()["api_generar"] = roto
            try:
                with redirect_stderr(io.StringIO()) as consola:   # the worker's line, captured
                    st1, _ = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar"})
                    for _ in range(50):
                        st4, final = call("GET", "/api/ejecucion")
                        if final["ejecucion"] == "terminada":
                            break
                        time.sleep(0.1)
            finally:
                globals()["api_generar"] = verdadero
            check("ejecución: a worker that crashes still ends red — the cause on the console and in the state file, the installer open",
                  st1 == 202 and final["ejecucion"] == "terminada" and final["veredicto"]["verde"] is False
                  and final["veredicto"]["titulo"] == "✗ la ejecución no terminó"
                  and "RuntimeError: prueba" in consola.getvalue()
                  and "RuntimeError: prueba" in open(ESTADO_PATH, encoding="utf-8").read()
                  and not DONE.is_set())
            EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)

            class SinHilos:   # a server whose close cannot start its timer
                def close_after_success(self):
                    raise RuntimeError("sin hilos")
            globals()["api_generar"] = lambda _p: (200, {"modo": "ejecutar", "divergencia_vacia": True})
            EJECUCION.update(estado="en_curso", hechos=[], veredicto=None)
            try:
                ejecutar_web("113314", SinHilos())
                cayo = False
            except RuntimeError:
                cayo = True
            finally:
                globals()["api_generar"] = verdadero
            check("ejecución: a close that fails still publishes the verdict — the run never stays «en curso»",
                  cayo and EJECUCION["estado"] == "terminada" and EJECUCION["veredicto"]["verde"] is True)
            EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)
            # ── L3 S5: step 7 — Talk sized to the server, the five apps, the wizard filled on a worker,
            # the containers followed (R26, a12, R48) ──
            (t12, g12), (t16, g16), (t7, g7), (tp, _gp), (t8, _g8), (_t85, g85) = (
                veredicto_talk(12, 4, True), veredicto_talk(16, 8, True), veredicto_talk(7.5, 2, True),
                veredicto_talk(12, 4, False), veredicto_talk(8, 4, True), veredicto_talk(8.5, 8, True))
            check("suite: Talk sized to the server (R26) — 12 GiB / 4 cores: Talk yes, recording no for want of cores; 16 / 8: both; 8 GiB: Talk just fits; too little memory, a taken port, or memory short for the recording: no, saying why",
                  t12 == (True, "~1 GiB") and g12 == (False, "requiere 4 núcleos libres; hay 4 en total")
                  and t16[0] and g16[0] and t8[0] and t7 == (False, "requiere ~1 GiB libres; quedan 0,5 GiB")
                  and g7 == (False, "requiere Talk") and tp == (False, "el puerto 3478 está ocupado")
                  and g85 == (False, "requiere ~2 GiB libres; quedan 1,5 GiB"))
            meminfo = os.path.join(tmp, "meminfo")
            with open(meminfo, "w", encoding="utf-8") as fh:
                fh.write("MemTotal:       12582912 kB\nMemFree:            1024 kB\n")
            ocupado = socket.socket()
            ocupado.bind(("0.0.0.0", 0))
            ocupado.listen()
            with socket.socket() as suelto:
                suelto.bind(("0.0.0.0", 0))
                puerto_suelto = suelto.getsockname()[1]
            try:
                medido, tomado, libre = (reales[0](meminfo), reales[1](ocupado.getsockname()[1]),
                                         reales[1](puerto_suelto))
            finally:
                ocupado.close()
            check("suite: the server's memory read from meminfo and its cores counted; a held port is taken, a closed one free (R26)",
                  medido == (12.0, os.cpu_count() or 1) and tomado is False and libre is True)
            with socket.socket() as escucha:   # a port its own proxy just let go (Go's listeners reuse)
                escucha.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                escucha.bind(("0.0.0.0", 0))
                escucha.listen()
                puerto_tw = escucha.getsockname()[1]
                with socket.create_connection(("127.0.0.1", puerto_tw)) as _cli:
                    srv, _d = escucha.accept()
                    srv.close()   # the server's side closes first: its port keeps a TIME_WAIT
                    time.sleep(0.05)
            check("suite: a port left in TIME_WAIT reads free — a restarted Talk is not refused for its own last connection (R26)",
                  reales[1](puerto_tw) is True)
            os.makedirs(AIO_STATE, exist_ok=True)
            globals()["puerto_libre"] = lambda _p: False
            try:
                corre, nada = talk_ahora({"nextcloud-aio-talk": "Up 1 minute"}), talk_ahora({})
            finally:
                globals()["puerto_libre"] = lambda _p: True
            check("suite: a running Talk holds its own port — it still fits; any other holder does not (R26)",
                  corre[0][0] is True and nada[0] == (False, "el puerto 3478 está ocupado"))
            globals()["puerto_libre"] = lambda _p: False
            try:
                with open(os.path.join(AIO_STATE, "opciones"), "w", encoding="utf-8") as fh:
                    fh.write("talk=0 grabacion=0\n")
                sin_talk_rec = talk_ahora({})
                with open(os.path.join(AIO_STATE, "opciones"), "w", encoding="utf-8") as fh:
                    fh.write("talk=1 grabacion=0\n")
                con_talk_rec = talk_ahora({})
            finally:
                globals()["puerto_libre"] = lambda _p: True
                os.remove(os.path.join(AIO_STATE, "opciones"))
            check("suite: once prepared, the port is probed only where Talk is off — Talk's own proxy is never raced, and a taken port still reads taken (R26)",
                  sin_talk_rec[0] == (False, "el puerto 3478 está ocupado") and con_talk_rec[0][0] is True)
            try:
                with open(os.path.join(AIO_STATE, "opciones"), "w", encoding="utf-8") as fh:
                    fh.write("talk=0 grabacion=0\n")
                sin_talk_plan = [n for n, _q in plan_clinico("113314", [], [], [])["componentes"]]
                with open(os.path.join(AIO_STATE, "opciones"), "w", encoding="utf-8") as fh:
                    fh.write("talk=1 grabacion=0\n")
                con_talk_plan = [n for n, _q in plan_clinico("113314", [], [], [])["componentes"]]
            finally:
                os.remove(os.path.join(AIO_STATE, "opciones"))
            check("revisión: Talk is a component only when step 7 gave the suite Talk — phase 12 installs nothing else (R29)",
                  "Talk" not in sin_talk_plan and "Talk" in con_talk_plan
                  and len(con_talk_plan) == len(COMPONENTES) == len(sin_talk_plan) + 1)
            with open(os.path.join(ROOT_DIR, "provisioning", "phases", "12-apps.sh"), encoding="utf-8") as fh:
                own = re.search(r'^OWN_APPS="([^"]*)"', fh.read(), re.M).group(1)
            with open(HOST_CLI, encoding="utf-8") as fh:
                aio_set = re.search(r'^AIO_SET="([^"]*)"', fh.read(), re.M).group(1).split()
            filas = apps_aps()
            check("suite: the five APS apps are phase 12's own, by name with their VENDOR versions; the containers are the host's set plus Nextcloud (a12)",
                  sorted(e.split("=", 1)[0] for e in own.split()) == sorted(APPS_APS)
                  and [f[0] for f in filas] == ["Inicio", "Epidemiología", "Estadística", "Farmacia", "Territorio"]
                  and all(re.fullmatch(r"\d+\.\d+\.\d+", f[1]) for f in filas)
                  and {c for c, _n in CONTENEDORES_SUITE} == set(aio_set) | {"nextcloud-aio-nextcloud"})
            fijo = centro_actual()[1].get("codigo")   # the site the preparation fills, then restored
            antes_fijo = open(site_path(fijo), encoding="utf-8").read() if fijo else None
            falso = os.path.join(tmp, "asistente-falso.sh")
            with open(falso, "w", encoding="utf-8") as fh:
                fh.write('''#!/usr/bin/env bash
printf '%s\\n' "$*" > "$AIO_STATE/argv"
d=""; t=0; g=0
while [ $# -gt 0 ]; do case "$1" in --dominio) d="$2" ;; --talk) t=1 ;; --grabacion) t=1; g=1 ;; esac; shift; done
sleep 0.3
echo "✓ La suite ya está iniciada"
case "$d" in
  rechazado.example)
    echo "✗ el asistente rechazó «domain» (HTTP 422): use un nombre de dominio, no una dirección IP"
    printf 'El asistente rechazó la dirección: use un nombre de dominio, no una dirección IP.\\n' > "$AIO_STATE/motivo"
    exit 1 ;;
  mudo.example) exit 1 ;;
esac
printf 'frase uno dos' > "$AIO_STATE/master.pw"
echo "✓ Contraseña del asistente guardada en $AIO_STATE/master.pw (solo administrador)"
echo "✓ Ingreso al asistente"
echo "✓ Dominio: $d"
echo "✓ Zona horaria: America/Santiago"
echo "✓ Opciones: oficina incluida; Talk activado; grabación apagada; pizarra e imágenes apagadas"
echo "✓ Respaldo diario a las 04:00 hora de Santiago (07:00 UTC), en /srv/aps-conecta/respaldos, con /opt/aps-conecta"
printf '%s\\n' "$d" > "$AIO_STATE/dominio"
printf 'talk=%s grabacion=%s\\n' "$t" "$g" > "$AIO_STATE/opciones"
echo "✓ Asistente listo: falta «Iniciar» en el asistente"
''')
            verdadero_cmd = SUITE_CMD
            globals()["SUITE_CMD"] = ["bash", falso]

            def preparar(cuerpo, otra_vez=False):
                st, _ = call("POST", "/api/suite", cuerpo)
                st2, otra = call("POST", "/api/suite", cuerpo) if otra_vez else (None, None)
                for _ in range(60):
                    _st3, s = call("GET", "/api/suite")
                    if s["preparacion"]["estado"] != "en_curso":
                        break
                    time.sleep(0.1)
                with open(os.path.join(AIO_STATE, "argv"), encoding="utf-8") as fh:
                    return st, st2, otra, s, fh.read()

            try:
                with redirect_stdout(io.StringIO()):   # the host's lines reach the console, not the test
                    malos = [call("POST", "/api/suite", {"dominio": d})[0] for d in ("sin_punto", "gestion", "10.0.0.5")]
                    *_x, rechazo, argv_rechazo = preparar({"dominio": "rechazado.example"})
                    *_x, mudo, _a = preparar({"dominio": "mudo.example"})
                    globals()["recursos"] = lambda *_a: (7.5, 2)
                    *_x, argv_chico = preparar({"dominio": "gestion.clinica.example"})
                    globals()["recursos"] = lambda *_a: (16.0, 8)
                    *_x, argv_grande = preparar({"dominio": "gestion.clinica.example"})
                    globals()["recursos"] = lambda *_a: (12.0, 4)
                    st1, st2, otra, lista, argv_txt = preparar({"dominio": "gestion.clinica.example",
                                                                 "validar": False}, otra_vez=True)
            finally:
                globals().update(SUITE_CMD=verdadero_cmd, recursos=lambda *_a: (12.0, 4))
                fijado = open(site_path(fijo), encoding="utf-8").read() if fijo else None
                if fijo:
                    write_site_text(site_path(fijo), antes_fijo)
            check("suite: a domain is a name with a dot, never an IP — refused 400 before anything runs",
                  malos == [400, 400, 400])
            check("suite: «Preparar» answers 202 and fills the wizard on a worker — the domain unvalidated only when asked, Talk as the server allows (none on 7,5 GiB / 2 cores, both on 16 / 8), the daily backup; the steps in the page's words, the passphrase, the domain and the options recorded (R26, a12)",
                  st1 == 202 and st2 == 409 and "preparando" in otra["error"]
                  and lista["preparacion"]["estado"] == "lista"
                  and lista["preparacion"]["hechos"] == [t for _p, t in PASOS_SUITE]
                  and lista["frase"] == "frase uno dos" and lista["dominio"] == "gestion.clinica.example"
                  and lista["preparada"] is True and lista["opciones"] == {"talk": True, "grabacion": False}
                  and "--sin-validar-dominio" in argv_txt and "--respaldo /srv/aps-conecta/respaldos" in argv_txt
                  and "--talk" in argv_txt and "--grabacion" not in argv_txt
                  and "--sin-validar-dominio" not in argv_rechazo
                  and "--talk" not in argv_chico and "--talk" in argv_grande and "--grabacion" in argv_grande)
            check("suite: a refused domain ends the preparation with the host's one Spanish line; a silent failure with the generic one — no path either way",
                  rechazo["preparacion"]["estado"] == "error" and rechazo["preparada"] is False
                  and rechazo["preparacion"]["motivo"] == "El asistente rechazó la dirección: use un nombre de dominio, no una dirección IP."
                  and mudo["preparacion"]["motivo"] == "El asistente no quedó listo: el detalle, en la consola del servidor.")
            tope = TIMEOUTS["suite"]
            try:
                TIMEOUTS["suite"] = 1
                globals()["SUITE_CMD"] = ["bash", "-c", "sleep 4", "--"]   # a preparation that outlasts its bound
                with redirect_stdout(io.StringIO()):
                    *_x, lento, _a = preparar({"dominio": "gestion.clinica.example"})
                TIMEOUTS["suite"] = tope
                globals()["SUITE_CMD"] = [os.path.join(tmp, "no-existe", "aps-conecta")]   # the host cannot even start
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as consola_s:
                    *_x, roto_s, _a = preparar({"dominio": "gestion.clinica.example"})
            finally:
                TIMEOUTS["suite"] = tope
                globals()["SUITE_CMD"] = verdadero_cmd
            check("suite: a preparation past its bound, or one whose host cannot start, ends in a Spanish line and the form back — never a stuck «en curso»",
                  lento["preparacion"]["estado"] == "error" and "tardó más de" in lento["preparacion"]["motivo"]
                  and roto_s["preparacion"]["estado"] == "error"
                  and roto_s["preparacion"]["motivo"] == "El asistente no quedó listo: el detalle, en la consola del servidor."
                  and "se detuvo" in consola_s.getvalue())
            check("suite: a site written before step 7 takes the domain the wizard took — that line only",
                  fijo is not None and 'SITE_DOMINIO=""' in antes_fijo
                  and fijado == antes_fijo.replace('SITE_DOMINIO=""', 'SITE_DOMINIO="gestion.clinica.example"'))
            arriba = ";".join(f"{c}:Up 3 minutes" for c, _n in CONTENEDORES_SUITE)
            try:
                open(stubctl, "w", encoding="utf-8").write(
                    "PS_LISTA=nextcloud-aio-apache:Up 1 minute;nextcloud-aio-nextcloud:Up 20 seconds (health: starting);"
                    "nextcloud-aio-database:Up 1 minute (healthy);nextcloud-aio-redis:Created;"
                    "nextcloud-aio-eurooffice:Up 1 minute;nextcloud-aio-talk:Exited (1) 5 seconds ago\n")
                st, a_medias = call("GET", "/api/suite")
                open(stubctl, "w", encoding="utf-8").write(f"PS_LISTA={arriba};nextcloud-aio-talk:Up 3 minutes\n")
                st2, completa = call("GET", "/api/suite")
                open(stubctl, "w", encoding="utf-8").write(f"PS_LISTA={arriba};nextcloud-aio-talk:Exited (1) 1 minute ago\n")
                st3, sin_talk = call("GET", "/api/suite")
            finally:
                open(stubctl, "w").close()
            check("suite: the containers by name — up, starting, waiting, stopped — then the suite installed, with Talk or with Talk stopped, which never blocks «Siguiente»; the passphrase is no longer served once installed (R48)",
                  st == 200 and a_medias["contenedores"] == [
                      ["Servidor web", "en marcha"], ["Núcleo de la suite", "iniciando"], ["Base de datos", "en marcha"],
                      ["Caché", "iniciando"], ["Notificaciones al instante", "en espera"], ["Oficina", "en marcha"],
                      ["Talk", "detenido"]]
                  and a_medias["en_marcha"] is False and a_medias["instalada"] is False
                  and a_medias["frase"] == "frase uno dos"
                  and st2 == 200 and completa["instalada"] is True and completa["frase"] == ""
                  and st3 == 200 and sin_talk["instalada"] is True and ["Talk", "detenido"] in sin_talk["contenedores"])
            with open(os.path.join(AIO_STATE, "dominio"), "w", encoding="utf-8") as fh:
                fh.write('x"; id; "\n')
            hostil = dominio_actual()
            with open(os.path.join(AIO_STATE, "dominio"), "w", encoding="utf-8") as fh:
                fh.write("gestion.clinica.example\n")
            listo = screen_listo()
            os.remove(os.path.join(AIO_STATE, "dominio"))
            sin = screen_listo()
            try:
                deis.write_site(find_row("113314"), SNAPSHOT, "113314", [], [], path=os.path.join(tmp, "hostil.sh"),
                                domain='x"; id; "')
                rechaza_hostil = False
            except SystemExit:
                rechaza_hostil = True
            check("suite: the recorded domain is only ever a domain — a hostile record reads as none and write_site refuses it; «Listo» names the staff's address when there is one",
                  hostil == "" and rechaza_hostil and not os.path.exists(os.path.join(tmp, "hostil.sh"))
                  and "Acceso del personal: <b>https://gestion.clinica.example</b>" in listo
                  and "Acceso del personal" not in sin)
            with tempfile.TemporaryDirectory() as sd:
                deis.write_site(find_row("113314"), SNAPSHOT, "113314", team_lines("sector", "sector-", ["Norte"]), [],
                                path=os.path.join(sd, "a.sh"), domain="gestion.clinica.example")
                deis_site_text = open(os.path.join(sd, "a.sh"), encoding="utf-8").read()
            check("suite: a new site file carries the domain the wizard took",
                  '\nSITE_DOMINIO="gestion.clinica.example"\n' in deis_site_text)
            SUITE.update(estado="sin_preparar", hechos=[], motivo="")
            for f in os.listdir(AIO_STATE):   # the fake's files go: later arms see a step 7 not yet prepared
                os.remove(os.path.join(AIO_STATE, f))
            planilla = os.path.join(deis.HERE, "..", "sites", "113314", "planilla-mia.csv")
            rc, out = stepped(["--paso", "usuarios", "--codigo", "113314", "--planilla", planilla])
            check("--paso usuarios: the loaded planilla re-validates — sealed once, 0 new passwords",
                  rc == 0 and "✓ Planilla validada: 2 usuarios; administrador inicial elena.diaz" in out
                  and ": 0 nuevas (personas y cargos)" in out)
            broken = os.path.join(tempfile.mkdtemp(), "rota.csv")
            open(broken, "w", encoding="utf-8").write("usuario;nombre;apellidos\nroto;a;b\n")
            rc, out = stepped(["--paso", "usuarios", "--codigo", "113314", "--planilla", broken])
            check("--paso usuarios: a broken planilla reds with its line errors, exit 1",
                  rc == 1 and "✗ línea 1:" in out)
            sin_admin = os.path.join(tempfile.mkdtemp(), "sin-admin.csv")
            open(sin_admin, "w", encoding="utf-8").write(
                "usuario;nombre;apellidos;correo;grupos;primer_admin\nluz.1;Luz;Uno;;role-medico;no\n"
                "sol.2;Sol;Dos;;grupo-x;no\n")
            rc, out = stepped(["--paso", "usuarios", "--codigo", "113314", "--planilla", sin_admin])
            check("--paso usuarios: a whole-file error has no line; an unknown group lists the valid ones (R38)",
                  rc == 1 and "✗ ninguna fila tiene primer_admin = sí" in out and "línea 0" not in out
                  and "  grupos válidos: " in out and "sector-estrella" in out)
            rc, out = stepped(["--paso", "usuarios", "--codigo", "113314", "--planilla", broken + ".nada"])
            check("--paso usuarios: an unreadable planilla names its path and why, in Spanish, exit 1",
                  rc == 1 and "✗ no se pudo leer la planilla" in out and out.rstrip().endswith(": no existe"))
            rcs = [stepped(a)[0] for a in (["--paso"], ["--paso", "nada", "--codigo", "113314"],
                                           ["--otra"], ["--paso", "usuarios", "--codigo", "113314"],
                                           ["--paso", "generar", "--codigo", "--revision"])]
            check("--paso: a missing value, an unknown step, an unknown option, no planilla, a flag as a value — exit 2",
                  rcs == [2, 2, 2, 2, 2])
            latin = os.path.join(tempfile.mkdtemp(), "latin.csv")
            open(latin, "wb").write("usuario;nombre\nñandú;a\n".encode("latin-1"))
            rc, out = stepped(["--paso", "usuarios", "--codigo", "113314", "--planilla", latin])
            check("--paso usuarios: a planilla not in UTF-8 is named, exit 1",
                  rc == 1 and "✗ la planilla" in out and "no está en UTF-8" in out)
            real_generar = globals()["api_generar"]

            def stubbed(fn, argv):
                globals()["api_generar"] = fn
                try:
                    return stepped(argv)
                finally:
                    globals()["api_generar"] = real_generar
            ejecutar = ["--paso", "generar", "--codigo", "113314"]
            empty, drift, busy, lines, bare = (stubbed(lambda _p, a=a: a, ejecutar) for a in (
                (200, {"modo": "ejecutar", "divergencia_vacia": True}),
                (200, {"modo": "ejecutar", "divergencia_vacia": False}),
                (409, {"error": "ya hay una ejecución en curso"}),
                (400, {"errores": [{"linea": 3, "error": "grupo desconocido"}]}),
                (500, {})))
            check("--paso generar: an empty divergence exits 0, a drift exits 1 naming the fix, a refused run exits 1 with its reason",
                  empty[0] == 0 and "✓ divergencia vacía" in empty[1]
                  and drift[0] == 1 and "✗ divergencia NO vacía" in drift[1]
                  and "sudo aps-conecta abrir" in drift[1]
                  and busy[0] == 1 and "✗ ya hay una ejecución en curso" in busy[1])
            check("--paso generar: line errors alone print no generic line; a bare refusal names its status",
                  lines[0] == 1 and "✗ línea 3: grupo desconocido" in lines[1]
                  and "el paso falló" not in lines[1]
                  and bare[0] == 1 and "✗ el paso falló (código 500)" in bare[1])

            def denied(_payload):
                raise PermissionError(13, "Permission denied", "/srv/x/.env")
            rc, out = stubbed(denied, ejecutar)
            check("--paso generar: an unreadable file is a Spanish ✗ line and exit 1, not a traceback",
                  rc == 1 and "✗ no se pudo acceder a /srv/x/.env (sin permiso)" in out)
            ran = []
            usage = [stubbed(lambda p: ran.append(p) or (200, {}), a) for a in (
                ["--paso", "generar"], ejecutar + ["--planilla", planilla],
                ["--paso", "usuarios", "--codigo", "113314", "--planilla", planilla, "--revision"])]
            check("--paso: no código, or a flag the step does not take — exit 2 naming it, nothing run",
                  [r for r, _ in usage] == [2, 2, 2] and not ran
                  and "✗ falta el código" in usage[0][1]
                  and "✗ --planilla no aplica a --paso generar" in usage[1][1]
                  and "✗ --revision no aplica a --paso usuarios" in usage[2][1])
            p = subprocess.run([sys.executable, os.path.abspath(__file__), "--paso", "generar"],
                               capture_output=True, text=True, timeout=60)
            check("--paso as a real process: the exit code and the Spanish line reach a pipe (systemd's view)",
                  p.returncode == 2 and "✗ falta el código" in p.stdout)
            check("titles: every phase file has its Spanish console title (R42)",
                  {f[:-3] for f in os.listdir(os.path.dirname(PHASE20))
                   if f[:1].isdigit() and f.endswith(".sh")} == set(PHASE_TITLES))
            given = open(site_path("113314"), encoding="utf-8").read()
            assert given.count('SITE_DOMINIO=""') == 1
            given = given.replace('SITE_DOMINIO=""', 'SITE_DOMINIO="clinica.example"')
            real_here, fresh = deis.HERE, tempfile.mkdtemp()
            os.makedirs(os.path.join(fresh, "scripts"))
            deis.HERE = os.path.join(fresh, "scripts")
            try:
                src = os.path.join(fresh, "site-dado.sh")

                def given_site(text):
                    open(src, "w", encoding="utf-8").write(text)
                    return stepped(["--paso", "sitio", "--archivo", src])
                first, again, bom = given_site(given), given_site(given), given_site("﻿" + given)
                sin_dominio = given_site(given.replace('SITE_DOMINIO="clinica.example"', 'SITE_DOMINIO=""'))
                mala_cat = given_site(given.replace("SITE_ROLES=(", 'SITE_ROLES=(\n  "role-x|X|cat-foo"', 1))
                placed = open(os.path.join(fresh, "sites", "113314", "site.sh"), encoding="utf-8").read()
                differs = given_site(given + "# editado\n")
                other = given_site(given.replace("SITE_DEIS=113314", "SITE_DEIS=121567"))
                sin_deis = given_site(given.replace("SITE_DEIS=113314", "SITE_DEIS=x"))
                roto = given_site(given.replace("SITE_TEAMS=(", "SITE_TEAMS=(\n  roto sin cierre", 1))
                usage = [stepped(a)[0] for a in (["--paso", "sitio"],
                                                 ["--paso", "sitio", "--archivo", src, "--codigo", "1"])]
            finally:
                deis.HERE = real_here
            check("--paso sitio: an operator's site.sh is placed at sites/<DEIS>/, byte for byte; the same file again is a re-run",
                  first[0] == 0 and "✓ Sitio cargado: sites/113314/site.sh (DEIS 113314)" in first[1]
                  and placed == given and again[0] == 0 and "✓ Sitio ya cargado" in again[1]
                  and bom[0] == 0 and "✓ Sitio ya cargado" in bom[1])
            check("--paso sitio: no SITE_DOMINIO, or a site role in a category that does not exist, is refused at step 6",
                  sin_dominio[0] == 1 and "SITE_DOMINIO" in sin_dominio[1]
                  and mala_cat[0] == 1 and "role-x → cat-foo" in mala_cat[1])
            check("--paso sitio: a different file for the same centre, or a second centre, is refused — never overwritten",
                  differs[0] == 1 and "difiere del archivo entregado" in differs[1]
                  and other[0] == 1 and "un solo establecimiento" in other[1]
                  and placed == open(os.path.join(fresh, "sites", "113314", "site.sh"), encoding="utf-8").read())
            check("--paso sitio: no SITE_DEIS, or an unreadable array, is refused naming «el sitio», not a temp path; usage exits 2",
                  sin_deis[0] == 1 and "SITE_DEIS=<código DEIS" in sin_deis[1]
                  and roto[0] == 1 and "el sitio" in roto[1] and "/tmp" not in roto[1]
                  and usage == [2, 2])
            drift = stubbed(lambda _p: (200, {"modo": "ejecutar", "divergencia_vacia": False, "salida": ""}),
                            ejecutar + ["--resumen"])
            early = stubbed(lambda _p: (409, {"error": "no hay planilla cargada"}), ejecutar + ["--resumen"])
            ran = stubbed(lambda _p: (500, {"error": "FATAL: algo", "salida": "x"}), ejecutar + ["--resumen"])
            check("generar --resumen: a red gate points at the log, not «arriba»; the log is named only when the executor ran",
                  drift[0] == 1 and "la deriva se muestra en el registro (" in drift[1] and "arriba" not in drift[1]
                  and early[0] == 1 and "registro completo" not in early[1]
                  and ran[0] == 1 and "registro completo:" in ran[1])

            st, _ = generar("ejecutar-x")
            st2, _ = api_generar({"codigo": "../etc", "modo": "revision"})
            check("generar: a junk modo and a traversal codigo answer 400", st == 400 and st2 == 400)

            st, body = api_generar({"codigo": "121567", "modo": "revision"})
            check("generar: a site never written answers 404 with the next step",
                  st == 404 and "primero guarde los equipos" in body.get("error", "")
                  and "site.sh" not in body["error"])
            # a site without a roster needs a tree without 113314's — one install, one establishment
            real_here, sin_planilla = deis.HERE, tempfile.mkdtemp()
            os.makedirs(os.path.join(sin_planilla, "scripts"))
            deis.HERE = os.path.join(sin_planilla, "scripts")
            try:
                st0, _ = api_sitio({"codigo": "121567", "sectors": [], "programs": []})
                st, body = api_generar({"codigo": "121567", "modo": "revision"})
                st2, _ = api_generar({"codigo": "121567", "modo": "ejecutar"})
            finally:
                deis.HERE = real_here
                shutil.rmtree(sin_planilla)
            check("generar: a site without a roster answers 409 naming the planilla",
                  st0 == 200 and st == 409 and "no hay planilla cargada" in body.get("error", ""))
            check("estado: a run refused before it starts is red too — the record carries its cause (a10)",
                  st2 == 409 and "· ✗ la ejecución no terminó\n  · no hay planilla cargada"
                  in open(ESTADO_PATH, encoding="utf-8").read())

            roster_mia = os.path.join(deis.HERE, "..", "sites", "113314", "planilla-mia.csv")
            good_roster = open(roster_mia, encoding="utf-8").read()
            open(roster_mia, "w", encoding="utf-8").write(
                good_roster + "intruso.99;Sin;Contraseña;;all-staff;no\n")
            st, body = generar("revision")
            check("generar: a hand-added unsealed uid answers 409 naming it",
                  st == 409 and "intruso.99" in body.get("error", ""))
            open(roster_mia, "w", encoding="utf-8").write(
                "usuario;nombre;apellidos\nroto;a;b\n")
            st, body = generar("revision")
            check("generar: a hand-broken roster re-validates — the upload screen's own line errors",
                  st == 400 and body["errores"][0]["linea"] == 1
                  and "usuario;nombre;apellidos;correo;grupos;primer_admin" in body["errores"][0]["error"])
            open(roster_mia, "w", encoding="utf-8").write(good_roster)
            sheet_text = open(CRED_PATH, encoding="utf-8").read()
            open(CRED_PATH, "w", encoding="utf-8").write(
                "".join(ln for ln in sheet_text.splitlines(True) if not ln.startswith("director;")))
            st, body = generar("revision")
            open(CRED_PATH, "w", encoding="utf-8").write(sheet_text)
            check("generar: a cargo the site declares without a sealed password answers 409 naming the site, not the planilla",
                  st == 409 and body.get("error", "").startswith("el sitio declara cargos sin contraseña sellada: director"))

            env_path = os.path.join(deis.HERE, "..", ".env")
            open(env_path, "w", encoding="utf-8").write("SITE=otro-lugar\n")
            st, body = generar("revision")
            check("generar: an .env naming another establishment refuses at review time (D13)",
                  st == 409 and "otro-lugar" in body.get("error", "") and "migre" in body.get("error", ""))
            os.remove(env_path)

            st, body = generar("ejecutar")
            if st != 200:  # B-028: abort with the seed's own output — never a bare .index() ValueError
                return seed_died(body, "generar: ejecutar runs the whole world green — the seed died (output above)")
            check("generar: ejecutar runs the whole world green — 14 phases, 2 roster users, gate clean",
                  st == 200 and body["ok"] and body["divergencia_vacia"]
                  and "14 phase(s) run" in body["salida"] and "== roster: 2 usuario(s) ==" in body["salida"]
                  and "user elena.diaz added to group admin" in body["salida"]
                  and "nada en la instancia que el repositorio no declare" in body["divergencia"])
            estado = open(ESTADO_PATH, encoding="utf-8").read()
            check("estado: a green execution leaves its verdict, readable without sudo (0644), in Santiago time (a10)",
                  re.match(r"\d{4}-\d\d-\d\d \d\d:\d\d \(hora de Santiago\) · ✓ la instancia coincide con lo declarado\n$", estado)
                  and oct(os.stat(ESTADO_PATH).st_mode & 0o777) == "0o644")
            env_text = open(env_path, encoding="utf-8").read()
            check("generar: ejecutar converges .env — SITE written, fixtures forced, fixture password generated, 0600",
                  "SITE=113314" in env_text and "SEED_FIXTURES=1" in env_text
                  and re.search(r"^FIXTURE_USER_PASSWORD=[0-9a-f]{24}$", env_text, re.M)
                  and oct(os.stat(env_path).st_mode & 0o777) == "0o600"
                  and body["env"]["SITE"] == "escrito")
            log = stub_log_text()
            oc = [l for l in log.splitlines() if "OC_PASS" in l]
            sealed_now = sealed_map(CRED_PATH)
            check("generar: OC_PASS rides docker exec -e only on user:add — the sealed passwords delivered",
                  len(oc) >= 2 and all("user:add" in l and "--password-from-env" in l for l in oc)
                  and "inspect" not in log
                  and all(any(sealed_now[u][0] in l for l in oc)
                          for u in ("maria.perez", "elena.diaz")))
            check("generar: the AIO arm — no document-server URL writes, the gestion-only keys still set",
                  "DocumentServerUrl" not in log and "sameTab" in log
                  and "trusted_domains" not in log
                  and "belong to the entrypoint" in body["salida"])
            check("generar: the password policy's breach check is off — no password, nor its hash prefix, leaves the server (R28)",
                  "config:app:set password_policy enforceHaveIBeenPwned --value=0" in log)
            check("generar: the AIO arm — Talk off in the suite: phase 12 asks the suite and installs no spreed (R29)",
                  "printenv TALK_ENABLED" in log and "spreed skipped" in body["salida"]
                  and "app spreed" not in body["salida"])
            # B-030: phase 50 creates the standing accounts AFTER phase 41 mapped the registry
            # groups into the engine's, so the FIRST seed must map them too — or the second seed
            # writes (Clean boot's seed-idempotent) and every fresh install converges one run late
            fixture_pw = re.search(r"^FIXTURE_USER_PASSWORD=([0-9a-f]{24})$", env_text, re.M).group(1)
            check("generar: each cargo account is created with its own sealed password — never the shared one (a8)",
                  all(any(l.rstrip().endswith(f" {u}") and sealed_now[u][0] in l for l in oc)
                      for u in cargos_113314)
                  and not any(fixture_pw in l for l in oc))
            check("generar: a planilla user joins all-staff and the category of each role — only the role written (a8)",
                  "user elena.diaz added to group all-staff" in body["salida"]
                  and "user elena.diaz added to group cat-clinicos" in body["salida"]
                  and "user elena.diaz added to group role-matroneria" in body["salida"])
            check("generar: the roster driver maps planilla users into the IntraVox groups the same run (B-030's class)",
                  "group: elena.diaz added to group IntraVox Users" in body["salida"]
                  and "group: maria.perez added to group IntraVox Users" in body["salida"])
            cats = role_categories(PHASE20, [("role-jefe-sar", "Jefe/a de SAR", "cat-jefaturas"),
                                             ("role-medico", "Médico", "cat-jefaturas")])
            fams = [c for r, c in cats.items() if r != "role-jefe-sar"]
            check("registry: the 22 shared roles name their category — 4 jefaturas, 10 clínicos, 3 técnicos, 5 administrativos; a site role adds its own, never overrides",
                  len(fams) == 22 and [fams.count(f"cat-{k}") for k in
                                       ("jefaturas", "clinicos", "tecnicos", "administrativos")] == [4, 10, 3, 5]
                  and cats["role-quimico-farmaceutico"] == "cat-clinicos"
                  and cats["role-jefe-sar"] == "cat-jefaturas" and cats["role-medico"] == "cat-clinicos")
            try:
                role_categories(junk20, [])
                floor = False
            except ValueError as e:
                floor = "declaran su categoría" in str(e)
            check("registry: a phase 20 whose roles lost their category is refused, not guessed", floor)
            check("generar: the first seed maps the standing accounts into the IntraVox groups (B-030)",
                  "group: director added to group IntraVox Users" in body["salida"]
                  and "group: director added to group IntraVox Editors" in body["salida"])

            env_before = open(env_path, "rb").read()
            open(stubctl, "w", encoding="utf-8").write("TALK_ENABLED=yes\n")
            buf = io.StringIO()
            with redirect_stdout(buf):
                st, body = api_generar({"codigo": "113314", "modo": "ejecutar", "resumen": True})
            if st != 200:  # B-028: same guard on the re-run — its FATAL, not a ValueError
                return seed_died(body, "generar: a re-run converges — the re-run seed died (output above)")
            drv = body["salida"][body["salida"].index("== provisioning complete"):]  # safe: seed green above
            check("generar: a re-run converges — .env byte-stable, driver noops, gate clean",
                  st == 200 and open(env_path, "rb").read() == env_before
                  and "user maria.perez exists" in drv and "user maria.perez created" not in drv
                  and "user elena.diaz exists" in drv and body["divergencia_vacia"])
            console = buf.getvalue()
            log_text = open(os.path.join(deis.HERE, "..", ".install.log"), encoding="utf-8").read()
            check("generar --resumen: one Spanish line per phase and the roster's count on the console, the whole log in .install.log (R42)",
                  "  ✓ Grupos: roles, categorías y equipos\n" in console
                  and "  ✓ Planilla: 2 personas\n" in console
                  and console.count("  ✓ ") == len(PHASE_TITLES) + 1
                  and all(ln.startswith("  ✓ ") for ln in console.splitlines() if ln.strip())
                  and "▶ phase" not in console and "user " not in console
                  and "▶ phase 20-groups" in log_text and "== roster: 2 usuario(s) ==" in log_text)
            seed2 = body["salida"][:body["salida"].index("== provisioning complete")]
            check("generar: the re-run seed maps no standing account again (B-030)",
                  "group: director added to group IntraVox" not in seed2
                  and "group: jefe." not in seed2)
            check("generar: Talk on in the suite — phase 12 installs spreed (R29)",
                  "app spreed" in seed2 and "spreed skipped" not in seed2)
            open(stubctl, "w").close()

            site_text = open(site_path("113314"), encoding="utf-8").read()
            assert "SITE_ROLES=(\n" in site_text
            open(site_path("113314"), "w", encoding="utf-8").write(
                site_text.replace("SITE_ROLES=(\n", 'SITE_ROLES=(\n  "role-x|X|cat-foo"\n', 1))
            st, body = generar("ejecutar")
            open(site_path("113314"), "w", encoding="utf-8").write(site_text)
            check("generar: a failing phase answers its own cause, not the runner's «phase failed» line",
                  st == 500 and body["error"].startswith("FATAL: SITE_ROLES entry 'role-x' names category 'cat-foo'"))
            check("estado: a run that stopped before the gate leaves its cause",
                  "· ✗ la ejecución no terminó\n  · FATAL: SITE_ROLES entry 'role-x'" in open(ESTADO_PATH, encoding="utf-8").read())
            open(stubstate, "w").close()
            open(stublog, "w").close()
            open(stubctl, "w", encoding="utf-8").write("FAIL_ON=group:add\n")
            st, body = generar("ejecutar")
            check("generar: a failing phase stops the run — 500 naming it, the gate never fires",
                  st == 500 and "FATAL: phase 20-groups.sh failed" == body["error"]
                  and "user:list" not in stub_log_text())
            open(stubctl, "w").close()
            open(stubctl, "w", encoding="utf-8").write("FAIL_ON=printenv\n")
            st, body = generar("ejecutar")
            check("generar: the suite's Talk switch unreadable stops phase 12 — never read as Talk off (R29)",
                  st == 500 and body["error"].startswith("FATAL: could not read the suite's Talk switch")
                  and "spreed skipped" not in body["salida"])
            open(stubctl, "w").close()

            open(stubctl, "w", encoding="utf-8").write("GATE_EXTRA=intruso.9\n")
            st, body = generar("ejecutar")
            check("generar: a red gate is data — vacia False with the note naming the account",
                  st == 200 and body["divergencia_vacia"] is False
                  and "intruso.9" in body["divergencia"])
            estado = open(ESTADO_PATH, encoding="utf-8").read()
            check("estado: a red gate leaves each item with its fix, in Spanish (a10)",
                  "· ✗ deriva: la instancia tiene lo que no se declaró\n" in estado
                  and "  · el usuario 'intruso.9' existe pero no está declarado" in estado
                  and "occ user:delete intruso.9" in estado)
            open(stubctl, "w").close()

            EXEC_LOCK.acquire()
            st, body = generar("ejecutar")
            EXEC_LOCK.release()
            check("generar: one run at a time — a second concurrent ejecutar answers 409",
                  st == 409 and "en curso" in body.get("error", ""))

            open(stubctl, "w", encoding="utf-8").write("SLOW=1\n")
            old_timeouts = dict(TIMEOUTS)
            TIMEOUTS.update({"seed": 2, "roster": 2, "gate": 2})
            st, body = generar("ejecutar")
            TIMEOUTS.clear()
            TIMEOUTS.update(old_timeouts)
            open(stubctl, "w").close()
            check("generar: the bound kills a hung seed — the 500 carries the partial log",
                  st == 500 and "excedió" in body["error"] and len(body["salida"]) > 0)

            open(stubstate, "w").close()
            open(stublog, "w").close()
            open(stubctl, "w", encoding="utf-8").write("PS_MODE=empty\n")
            st, body = generar("ejecutar")
            check("the compose arm: with no office keys the OFFICE_PORT gate fires inside the branch",
                  st == 500 and "FATAL: phase 14-office.sh failed" == body["error"]
                  and "OFFICE_PORT" in body["salida"])
            env_lines = open(env_path, encoding="utf-8").read().splitlines()
            env_lines += ["OFFICE_PORT=9980", "OFFICE_JWT_SECRET=" + "a" * 40]
            open(env_path, "w", encoding="utf-8").write("\n".join(env_lines) + "\n")
            st, body = generar("ejecutar")
            check("the compose arm: with the office keys the URL writes return",
                  st == 200 and "DocumentServerUrl" in stub_log_text()
                  and "jwt_secret -> (value not printed)" in body["salida"])
            check("the compose arm: Talk is the stack's own — spreed installs, the suite is never asked (R29)",
                  st == 200 and "app spreed" in body["salida"] and "printenv" not in stub_log_text())
            open(stubctl, "w").close()
            open(env_path, "w", encoding="utf-8").write(
                "\n".join(l for l in env_lines if not l.startswith("OFFICE_")) + "\n")

            rc = subprocess.run(["bash", "-n", os.path.join(deis.HERE, "..", "provisioning", "usuarios.sh")],
                                capture_output=True).returncode
            check("the driver parses: bash -n provisioning/usuarios.sh is clean", rc == 0)
            check("the bounds are explicit: TIMEOUTS seed/roster/gate/suite = 1800/1800/300/900",
                  TIMEOUTS == {"seed": 1800, "roster": 1800, "gate": 300, "suite": 900})

            STEPS[:] = read_steps()
            LAN_IP, HOSTNAME, PORT = "127.0.0.1", "servidor-prueba", port

            # ── slice 17: the UI (FRD S6) — the eight screens, the cookie arm, the estado leg ──
            # A browser-shaped client: http.client (no auto-redirect, the Cookie header set by
            # hand) — the API's Bearer client above stays the API's.

            class Browser:
                def __init__(self, token):
                    self.token = token
                    self.cookie = None

                def req(self, method, path, body=None):
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                    headers = {"Content-Type": "application/json"}
                    if self.cookie:
                        headers["Cookie"] = self.cookie
                    conn.request(method, path, body, headers)
                    r = conn.getresponse()
                    text = r.read().decode("utf-8", "replace")
                    setc = r.getheader("Set-Cookie")
                    conn.close()
                    return r.status, text, dict(r.getheaders()), setc

            errlog = io.StringIO()  # the request log under redirect_stderr — the URL rule's oracle
            b = Browser(TOKEN)
            with redirect_stderr(errlog):
                st, text, hdr, setc = b.req("GET", "/login")
            check("login: the sign-in page — es-CL, the code field, the link's fragment read and wiped first",
                  st == 200 and "text/html" in hdr.get("Content-Type", "")
                  and 'lang="es"' in text and "Código de acceso" in text and 'type="password"' in text
                  and 'get("acceso")' in text and "history.replaceState" in text
                  and text.index("const ACCESO") < text.index("</head>")
                  and TOKEN not in text)

            with redirect_stderr(errlog):
                st, text, hdr, setc = b.req("POST", "/api/login",
                                            json.dumps({"token": "0" * 64}))
                check("login: a wrong token answers 401 and sets no cookie",
                      st == 401 and setc is None)

                st, text, hdr, setc = b.req("POST", "/api/login",
                                            json.dumps({"token": TOKEN}))
                check("login: the code exchanges for an HttpOnly, Secure, SameSite=Strict cookie",
                      st == 200 and setc and TOKEN_COOKIE + "=" in setc
                      and "HttpOnly" in setc and "Secure" in setc and "SameSite=Strict" in setc
                      and TOKEN not in text)

                st, text, hdr, setc = b.req("GET", "/contenedores")
                check("screens: without a cookie the step routes redirect to the door",
                      st == 302 and hdr.get("Location") == "/login")

                b.cookie = f"{TOKEN_COOKIE}=valor-basura"
                st, text, hdr, setc = b.req("GET", "/contenedores")
                check("screens: a garbage cookie also redirects — constant-time, both arms",
                      st == 302 and hdr.get("Location") == "/login")

                b.cookie = f"{TOKEN_COOKIE}={TOKEN}"
                for path, marca in (("/bienvenida", "Sesión iniciada desde servidor-prueba"),
                                    ("/contenedores", "Preparar el asistente"),
                                    ("/centro", "Confirmar centro"),
                                    ("/equipos", "Planilla de personas"),
                                    ("/revision", "Crea los grupos, las carpetas y las cuentas")):
                    st, text, hdr, setc = b.req("GET", path)
                    check(f"screens: {path} renders with the cookie arm",
                          st == 200 and marca in text and "text/html" in hdr.get("Content-Type", ""))
                nodo = shutil.which("node")
                bloques, sueltos = set(), 0
                for ruta in ROUTES:
                    pagina = b.req("GET", ruta)[1]
                    hallados = re.findall(r"<script>(.*?)</script>", pagina, re.S)
                    sueltos += pagina.count("<script") - len(hallados)   # a block this reader would skip
                    bloques.update(hallados)
                if nodo:
                    malos = []
                    for js in bloques:
                        r = subprocess.run([nodo, "--check"], input=js, capture_output=True, text=True, timeout=30)
                        if r.returncode:
                            malos.append(next((x for x in r.stderr.splitlines() if "Error" in x), r.stderr[:200]))
                    for m in malos:
                        print("    node:", m[:200])
                    check(f"screens: every rendered script parses — node --check over {len(bloques)} blocks (CI has node, not a browser)",
                          len(bloques) > 1 and sueltos == 0 and not malos)
                else:
                    print("  skip: script syntax arm — node is not installed")
                st, centro_html, hdr, setc = b.req("GET", "/centro")
                check("centro: the search folds like deis.fold, every term counts, every type offered (R36)",
                      's.normalize("NFD").replace(/[\\u0300-\\u036f]/g, "").toLowerCase()' in centro_html
                      and "qs.every((t) => x.k.includes(t))" in centro_html
                      and "const F = {reg: -1, com: -1, tipo: -1};" in centro_html)
                tsv = subprocess.run(["bash", HOST_CLI, "pasos"], capture_output=True, text=True,
                                     timeout=10).stdout
                titulos = [line.split("\t")[1] for line in tsv.splitlines()]
                st, text, hdr, setc = b.req("GET", "/contenedores")
                pos = [text.find(f'<span class="t">{html.escape(t)}</span>') for t in titulos]
                check("screens: the rail is «aps-conecta pasos» — every title in order, «Iniciar la suite» current as Paso 7 de 9 (a11)",
                      len(titulos) == 9 and -1 not in pos and pos == sorted(pos)
                      and "Paso 7 de 9 · en su navegador" in text
                      and 'aria-current="step"><span class="n" aria-hidden="true">7</span>' in text
                      and "SCREENS" not in globals())

                st, text, hdr, setc = b.req("GET", "/api/suite")
                check("suite: the cookie arm serves an API route — the stub's containers answer by name, never cached",
                      st == 200 and ["Núcleo de la suite", "en marcha"] in json.loads(text)["contenedores"]
                      and hdr.get("Cache-Control") == "no-store")

                st, text, hdr, setc = b.req("GET", "/")
                st2, text2, hdr2, _ = b.req("GET", "/api/salud")
                check("screens: GET / opens the sign-in page even with the cookie; /api/salud stays the identity JSON (R33)",
                      st == 302 and hdr.get("Location") == "/login"
                      and st2 == 200 and "application/json" in hdr2.get("Content-Type", "")
                      and SERVICE in text2)
                st, text, hdr, setc = b.req("GET", "/login")
                check("screens: a signed-in browser at the door goes to the welcome",
                      st == 302 and hdr.get("Location") == "/bienvenida")
                st, text, hdr, setc = b.req("GET", "/listo")
                DONE.set()
                st2, text2, hdr2, _ = b.req("GET", "/listo")
                DONE.clear()
                check("screens: «Listo» exists only after a green execution — the port it closes named, the motto on the backdrop",
                      st == 302 and hdr.get("Location") == "/bienvenida"
                      and st2 == 200 and "Instalador cerrado: enlace inválido, puerto" in text2
                      and f"puerto {port} cerrado" in text2 and MOTTO in text2)
                check("screens: the motto is phase 15's theming slogan (one string, three homes, pinned)",
                      any(f'"{MOTTO}"' in line and "theming_set slogan" in line for line in
                          open(os.path.join(ROOT_DIR, "provisioning", "phases", "15-branding.sh"),
                               encoding="utf-8")))
                b.cookie = None
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                conn.request("GET", "/recursos/fraunces.woff2")
                r = conn.getresponse()
                fuente = r.read()
                tipo = r.getheader("Content-Type")
                conn.close()
                with open(os.path.join(ROOT_DIR, ASSETS["fraunces.woff2"][0]), "rb") as fh:
                    igual = fh.read() == fuente
                st, _t, _h, _s = b.req("GET", "/recursos/../provisionador.py")
                st2, _t, _h, _s = b.req("GET", "/recursos/nada.woff2")
                check("assets: the brand fonts serve locally without a session; any other name is a 404; every whitelisted file exists",
                      r.status == 200 and tipo == "font/woff2" and igual and st == 404 and st2 == 404
                      and all(os.path.isfile(os.path.join(ROOT_DIR, rel)) for rel, _t in ASSETS.values()))
                b.cookie = f"{TOKEN_COOKIE}={TOKEN}"


                gone = [b.req("GET", r)[0] for r in ("/sectores", "/componentes", "/planilla")]
                st, equipos_html, hdr, setc = b.req("GET", "/contenedores")
                check("screens: step 8 is one screen — the three old routes are gone, the suite hands off to /equipos (a16)",
                      gone == [404, 404, 404] and 'location.href = "/equipos"' in equipos_html)
                st, rev_html, hdr, setc = b.req("GET", "/revision")
                with open(os.path.join(ROOT_DIR, "host", "aps-conecta.timer"), encoding="utf-8") as fh:
                    semanal = re.search(r"^OnCalendar=(.*)$", fh.read(), re.M).group(1)
                with open(os.path.join(ROOT_DIR, "host", "aps-conecta-tiles.timer"), encoding="utf-8") as fh:
                    mensual = re.search(r"^OnCalendar=(.*)$", fh.read(), re.M).group(1)
                check("screens: step 9 is one screen — /divergencia is gone; the maintenance it states is the timers' own (Sun 03:00, day 4 05:00)",
                      b.req("GET", "/divergencia")[0] == 404
                      and semanal.startswith("Sun *-*-* 03:00") and "domingo 03:00" in rev_html
                      and mensual.startswith("*-*-04 05:00") and "día 4, 05:00" in rev_html)

                st, plan, hdr, setc = b.req("GET", "/equipos")
                check("planilla: the browser decode-or-warn rides the screen (bytes, utf-8 fatal, cp1252)",
                      st == 200 and "arrayBuffer" in plan
                      and 'TextDecoder("utf-8", {fatal: true})' in plan
                      and 'TextDecoder("windows-1252")' in plan
                      and "Windows-1252" in plan and "CSV UTF-8" in plan)
                check("planilla: the line-numbered error table is the render contract",
                      "<th>Línea</th><th>Error</th>" in plan and "primer_admin" in plan
                      and "Los cargos" in plan)

                css_ok = all(tok in plan for tok in
                             ("#7f21fe", "#5315a8", "#6b01fa", "#ea003e", "#e06f00",
                              "#101828", "#485363"))
                check("screens: the D1 tokens ride the CSS", css_ok)
                check("screens: no literal provisionador address or port — relative links only, no token",
                      "http://127.0.0.1" not in plan and ":8081" not in plan
                      and ":8082" not in plan and ":8083" not in plan and TOKEN not in plan
                      and 'zona("e-sig").onclick' in plan)

                lleva = [r for r in ROUTES if re.search(r"\?codigo=|URLSearchParams\(location\.search\)|'\s*\+\s*location\.search",
                                                        b.req("GET", r)[1])]
                check("screens: no code rides a URL — the later steps read the centre from the server (L3 S2)",
                      lleva == [] and "const codigo = await centro();" in b.req("GET", "/revision")[1])

                errlog.seek(0)
                logged = errlog.read()
                check("screens: the request log is silent — no path, no token, no timeout trace (R42)",
                      logged == "")

            # docker-absent arm: estado answers a fix hint, never a traceback
            saved_path = os.environ["PATH"]
            os.environ["PATH"] = "/nonexistent-dir-for-test"
            st_hint, body_hint = contenedores()
            os.environ["PATH"] = saved_path
            check("suite: a missing docker answers a 500 fix hint, never a hang or traceback",
                  st_hint == 500 and "no se encontró el comando docker" in body_hint["error"])
            # ── L3 S1: HTTPS with the installer's own certificate (a13), the second installer (R33) ──
            CERT_DIR = os.path.join(tmp, "certificados")
            ctx1, hu1 = tls_context("127.0.0.1")
            with open(os.path.join(CERT_DIR, "ca.crt"), "rb") as fh:
                ca_pem = fh.read()
            ctx2, hu2 = tls_context("127.0.0.1")
            with open(os.path.join(CERT_DIR, "ca.crt"), "rb") as fh:
                ca_kept = fh.read() == ca_pem
            check("tls: the CA is made once and kept; the leaf is re-signed on every start",
                  ca_kept and hu1 != hu2)
            check("tls: both private keys are 0600, the directory 0700; the fingerprint is 32 hex pairs",
                  all(os.stat(os.path.join(CERT_DIR, k)).st_mode & 0o777 == 0o600
                      for k in ("ca.key", "instalador.key"))
                  and os.stat(CERT_DIR).st_mode & 0o777 == 0o700
                  and re.fullmatch(r"(?:[0-9A-F]{2}:){31}[0-9A-F]{2}", hu2) is not None)
            check("tls: the link's address is an IPv4 the kernel routes by",
                  re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", lan_ip()) is not None)
            ts, tport = bind_server("127.0.0.1", (0,))
            ts.socket = ctx2.wrap_socket(ts.socket, server_side=True, do_handshake_on_connect=False)
            threading.Thread(target=ts.serve_forever, daemon=True).start()
            confia = ssl.create_default_context(cafile=os.path.join(CERT_DIR, "ca.crt"))
            with urllib.request.urlopen(f"https://127.0.0.1:{tport}/api/salud", context=confia,
                                        timeout=10) as r:
                salud = json.loads(r.read().decode("utf-8"))
            check("tls: the address verifies against the installer's CA — /api/salud over HTTPS",
                  salud.get("servicio") == SERVICE)
            plano = io.StringIO()
            with redirect_stderr(plano):
                try:
                    c = http.client.HTTPConnection("127.0.0.1", tport, timeout=5)
                    c.request("GET", "/api/salud")
                    c.getresponse()
                    en_claro = True
                except (OSError, http.client.HTTPException):
                    en_claro = False
                with urllib.request.urlopen(f"https://127.0.0.1:{tport}/api/salud", context=confia,
                                            timeout=10) as r:
                    sigue = r.status == 200
            check("tls: plain HTTP gets no answer, the console stays quiet, the server keeps serving",
                  not en_claro and plano.getvalue() == "" and sigue)
            check("second installer: a running one is found by its identity, a plain stranger is not",
                  running_installer((tport,)) == tport and running_installer((port,)) is None)
            with open(os.path.join(HERE, "..", "host", "aps-conecta"), encoding="utf-8") as fh:
                prov = re.search(r'^PROV_PORTS="([0-9 ]+)"', fh.read(), re.MULTILINE)
            check("ports: the host probe's chain is the server's own (PROV_PORTS = PORTS, one fact pinned)",
                  prov is not None and tuple(map(int, prov.group(1).split())) == PORTS)
            saved_path = os.environ["PATH"]
            os.environ["PATH"] = os.path.join(tmp, "empty")   # exists, holds nothing
            try:
                tls_context("127.0.0.1")
                sin_openssl = ""
            except SystemExit as e:
                sin_openssl = str(e)
            finally:
                os.environ["PATH"] = saved_path
            check("tls: no openssl stops the start before any socket, naming the package",
                  "falta openssl" in sin_openssl and "apt-get install openssl" in sin_openssl)

            # the fragment login in a real browser (a13) — where Playwright is installed (this box,
            # the L7 boxes); elsewhere the arm says so and is not counted
            try:
                from playwright.sync_api import sync_playwright
            except ImportError:
                sync_playwright = None
                print("  skip: browser arms — playwright is not installed "
                      "(pip install playwright; playwright install chromium)")
            if sync_playwright:
                with sync_playwright() as pw:
                    nav = pw.chromium.launch()
                    try:
                        visto = nav.new_context(ignore_https_errors=True)
                        pg = visto.new_page()
                        errores = []
                        pg.on("pageerror", lambda e: errores.append(str(e)))
                        pg.on("console", lambda m: errores.append(m.text) if m.type == "error" else None)
                        try:
                            pg.goto(f"https://127.0.0.1:{tport}/login#acceso={TOKEN}")
                            pg.wait_for_url("**/bienvenida", timeout=10000)
                            llego = True
                        except Exception as e:   # a Playwright timeout: the arm reports it
                            llego = False
                            errores.append(str(e))
                        galleta = next((c for c in visto.cookies() if c["name"] == TOKEN_COOKIE), {})
                        check("browser: the link signs in — the fragment leaves the address bar, the cookie is Secure and HttpOnly",
                              llego and "acceso" not in pg.url and galleta.get("secure") is True
                              and galleta.get("httpOnly") is True and not errores)
                        cargando = {"/contenedores": "Consultando el servidor",
                                    "/centro": "Cargando el registro",
                                    "/equipos": "Cargando los equipos",
                                    "/revision": "Preparando la revisión"}   # the centre from the server, then the plan
                        corrio = True
                        for ruta, texto in cargando.items():
                            try:
                                pg.goto(f"https://127.0.0.1:{tport}{ruta}")
                                pg.wait_for_function("t => !document.body.innerText.includes(t)",
                                                     arg=texto, timeout=10000)
                            except Exception as e:   # a Playwright timeout: the arm reports it
                                corrio = False
                                errores.append(f"{ruta}: {e}")
                        for ruta in ("/bienvenida",):
                            pg.goto(f"https://127.0.0.1:{tport}{ruta}")
                        check("browser: every page runs its script on load — the loading texts are replaced, no script or console error (R34)",
                              corrio and not errores)
                        # the cascade in a real browser on a tree with no site file (the choice is
                        # still free): región › comuna, an accent-blind search, the card, «Confirmar
                        # centro» — the code reaches the server and never the address bar
                        real_here, sin_sitio = deis.HERE, tempfile.mkdtemp()
                        os.makedirs(os.path.join(sin_sitio, "scripts"))
                        deis.HERE = os.path.join(sin_sitio, "scripts")
                        CENTRO = None
                        try:
                            pg.goto(f"https://127.0.0.1:{tport}/centro")
                            pg.wait_for_function("() => document.querySelector('#c-btn').innerText.includes('Elija un centro')",
                                                 timeout=10000)
                            tipo_inicial = pg.input_value("#f-tipo")

                            def filtro(sel, texto):
                                etiquetas = pg.eval_on_selector_all(f"{sel} option", "os => os.map(o => o.text)")
                                pg.select_option(sel, label=next(t for t in etiquetas if t.startswith(texto)))
                            pg.click("#c-btn")
                            pg.fill("#c-q", "ramon")
                            pg.click("#c-lista [data-c='121567']")
                            elegida = pg.input_value("#f-reg") != "-1" and pg.is_enabled("#c-ok")
                            filtro("#f-reg", "Metropolitana")   # excludes San Ramón: cleared, never swapped
                            limpia = pg.is_disabled("#c-ok") and pg.inner_text("#c-ficha").strip() == ""
                            filtro("#f-reg", "La Araucanía")
                            filtro("#f-com", "Padre Las Casas")
                            pg.click("#c-btn")
                            pg.fill("#c-q", "ramon")
                            pg.press("#c-q", "Enter")
                            ficha = pg.inner_text("#c-ficha")
                            pg.click("#c-ok")
                            pg.wait_for_url("**/contenedores", timeout=10000)
                            cascada = (tipo_inicial == "-1" and elegida and limpia
                                       and "codigo" not in pg.url and CENTRO == "121567"
                                       and all(t in ficha for t in (
                                           "Posta de Salud Rural", "121567", "Calle Caserío de San Ramón",
                                           "Padre Las Casas", "La Araucanía", "Servicio de Salud Araucanía Sur",
                                           "Municipal")))
                        except Exception as e:   # a Playwright timeout: the arm reports it
                            cascada = False
                            errores.append(str(e))
                        finally:
                            deis.HERE = real_here
                            shutil.rmtree(sin_sitio)
                            CENTRO = None
                        check("browser: Centro — every type by default; «ramon» finds San Ramón and sets its región; a filter that excludes it clears the choice; región › comuna, Enter, the card's seven fields; «Confirmar centro» holds the code server-side, none in the address (R36)",
                              cascada and not errores)
                        try:   # the fixture tree's own site: the centre is fixed
                            pg.goto(f"https://127.0.0.1:{tport}/centro")
                            pg.wait_for_selector("#m .aviso", timeout=10000)
                            fijo = (pg.is_disabled("#f-reg") and pg.is_disabled("#f-tipo")
                                    and pg.is_disabled("#c-btn") and pg.is_enabled("#c-ok")
                                    and "Cóndores de Chile" in pg.inner_text("#m"))
                            pg.click("#c-ok")
                            pg.wait_for_url("**/contenedores", timeout=10000)
                        except Exception as e:   # a Playwright timeout: the arm reports it
                            fijo = False
                            errores.append(str(e))
                        check("browser: a fixed centre locks the filters and the combobox; «Confirmar centro» just continues (D13)",
                              fijo and not errores)
                        # step 8 in a real browser on a fresh tree (a15): the ids under each list, a
                        # save, a different save is a conflict, «Reemplazar»; the centre's template
                        # downloaded and uploaded back; an unknown group opens «Grupos válidos». The
                        # 409 and 400 it provokes on purpose are the browser's own console lines.
                        real_here, real_cred, previos = deis.HERE, CRED_PATH, len(errores)
                        previo_centro = CENTRO
                        with tempfile.TemporaryDirectory() as eqb:
                            deis.HERE = os.path.join(eqb, "scripts")
                            os.makedirs(deis.HERE)
                            CRED_PATH = os.path.join(eqb, "credenciales.txt")
                            CENTRO = "121567"
                            try:
                                pg.goto(f"https://127.0.0.1:{tport}/equipos")
                                pg.wait_for_function("() => !document.body.innerText.includes('Cargando los equipos')",
                                                     timeout=10000)
                                oculto = pg.is_hidden("#e-plant")   # no template before the teams
                                pg.fill("#e-sec", "Norte\nSector Sur")
                                pg.fill("#e-prog", "Cardiovascular")
                                pg.wait_for_selector("#e-sec-g .chip >> text=sector-sur", timeout=10000)
                                chips = pg.inner_text("#e-sec-g") + " " + pg.inner_text("#e-prog-g")
                                pg.click("#e-guardar")
                                pg.wait_for_selector("#e-conf .ok", timeout=10000)
                                pg.fill("#e-sec", "Norte\nOriente")
                                pg.click("#e-guardar")
                                pg.wait_for_selector("#e-reemp", timeout=10000)
                                conflicto = pg.inner_text("#e-conf")
                                pg.click("#e-reemp")
                                pg.wait_for_selector("#e-conf .ok", timeout=10000)
                                with pg.expect_download() as bajada:
                                    pg.click("#e-plant")
                                plantilla_csv = bajada.value.path()
                                pg.set_input_files("#archivo", plantilla_csv)
                                pg.click("#f button")
                                pg.wait_for_selector("#e-sig", timeout=10000)
                                tabla, sellado = pg.inner_text("#e-tabla"), pg.inner_text("#m")
                                mala = os.path.join(eqb, "mala.csv")
                                with open(mala, "w", encoding="utf-8") as fh:
                                    fh.write("usuario;nombre;apellidos;correo;grupos;primer_admin\n"
                                             "luz.1;Luz;Uno;;sector-inexistente;sí\n")
                                pg.set_input_files("#archivo", mala)
                                pg.click("#f button")
                                pg.wait_for_selector("#m .error", timeout=10000)
                                abiertos = pg.eval_on_selector("#e-validos-box", "d => d.open")
                                validos = pg.inner_text("#e-validos")
                                pg.set_input_files("#archivo", plantilla_csv)
                                pg.click("#f button")
                                pg.wait_for_selector("#e-sig", timeout=10000)
                                pg.click("#e-sig")
                                pg.wait_for_url("**/revision", timeout=10000)
                                paso8 = (oculto and "sector-norte" in chips and "sector-sur" in chips
                                         and "prog-cardiovascular" in chips
                                         and "Nuevos: Sector Oriente" in conflicto
                                         and "Quitados: Sector Sur" in conflicto
                                         and "ana.rojas" in tabla and "pedro.munoz" in tabla
                                         and "quedan selladas y se entregan al final" in sellado
                                         and "/" not in sellado
                                         and abiertos and "sector-oriente" in validos and "role-medico" in validos)
                            except Exception as e:   # a Playwright timeout: the arm reports it
                                paso8 = False
                                errores.append(str(e))
                            finally:
                                deis.HERE, CRED_PATH, CENTRO = real_here, real_cred, previo_centro
                        provocados = [x for x in errores[previos:] if re.search(r"status of (409|400)", x)]
                        propios = [x for x in errores[previos:] if x not in provocados]
                        del errores[previos:]
                        errores.extend(propios)
                        # exactly the two it provokes: the conflict (409) and the unknown group (400)
                        paso8 = paso8 and sorted(re.search(r"status of (\d+)", x).group(1)
                                                 for x in provocados) == ["400", "409"]
                        check("browser: step 8 — ids under each list, save, a different save is a conflict, «Reemplazar»; the centre's template uploads back clean; an unknown group opens «Grupos válidos» (R35, R38, a15)",
                              paso8 and not errores)
                        # step 9 in a real browser: the plan in clinic terms; «Ejecutar» on a run
                        # that reports one phase, then a red verdict — the progress, the head line, the
                        # way to the detail; a reload finds the verdict where it was (a14, a16)
                        # step 8 hands off to /revision under a fixture that is gone by now: a late
                        # answer from that page is not this arm's, so it judges its own lines only
                        pg.goto("about:blank")
                        desde = len(errores)
                        verdadero, suelta = globals()["api_generar"], threading.Event()

                        def lento(p):   # the plan is real; the run reports a phase and waits
                            if p.get("modo") != "ejecutar":
                                return verdadero(p)
                            avance("✓ phase 05-security\n")
                            suelta.wait(30)
                            return 200, {"modo": "ejecutar", "divergencia_vacia": False,
                                         "divergencia": "    algo de más\n"}
                        globals()["api_generar"] = lento
                        EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)
                        try:
                            pg.goto(f"https://127.0.0.1:{tport}/revision")
                            pg.wait_for_selector("#x-plan dl", timeout=15000)
                            plan_txt = pg.inner_text("#x-plan")
                            pg.wait_for_selector("#x-ir:enabled", timeout=10000)
                            pg.click("#x-ir")
                            pg.wait_for_selector(".lista-estado .hecho", timeout=10000)
                            avance_txt = pg.inner_text("#x-prog")
                            pg.reload()   # mid-run: the page finds the run and follows it
                            pg.wait_for_selector(".lista-estado .hecho", timeout=15000)
                            sigue = pg.is_disabled("#x-ir") and not pg.query_selector("#x-error .error")
                            suelta.set()
                            pg.wait_for_selector("#x-prog .error", timeout=10000)
                            veredicto_txt = pg.inner_text("#x-prog")
                            principal = pg.inner_text("#contenido")
                            pg.reload()
                            pg.wait_for_selector("#x-prog .error", timeout=15000)
                            recargado = pg.inner_text("#x-prog")
                            # a16 over everything step 9 shows: no app id, no file, no key, no jargon
                            ids = "|".join([a for a, _n, _q in COMPONENTES] + list(PLUMBING_APPS))
                            jerga = re.findall(rf"\b(?:{ids})\b|idempotente|\.sh\b|\.env\b|/|"
                                               r"\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b", principal)
                            paso9 = ("Cóndores de Chile, El Bosque · DEIS 113314" in plan_txt
                                     and "Sector Estrella" in plan_txt and "elena.diaz" in plan_txt
                                     and "maria.perez" in plan_txt and "Chat y videollamadas internas" in plan_txt
                                     and "domingo 03:00" in plan_txt and "unos minutos" in principal
                                     and jerga == [] and sigue
                                     and "Seguridad de sesión" in avance_txt and "Comprobación final" in avance_txt
                                     and "✗ deriva" in veredicto_txt and "aps-conecta estado" in veredicto_txt
                                     and "algo de más" not in veredicto_txt
                                     and "✗ deriva" in recargado
                                     and pg.locator(".lista-estado .hecho").count() == 2
                                     and pg.inner_text("#x-ir") == "Volver a ejecutar")
                        except Exception as e:   # a Playwright timeout: the arm reports it
                            paso9 = False
                            errores.append(str(e))
                        finally:
                            suelta.set()
                            globals()["api_generar"] = verdadero
                            EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)
                        check("browser: step 9 — the plan in clinic terms, «Ejecutar» followed by polling and through a reload mid-run, a red verdict's head and the way to its detail (no gate notes), nothing a16 forbids on the page (R40, a14, a16)",
                              paso9 and not errores[desde:])
                        # step 7 in a real browser (L3 S5): the apps and Talk's verdict; a refusal that gives
                        # the form back; «Preparar el asistente» on the fake host command, with progress in
                        # under 2 s; a reload; the passphrase and the link; the containers to «Siguiente»;
                        # nothing a16 forbids in any state (R26, a12, R48, a16)
                        pg.goto("about:blank")
                        desde = len(errores)
                        aio_antes = AIO_STATE
                        AIO_STATE = os.path.join(tempfile.mkdtemp(), "aio")
                        os.makedirs(AIO_STATE)
                        fijo7 = centro_actual()[1].get("codigo")   # the site the preparation fills, then restored
                        antes7 = open(site_path(fijo7), encoding="utf-8").read() if fijo7 else None
                        globals()["SUITE_CMD"] = ["bash", falso]
                        SUITE.update(estado="sin_preparar", hechos=[], motivo="")
                        try:
                            open(stubctl, "w", encoding="utf-8").write("PS_MODE=empty\n")
                            pg.goto(f"https://127.0.0.1:{tport}/contenedores")
                            pg.wait_for_selector("#s-apps table", timeout=15000)
                            apps_txt, talk_txt = pg.inner_text("#s-apps"), pg.inner_text("#s-talk")
                            antes_txt = pg.inner_text("#contenido")
                            pg.fill("#s-dom", "rechazado.example")
                            pg.click("#s-ir")
                            pg.wait_for_selector("#s-error .error", timeout=15000)
                            error_txt = pg.inner_text("#s-error")
                            pg.wait_for_selector("#s-ir:enabled", timeout=10000)
                            de_nuevo = pg.is_visible("#s-form")
                            pg.fill("#s-dom", "gestion.clinica.example")
                            pg.check("#s-sinval")
                            pg.click("#s-ir")
                            pg.wait_for_selector("#s-prep li", state="attached", timeout=2000)   # a12: within 2 s
                            prep_txt = pg.inner_text("#s-prep") + pg.inner_text("#s-nota")
                            pg.wait_for_selector("#s-abrir", timeout=15000)
                            datos_txt = pg.inner_text("#s-datos")
                            espera_txt = pg.inner_text("#s-linea")
                            pg.reload()
                            pg.wait_for_selector("#s-abrir", timeout=15000)
                            recargado7 = pg.inner_text("#s-datos")
                            open(stubctl, "w", encoding="utf-8").write("PS_LISTA=" + ";".join(
                                f"{c}:Up 3 minutes" for c, _n in CONTENEDORES_SUITE + CONTENEDORES_TALK[:1]) + "\n")
                            pg.wait_for_selector("#s-sig-fila:not([hidden])", timeout=15000)
                            principal7 = pg.inner_text("#contenido")
                            sin_abrir = pg.query_selector("#s-abrir") is None   # no wait: it is gone
                            pg.click("#s-sig")
                            pg.wait_for_url("**/equipos", timeout=10000)
                            ids7 = "|".join([a for a, _n, _q in COMPONENTES] + list(PLUMBING_APPS))
                            jerga7 = re.findall(rf"\b(?:{ids7})\b|idempotente|\.sh\b|\.env\b|/|"
                                                r"\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b",
                                                antes_txt + error_txt + prep_txt + datos_txt + espera_txt + principal7)
                            paso7 = ("Inicio" in apps_txt and "3.1.7" in apps_txt and "Territorio" in apps_txt
                                     and "Talk: cabe" in talk_txt and "Grabación: no cabe" in talk_txt
                                     and "requiere 4 núcleos libres; hay 4 en total" in talk_txt
                                     and "El asistente rechazó la dirección" in error_txt and de_nuevo
                                     and "Asistente en marcha" in prep_txt
                                     and "frase uno dos" in datos_txt and "gestion.clinica.example" in datos_txt
                                     and "frase uno dos" in recargado7
                                     and "Esperando «Iniciar» en el asistente" in espera_txt
                                     and "✓ Suite en marcha: 7 contenedores." in principal7 and jerga7 == []
                                     and sin_abrir)
                        except Exception as e:   # a Playwright timeout: the arm reports it
                            paso7 = False
                            errores.append(str(e))
                        finally:
                            globals()["SUITE_CMD"] = verdadero_cmd
                            open(stubctl, "w").close()
                            AIO_STATE = aio_antes
                            SUITE.update(estado="sin_preparar", hechos=[], motivo="")
                            if fijo7:
                                write_site_text(site_path(fijo7), antes7)
                        check("browser: step 7 — the five apps with versions, Talk's verdict, a refusal that gives the form back, «Preparar el asistente» with progress in 2 s, a reload, the passphrase and the wizard's link, the containers to «Siguiente»; nothing a16 forbids (R26, a12, R48, a16)",
                              paso7 and not errores[desde:])
                        # step 7's edges in a real browser: the data block stays put while the page polls (the
                        # passphrase can be selected, the link clicked); a suite already running shows its
                        # progress and no form; the freeze's refusal is said, never swallowed
                        pg.goto("about:blank")
                        desde = len(errores)
                        aio_antes = AIO_STATE
                        AIO_STATE = os.path.join(tempfile.mkdtemp(), "aio")
                        os.makedirs(AIO_STATE)
                        try:
                            for nombre, texto in (("dominio", "gestion.clinica.example\n"),
                                                  ("opciones", "talk=1 grabacion=0\n"), ("master.pw", "frase uno dos")):
                                with open(os.path.join(AIO_STATE, nombre), "w", encoding="utf-8") as fh:
                                    fh.write(texto)
                            open(stubctl, "w", encoding="utf-8").write("PS_MODE=empty\n")
                            pg.goto(f"https://127.0.0.1:{tport}/contenedores")
                            pg.wait_for_selector("#s-abrir", timeout=15000)
                            pg.evaluate("window.__abrir = document.getElementById('s-abrir')")
                            pg.wait_for_timeout(2500)
                            quieto = pg.evaluate("window.__abrir.isConnected")
                            for nombre in os.listdir(AIO_STATE):
                                os.remove(os.path.join(AIO_STATE, nombre))
                            open(stubctl, "w", encoding="utf-8").write("PS_LISTA=nextcloud-aio-apache:Up 1 minute\n")
                            pg.goto(f"https://127.0.0.1:{tport}/contenedores")
                            pg.wait_for_selector("#s-prog:not([hidden])", timeout=15000)
                            ya_corre = pg.is_hidden("#s-form") and pg.is_hidden("#s-datos")
                            open(stubctl, "w", encoding="utf-8").write("PS_MODE=empty\n")
                            DONE.set()
                            pg.goto(f"https://127.0.0.1:{tport}/contenedores")
                            pg.wait_for_selector("#s-form:not([hidden])", timeout=15000)
                            pg.fill("#s-dom", "gestion.clinica.example")
                            pg.click("#s-ir")
                            pg.wait_for_selector("#s-error .aviso", timeout=10000)
                            congelado = pg.inner_text("#s-error")
                        except Exception as e:   # a Playwright timeout: the arm reports it
                            quieto, ya_corre, congelado = False, False, ""
                            errores.append(str(e))
                        finally:
                            DONE.clear()
                            open(stubctl, "w").close()
                            AIO_STATE = aio_antes
                        provocados = [x for x in errores[desde:] if re.search(r"status of 409", x)]
                        propios = [x for x in errores[desde:] if x not in provocados]
                        del errores[desde:]
                        errores.extend(propios)
                        check("browser: step 7's edges — the passphrase and the link stay the same nodes while the page polls; a suite already running shows its progress, no form and no claimed configuration; the freeze's refusal is said (its one 409 the only console line)",
                              quieto is True and ya_corre and "ya terminó" in congelado and len(provocados) == 1
                              and not errores[desde:])
                        limpio = nav.new_context(ignore_https_errors=True).new_page()
                        limpio.goto(f"https://127.0.0.1:{tport}/")
                        en_login = limpio.url.endswith("/login") and "Código de acceso" in limpio.content()
                        try:   # the full link pasted into that open page: only the fragment changes
                            limpio.goto(f"https://127.0.0.1:{tport}/login#acceso={TOKEN}")
                            limpio.wait_for_url(lambda u: "/login" not in u and "acceso" not in u,
                                                timeout=10000)
                            pegado = True
                        except Exception:   # a Playwright timeout: the arm reports it
                            pegado = False
                        check("browser: the address without the fragment opens the sign-in page, never JSON; the full link pasted there signs in",
                              en_login and pegado)
                    finally:
                        nav.close()
            # ── L3 S1: a green «Revisar y ejecutar» closes the installer (SEC-2, a13) ──
            fin, fport = bind_server("127.0.0.1", (0,))
            fin.grace = 0.2
            DONE.clear()
            servido = []
            hilo = threading.Thread(target=lambda: servido.append(serve(fin)), daemon=True)
            hilo.start()
            verdadero = globals()["api_generar"]

            def ejecutar_http(vacia):
                globals()["api_generar"] = lambda _p: (200, {"modo": "ejecutar",
                                                              "divergencia_vacia": vacia})
                EJECUCION.update(estado="sin_ejecutar")
                try:
                    req = urllib.request.Request(
                        f"http://127.0.0.1:{fport}/api/generar", method="POST",
                        data=json.dumps({"codigo": "113314", "modo": "ejecutar"}).encode(),
                        headers={"Content-Type": "application/json",
                                 "Authorization": f"Bearer {TOKEN}"})
                    with urllib.request.urlopen(req, timeout=10) as r:
                        st = r.status
                    for _ in range(100):   # the worker's verdict, before the stub goes
                        if EJECUCION["estado"] == "terminada":
                            break
                        time.sleep(0.05)
                    return st, DONE.is_set()   # DONE as the poll first sees the verdict (SEC-2)
                finally:
                    globals()["api_generar"] = verdadero
                    EJECUCION.update(estado="sin_ejecutar", hechos=[], veredicto=None)

            st, al_terminar = ejecutar_http(False)
            time.sleep(0.5)
            check("finish: a red verdict keeps the installer open for the correction",
                  st == 202 and not al_terminar and hilo.is_alive() and not DONE.is_set())
            st, al_terminar = ejecutar_http(True)
            hilo.join(5)
            try:
                socket.create_connection(("127.0.0.1", fport), timeout=2).close()
                cerrado = False
            except OSError:
                cerrado = True
            check("finish: a green verdict closes the port within the grace and serve() answers 0",
                  st == 202 and al_terminar and not hilo.is_alive() and DONE.is_set() and cerrado and servido == [0])
            st, body = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar"})
            st_v, body_v = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar", "vista": True})
            st_u, _ = call("POST", "/api/usuarios", {"codigo": "113314", "csv": "x", "vista": True})
            st_s, body_s = call("POST", "/api/suite", {"dominio": "gestion.clinica.example"})
            check("finish: once done, «Preparar el asistente» is refused 409 too",
                  st_s == 409 and "ya terminó" in body_s.get("error", ""))
            check("finish: once done, a second execution inside the grace is refused 409 — nothing runs twice, «vista» or not",
                  st == 409 and "ya terminó" in body.get("error", "")
                  and st_v == 409 and "ya terminó" in body_v.get("error", "") and st_u == 409)

            class Interrumpido:   # Ctrl+C arriving while serve_forever runs
                def serve_forever(self):
                    raise KeyboardInterrupt

                def server_close(self):
                    pass

            with redirect_stdout(io.StringIO()):
                tarde = serve(Interrumpido())
                DONE.clear()
                temprano = serve(Interrumpido())
            check("finish: Ctrl+C inside the grace after a green run still answers 0; before it, 130",
                  tarde == 0 and temprano == 130)
            DONE.clear()
            ts.shutdown()
            ts.server_close()
            httpd.shutdown()
            httpd.server_close()
    finally:
        deis.HERE = old
        CRED_PATH, PHASE20 = old_cred, old_p20
        CERT_DIR = old_cert
        AIO_STATE = old_aio
        globals().update(recursos=reales[0], puerto_libre=reales[1])
        os.environ.update(_scrubbed)
        # the stub world closes with the fixture: the PATH injection and the FAKE_DOCKER_* knobs
        # are self-test machinery and must not leak into the caller's environment
        os.environ["PATH"] = old_path
        for key in ("FAKE_DOCKER_LOG", "FAKE_DOCKER_STATE", "FAKE_DOCKER_CONTROL"):
            os.environ.pop(key, None)

    if bad:
        print(f"\nself-test: {len(bad)} de {n} checks fallaron:")
        for name in bad:
            print(f"  FAIL: {name}")
        return 1
    print(f"\nself-test: {n} checks OK")
    return 0


def main(argv):
    if "--self-test" in argv:
        return selftest()
    if "--paso" in argv:
        sys.stdout.reconfigure(line_buffering=True)   # the phases stream live to a pipe (systemd)
        return run_step(argv)
    global TOKEN, LAN_IP, HOSTNAME, PORT
    # The banner is the operator's only copy of the link, and `aps-conecta abrir` and systemd both
    # PIPE this stdout — block-buffered, a piped banner is invisible (measured: the smoke driver read
    # nothing). Line-buffered is correct for a thing that must be read the moment it prints.
    sys.stdout.reconfigure(line_buffering=True)
    load_register()                        # fail fast: no register, no wizard, no socket
    STEPS[:] = read_steps()                # …no step list, no rail
    otro = running_installer()             # …a second installer refuses before it re-signs the first one's leaf
    if otro:
        sys.exit(f"✗ el instalador web ya está abierto en el puerto {otro}\n"
                 "  → use el enlace de su consola, o ciérrelo (Ctrl+C en su consola; sin consola: "
                 "sudo pkill -f 'provisionador.py$') y vuelva a ejecutar: sudo aps-conecta abrir")
    LAN_IP, HOSTNAME = lan_ip(), socket.gethostname()
    ctx, fingerprint = tls_context(LAN_IP)  # …no certificate, no link
    TOKEN = secrets.token_hex(32)           # 64 hex chars — the env-init size, via the stdlib CSPRNG
    httpd, PORT = bind_server("", PORTS)   # all interfaces: the LAN reaches it, loopback probes too
    # the handshake runs in the handler thread (its 30 s timeout), never in the accept loop
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
    banner(f"https://{LAN_IP}:{PORT}/login#acceso={TOKEN}", fingerprint)
    return serve(httpd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
