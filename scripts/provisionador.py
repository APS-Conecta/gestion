#!/usr/bin/env python3
"""Provisionador — the host-side wizard that walks an operator from a fresh AIO install to a
provisioned clinic (FRD S5 core + S6 screens).

  scripts/provisionador.py               serve the API + UI (bearer token printed at start)
  scripts/provisionador.py --self-test   the FRD's named self-tests; exit 0 green / 1 red

The operator flow, one establishment per install (D13): Centro → sectores/programas →
componentes → CSV usuarios → revisar/dry-run → divergencia vacía. This file is built across
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
# Phase 20 IS the group registry — parsed, never restated (registry_groups below).
PHASE20 = os.path.join(HERE, "..", "provisioning", "phases", "20-groups.sh")
# Where the sealed credentials sheet lives (FRD S5; the host bundle's directory — S7 wires
# /opt/aps-conecta into backups). The self-test redirects it; this default is the only literal.
CRED_PATH = "/opt/aps-conecta/credentials.txt"
ESTADO_PATH = "/opt/aps-conecta/estado.txt"   # the last execution's verdict (a10): 0644, «aps-conecta estado»

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
# Every executor subprocess is bounded (B-015: a phase that hangs must not hang a thread forever).
# The seed's bound is the harness's pull budget (30 min); the roster driver rides the same number —
# a big clinic's N×0.8 s execs fit with margin; the gate only reads. The self-test patches this
# dict for its timeout arm instead of a test-only env knob.
TIMEOUTS = {"seed": 1800, "roster": 1800, "gate": 300}
# The silent install's console (R42): one Spanish line per finished phase, keyed by the phase
# file's stem — a self-test arm pins one title per file in provisioning/phases.
PHASE_TITLES = {
    "05-security": "Seguridad de sesión", "06-jobs": "Tareas programadas",
    "07-certs": "Certificados intermedios", "10-locale": "Idioma y región (es-CL)",
    "12-apps": "Aplicaciones de la suite", "14-office": "Oficina (Euro-Office)",
    "15-branding": "Imagen de APS Conecta", "16-app-policy": "Aplicaciones por perfil",
    "20-groups": "Grupos: roles, categorías y equipos", "30-folders": "Carpetas compartidas",
    "40-acl": "Permisos de las carpetas", "41-intravox": "Portada (IntraVox)",
    "50-users": "Cuentas de cargo", "60-fixtures": "Contenido de ejemplo"}


STUB_DOCKER = r'''#!/usr/bin/env python3
"""The stub docker — the test.sh #143 stub pattern as a PATH binary, for the executor's de-risk
and self-test. Answers the seed/phases/driver/gate world against a state file, so a RE-RUN sees
what the first run created (users, groups, memberships, folders): the executor's idempotent
re-run arms are load-bearing (the weekly timer rides them) and a stateless stub would fake them
red. Everything it does is logged to FAKE_DOCKER_LOG (one line per argv) — the OC_PASS delivery
and the AIO-arm arms grep THAT. Control knobs arrive via FAKE_DOCKER_CONTROL (python-assignable
lines), so the log stays a pure record: FAIL_ON (a word that makes any matching call exit 1 —
the fail-stop arm), GATE_EXTRA (a uid the user:list answer plants — the gate-red arm), PS_MODE
('empty' — the compose-arm), SLOW (sleep before answering — the timeout arm).
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
        print("nextcloud-aio-nextcloud\tUp 2 minutes")
        print("nextcloud-aio-database\tUp 2 minutes (healthy)")
    else:
        print("nextcloud-aio-nextcloud")
    sys.exit(0)
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
    """POST /api/sitio {"codigo", "sectors", "programs"} — write sites/<codigo>/site.sh via deis.py
    write_site: the establishment's whole truth in one standalone file, byte-identical to what
    `deis.py <codigo> --new <slug>` writes, with the slug being the codigo itself. One install, one
    establishment (D13): another centre's site file refuses 409 here as in the silent install."""
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
    # ponytail: check-then-write is not atomic across threads — one operator, one link; a lock shared
    # with api_centro if two ever drive one installer
    refused = one_establishment(codigo)   # D13 at step 8 too, not only in the silent install
    if refused:
        return refused

    path = site_path(codigo)
    if not os.path.exists(path):
        try:
            buf = io.StringIO()
            with redirect_stdout(buf):  # write_site's "wrote sites/…" line is the response, not noise
                deis.write_site(row, SNAPSHOT, codigo, sectors, programs)
            return 200, {"ok": True, "already": False, "site": _site_rel(codigo),
                         "written": buf.getvalue().strip()}
        except SystemExit:  # the refusal raced our look (threaded server) — settle it the same way
            pass
    return _site_exists_answer(codigo, path)


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
        raise ValueError(f"no se puede leer el registro de grupos ({path}) — falta en este "
                         "paquete de aprovisionamiento")
    ids = {m.group(1) for m in re.finditer(r'^ *"((?:role|cat)-[a-z0-9-]*)\|', text, re.M)}
    ids |= {m.group(1) for m in re.finditer(r"^ensure_group ([a-z0-9-]*)", text, re.M)}
    if len(ids) < 20:
        raise ValueError(f"solo {len(ids)} grupos compartidos se pudieron leer del registro "
                         f"({path}; se esperan 27: all-staff, 4 categorías cat-*, 22 roles "
                         "role-*) — cambió de forma; corríjalo antes de validar la planilla")
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
    out = subprocess.run(snippet, cwd=cwd, capture_output=True, text=True, check=True)
    reserved = {
        "admin": "la cuenta administradora que crea el asistente de instalación",
    }
    for uid in out.stdout.split():
        reserved.setdefault(uid, "cargo de la fase 50 (derivación compartida: standings.sh)")
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
                errors.append((start, f"el usuario «{uid}» es {reserved[uid]} — los cargos se "
                              "crean solos; quítelo de la planilla"))
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
                errors.append((start, "ingrese al menos un grupo, p. ej. all-staff"))
                ok = False
            for g in sorted(set(gids)):
                if g == "admin":
                    errors.append((start, "el grupo «admin» se asigna con la columna "
                                  "primer_admin, no en grupos"))
                    ok = False
                elif g not in universe:
                    errors.append((start, f"el grupo «{g}» no existe — use el registro "
                                  "compartido (fase 20) o los equipos y roles del sitio"))
                    ok = False
            p = deis.fold(primer)
            if p not in ("si", "no"):
                errors.append((start, f"primer_admin debe ser «si» o «no» — la fila dice "
                              f"«{primer}»"))
                ok = False
            elif p == "si":
                si_lines.append(start)
            if ok:
                rows.append((uid, nombre, apellidos, correo, tuple(sorted(set(gids))), p == "si"))
    except csv.Error as e:
        return [], [(1, f"la planilla no se puede leer como CSV: {e}")]
    if rows and len(si_lines) != 1:
        where = ", ".join(f"línea {n}" for n in si_lines) if si_lines else "ninguna"
        errors.append((si_lines[0] if si_lines else 2,
                       f"marque exactamente un primer_admin=si — hoy hay {len(si_lines)} "
                       f"({where})"))
    elif not rows and not errors:
        errors.append((2, "la planilla no trae usuarios — agregue filas bajo la cabecera"))
    return rows, errors


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
        return 404, {"error": f"no existe sites/{codigo}/site.sh — primero genere el sitio con "
                              "el paso de sectores y programas"}
    csv_text = payload.get("csv")
    if not isinstance(csv_text, str) or not csv_text.strip():
        return 400, {"error": "falta la planilla: envíe el texto CSV en el campo «csv»"}
    try:
        shared = registry_groups(PHASE20)
        teams, roles = site_arrays(site)
    except ValueError as e:
        return 400, {"error": str(e)}
    reserved = standing_uids(teams, roles)
    universe = shared | {gid for gid, _ in teams} | {gid for gid, _, _ in roles}

    rows, errors = roster_parse(csv_text.lstrip("\ufeff"), reserved, universe)
    if errors:
        return 400, {"ok": False, "errores": [{"linea": n, "error": m} for n, m in errors]}

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
        with open(site, "w", encoding="utf-8") as fh:
            fh.write(re.sub(r"(?m)^SITE_ROSTER=.*$", f"SITE_ROSTER={default_rel}",
                            site_text, count=1))
    primer_uid = next((uid for uid, _n, _a, _c, _g, p in rows if p), None)
    if primer_uid is None:
        # roster_parse enforces exactly-one; this is the belt-and-braces arm — a future edit that
        # breaks that rule must answer JSON, never crash a thread mid-request (the tamper-test
        # caught exactly this: an unguarded next() dropped the connection).
        return 500, {"error": "invariante rota: una planilla válida sin primer_admin=si — "
                              "repórtelo como error del Provisionador"}
    return 200, {"ok": True, "usuarios": len(rows), "primer_admin": primer_uid,
                 "roster": roster_rel, "credenciales": CRED_PATH,
                 "contrasenas_nuevas": fresh, "contrasenas_selladas": sealed}


def why(e):  # the OS's own text is English: the common cases in Spanish, else the errno name
    return {errno.ENOENT: "no existe", errno.EACCES: "sin permiso", errno.EISDIR: "es un directorio",
            errno.ENOSPC: "disco lleno"}.get(e.errno, errno.errorcode.get(e.errno, "error de archivo"))


def record_state(body):
    """The last execution's verdict, for «aps-conecta estado» and the admins' notification (a10): a
    head line — the time in Santiago and the verdict — then each item with its fix (the gate's own
    Spanish lines), or the cause of a run that stopped before the gate. 0644 and whole (tmp, then
    rename): readable without sudo, never half a state."""
    from datetime import datetime
    from zoneinfo import ZoneInfo
    if body.get("divergencia_vacia"):
        head, items = "✓ la instancia coincide con lo declarado", []
    elif "divergencia_vacia" in body:
        head = "✗ deriva: la instancia tiene lo que no se declaró"
        items = [ln[4:] for ln in body.get("divergencia", "").splitlines()
                 if ln.startswith("    ") and not ln.startswith("     ")]
        if not items:  # the gate stopped before its list (a FATAL): its own last lines are the cause
            head = "✗ la revisión de divergencia no terminó"
            items = [ln.strip() for ln in body.get("divergencia", "").splitlines() if ln.strip()][-3:]
    else:
        head, items = "✗ la ejecución no terminó", [body.get("error", "")]
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
        return 404, {"error": f"no existe sites/{codigo}/site.sh — primero genere el sitio con "
                              "el paso de sectores y programas"}
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
    reserved = standing_uids(teams, roles)
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
        return 400, {"ok": False, "errores": [{"linea": n, "error": m} for n, m in errors]}
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
        return 500, {"error": "invariante rota: una planilla válida sin primer_admin=si — "
                              "repórtelo como error del Provisionador"}
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
                     "divergencia": "se comprueba al final de la ejecución"}

    # ── ejecutar: one run at a time; the seed and the driver and the gate in order ──
    if not EXEC_LOCK.acquire(blocking=False):
        return 409, {"error": "ya hay una ejecución en curso — espere a que termine e inténtelo "
                              "de nuevo"}
    log = None
    try:
        if payload.get("resumen") is True:
            log = open(os.path.join(root, ".install.log"), "w", encoding="utf-8", buffering=1)
        show = summary(log) if log else None
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
    return telon("Listo", f"""<h1 tabindex="-1">Listo</h1>
<p class="para grande">Suite instalada en {esc(installed_centre())}.</p>
<p class="para">Instalador cerrado: enlace inválido, puerto {PORT} cerrado.</p>
<ul class="lista-sigue para"><li>Credenciales: en la consola del servidor; una fila por persona.</li>
<li>Re-provisión semanal: la activa la consola al cerrar el instalador.</li></ul>
<p class="lema">{MOTTO}</p>""")


def screen_contenedores():
    body = """<div class="tarjeta"><h2>Contenedores del asistente de instalación</h2>
<p>El asistente crea la instancia; el Provisionador la configura. Confirme que la suite esté
en marcha antes de continuar.</p><div id="m">Consultando el estado…</div></div>
<div class="tarjeta"><h2>Continuar</h2>
<p>Con la suite en marcha, siga con los equipos del establecimiento.</p>
<button onclick="location.href='/sectores'">Continuar</button></div>
<script>
(async () => {
  const r = await api("/api/estado");
  if (r.estado !== 200) {
    zona("m").innerHTML = '<div class="error">' + escapear(r.error) + "</div>"; return;
  }
  if (!r.contenedores.length) {
    zona("m").innerHTML = '<div class="error">No se encontró la instancia. ' +
      'Complete primero el asistente de instalación en el puerto 8080.</div>'; return;
  }
  zona("m").innerHTML = "<table><tr><th>Contenedor</th><th>Estado</th></tr>" +
    r.contenedores.map(c => "<tr><td>" + escapear(c.nombre) + "</td><td>" +
      escapear(c.estado) + "</td></tr>").join("") + "</table>";
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


def screen_sectores():
    body = """<div class="tarjeta"><h2>Sectores y programas</h2>
<p>El archivo del establecimiento se genera con sus equipos territoriales (sectores) y
programas de salud. Escriba un nombre por campo, separados por comas — por ejemplo
<code>Sector Estrella, Sector Cordillera</code>.</p>
<form id="f">
<label for="sectores">Sectores</label>
<input type="text" id="sectores" placeholder="Sector Estrella, Sector Cordillera">
<label for="programas">Programas</label>
<input type="text" id="programas" placeholder="Programa Cardiovascular, Programa Salud Mental">
<button type="submit">Generar el archivo del establecimiento</button></form>
<div id="m"></div></div>
<script>
centro();   // a missing centre shows its way back before any typing
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const codigo = await centro();
  if (!codigo) return;
  const corta = (s) => s.split(",").map(x => x.trim()).filter(x => x);
  const r = await api("/api/sitio", {codigo: codigo,
    sectors: corta(zona("sectores").value), programs: corta(zona("programas").value)});
  if (r.estado === 200) { location.href = "/componentes"; return; }
  zona("m").innerHTML = '<div class="error">' + escapear(r.error) + "</div>";
});
</script>"""
    return shell("equipos", body)


def screen_componentes():
    """The ALL-ON cards: the suite is one distribution (D12/D4) — everything the executor will
    provision, rendered from the live tree, nothing to choose. The one screen where 'no
    choices' is the honest design: the FRD's 'component cards ALL-ON'."""
    root = os.path.join(deis.HERE, "..")
    fases = sorted(p for p in os.listdir(os.path.join(root, "provisioning", "phases"))
                   if p[:1].isdigit() and p.endswith(".sh"))
    apps = sorted(os.listdir(os.path.join(root, "provisioning", "apps")))
    filas = "".join(f"<tr><td>{f}</td><td>Se ejecuta</td></tr>" for f in fases)
    apps_html = "".join(f"<code>{a}</code> " for a in apps)
    body = f"""<div class="tarjeta"><h2>Componentes de la suite</h2>
<p>La suite instala todo esto — es una sola distribución; no hay opciones que desactivar.
Las fases se ejecutan en orden, cada una idempotente.</p>
<table><tr><th>Fase</th><th>Estado</th></tr>{filas}</table></div>
<div class="tarjeta"><h2>Aplicaciones incluidas</h2><p>{apps_html}</p></div>
<div class="tarjeta"><h2>Continuar</h2>
<p>El siguiente paso carga la planilla de usuarios del establecimiento.</p>
<button onclick="location.href='/planilla'">Continuar</button></div>"""
    return shell("equipos", body)


def screen_planilla():
    body = """<div class="tarjeta"><h2>Planilla de usuarios</h2>
<p>Suba el archivo CSV con el personal. Las columnas, separadas por «;»:
<code>usuario;nombre;apellidos;correo;grupos;primer_admin</code>.
Marque exactamente una fila con <code>primer_admin=si</code>. Los cargos (dirección,
jefaturas) se crean solos — no los incluya.</p>
<form id="f"><label for="archivo">Archivo CSV</label>
<input type="file" id="archivo" accept=".csv,text/csv" required>
<button type="submit" disabled>Cargar y validar la planilla</button></form>
<div id="m"></div></div>
<script>
document.getElementById("archivo").addEventListener("change", (e) => {
  zona("f").querySelector("button").disabled = !e.target.files.length;
});
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const b = zona("f").querySelector("button"); b.disabled = true;
  const codigo = await centro();
  if (!codigo) { b.disabled = false; return; }
  const {texto, aviso} = await leerPlanilla(zona("archivo").files[0]);
  const r = await api("/api/usuarios", {codigo: codigo, csv: texto});
  if (r.estado === 200) {
    zona("m").innerHTML = (aviso ? '<div class="aviso">' + aviso + "</div>" : "") +
      '<div class="ok">Planilla validada: ' + r.usuarios + " usuario(s), primera " +
      "administración: <code>" + escapear(r.primer_admin) + "</code>. Contraseñas selladas en <code>" +
      escapear(r.credenciales) + "</code>.</div>" +
      '<p><button id="paso6">Continuar</button></p>';
    // The handler is ATTACHED, never inlined: a quoted onclick inside a built string is the
    // R2-caught syntax-error class.
    document.getElementById("paso6").onclick = () =>
      { location.href = "/revision"; };
    return;
  }
  b.disabled = false;
  const errores = (r.errores || [{linea: "", error: r.error || "Error inesperado"}]);
  zona("m").innerHTML = (aviso ? '<div class="aviso">' + aviso + "</div>" : "") +
    '<div class="error">Corrija la planilla y vuelva a subirla:</div><table><tr><th>Línea</th><th>Error</th></tr>' +
    errores.map(x => "<tr><td>" + escapear(x.linea) + "</td><td>" +
      escapear(x.error) + "</td></tr>").join("") + "</table>";
});
</script>"""
    return shell("equipos", body)


def screen_revision():
    body = """<div class="tarjeta"><h2>Revisión</h2>
<p>Revise el plan antes de ejecutar. La ejecución configura la instancia completa
(minutos); su avance se ve en la consola del servidor.</p>
<div id="m">Preparando la revisión…</div>
<button id="ejecutar" disabled>Ejecutar</button></div>
<script>
(async () => {
  const codigo = await centro();
  if (!codigo) return;
  const r = await api("/api/generar", {codigo: codigo, modo: "revision"});
  if (r.estado !== 200) {
    zona("m").innerHTML = '<div class="error">' + escapear(r.error || r.errores) + "</div>"; return;
  }
  zona("m").innerHTML = "<table>" +
    "<tr><th>Establecimiento</th><td>" + escapear(r.sitio) + "</td></tr>" +
    "<tr><th>Usuarios</th><td>" + r.usuarios + " (primera administración: <code>" +
      escapear(r.primer_admin) + "</code>)</td></tr>" +
    "<tr><th>Fases</th><td>" + r.fases.length + ": " + r.fases.join(", ") + "</td></tr>" +
    "<tr><th>Contraseñas</th><td>" + r.contrasenas_selladas + " selladas (personas y cargos)</td></tr>" +
    "<tr><th>.env</th><td>SITE " + escapear(r.env.SITE) + ", " + escapear(r.env.SEED_FIXTURES) +
      ", FIXTURE_USER_PASSWORD " + escapear(r.env.FIXTURE_USER_PASSWORD) + "</td></tr>" +
    "</table><p>La divergencia se comprueba al final de la ejecución.</p>";
  zona("ejecutar").disabled = false;
  zona("ejecutar").addEventListener("click", async () => {
    zona("ejecutar").disabled = true;
    zona("ejecutar").textContent = "Ejecutando… vea la consola";
    const r2 = await api("/api/generar", {codigo: codigo, modo: "ejecutar"});
    sessionStorage.setItem("resultado", JSON.stringify(r2));
    location.href = "/divergencia";
  });
})();
</script>"""
    return shell("ejecutar", body)


def screen_divergencia():
    body = """<div class="tarjeta"><h2>Divergencia</h2>
<div id="m">Cargando el resultado…</div>
<button onclick="location.href='/bienvenida'">Volver a la bienvenida</button></div>
<script>
(async () => {
  const r = JSON.parse(sessionStorage.getItem("resultado") || "null");
  if (!r) { zona("m").innerHTML =
    '<div class="aviso">No hay un resultado en esta sesión. Ejecute de nuevo desde la revisión.</div>'; return; }
  if (r.estado !== 200) {
    zona("m").innerHTML = '<div class="error">' + escapear(r.error) + "</div>" +
      "<pre>" + escapear((r.salida || "").split("\\n").slice(-12).join("\\n")) + "</pre>"; return;
  }
  if (r.divergencia_vacia) { location.replace("/listo"); return; }
  zona("m").innerHTML = '<div class="error"><strong>Hay divergencia.</strong> Revise las ' +
    "notas y corrija; luego vuelva a ejecutar desde la revisión.</div>" +
    "<pre>" + escapear(r.divergencia) + "</pre>";
})();
</script>"""
    return shell("ejecutar", body)


# The screens a signed-in browser reaches — path → renderer. A plain route table: each screen names
# its own registry step (shell(step_id, …)); the step list itself is STEPS, read from the host CLI.
ROUTES = {
    "/bienvenida": screen_bienvenida,
    "/centro": screen_centro,
    "/contenedores": screen_contenedores,
    "/sectores": screen_sectores,
    "/componentes": screen_componentes,
    "/planilla": screen_planilla,
    "/revision": screen_revision,
    "/divergencia": screen_divergencia,
}


def estado_contenedores():
    """The one new subprocess site besides run_tee: a single bounded `docker ps` filtered to
    nextcloud-aio-* — read-only, 5 s, the same argv shape smoke's check 1 and the AIO arm use.
    A missing docker binary or a dead daemon answers a fix-hint 500, never a hang."""
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
    conts = [{"nombre": n, "estado": s} for n, s in
             (l.split(tab, 1) for l in out.stdout.splitlines() if tab in l)]
    return 200, {"contenedores": conts}


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
        if path in ("/api/estado", "/api/centros", "/api/centro"):
            if not self.authorized():
                self.send_json(401, {"error": "token ausente o inválido"},
                               {"WWW-Authenticate": "Bearer"})
                return
            status, body = (estado_contenedores() if path == "/api/estado"
                            else api_centros() if path == "/api/centros" else centro_actual())
            self.send_json(status, body)
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
        if path == "/api/generar" and DONE.is_set():
            # SEC-2: the installer is done and closing — a reload and a second click inside the grace
            # must not start a run the shutdown would cut
            self.send_json(409, {"error": "la instalación ya terminó: el instalador se está cerrando"})
            return
        if path == "/api/centro":
            status, body = api_centro(payload)
        elif path == "/api/sitio":
            status, body = api_sitio(payload)
        elif path == "/api/usuarios":
            status, body = api_usuarios(payload)
        elif path == "/api/generar":
            status, body = api_generar(payload)
        else:
            status, body = 404, {"error": "ruta desconocida"}
        finished = (path == "/api/generar" and status == 200 and body.get("modo") == "ejecutar"
                    and body.get("divergencia_vacia") is True)
        if finished:
            # In the HTTP layer, never in api_generar: --paso generar (the silent install, the
            # weekly timer) shares that function and must not close anything. Marked done BEFORE
            # the answer leaves, so the browser's next request (/listo) already sees it; the
            # shutdown waits out the grace.
            self.close_connection = True   # the browser's next request opens a fresh socket
            self.server.close_after_success()
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
        for err in body.get("errores", []):
            print(f"✗ línea {err['linea']}: {err['error']}")
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
    global TOKEN, SNAPSHOT, ROWS, CRED_PATH, PHASE20, ESTADO_PATH, CERT_DIR, LAN_IP, HOSTNAME, PORT, CENTRO
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
            check("centro: the centre's GETs need the token too", st == 401 and st2 == 401)
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
                                                   "sectors": [], "programs": []})
            check("a re-run converges on the same establishment",
                  st == 200 and body["ok"] and body["already"])
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
                  and msgs.count("derivación compartida: standings.sh") == 3
                  and "cuenta administradora" in msgs
                  and all(f"«{uid}»" in msgs
                          for uid in ("director", "jefe.estrella", "jefe.sar", "admin")))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pedro.2", "Pedro", "Dos", "pedro2@example.cl",
                                   "role-medico sar-desconocido admin", "no"))})
            msgs = err_lines(body)
            check("roster: unknown groups and admin-in-grupos are line errors",
                  st == 400 and "«sar-desconocido» no existe" in msgs
                  and "columna primer_admin" in msgs)

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("luis.3", "Luis", "Tres", "no-es-correo",
                                   "all-staff", "no"))})
            check("roster: a malformed correo errors (empty correo was green above)",
                  st == 400 and "«no-es-correo» no es válido" in err_lines(body))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("sofia.4", "Sofía", "Cuatro", "", "", "no"))})
            check("roster: empty grupos errors with the all-staff hint",
                  st == 400 and "al menos un grupo" in err_lines(body))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("elena.5", "Elena", "Cinco", "", "all-staff", "SÍ"))})
            check("roster: primer_admin accepts sí, accent-blind (es-CL spells it so)",
                  st == 200 and body["primer_admin"] == "elena.5")

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pepe.6", "Pepe", "Seis", "", "all-staff", "no"))})
            check("roster: zero primer_admin=si is a file error naming it",
                  st == 400 and "exactamente un primer_admin=si" in err_lines(body))

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pepe.6", "Pepe", "Seis", "", "all-staff", "si"),
                                  ("rosa.7", "Rosa", "Siete", "", "all-staff", "si"))})
            msgs = err_lines(body)
            check("roster: two primer_admin=si name both lines",
                  st == 400 and "exactamente un primer_admin=si" in msgs
                  and "línea 2" in msgs and "línea 3" in msgs)

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                  "csv": planilla(("pepe.6", "Pepe", "Seis", "", "all-staff", "ja"))})
            check("roster: primer_admin junk values are refused",
                  st == 400 and "«si» o «no»" in err_lines(body))

            st, body = call("POST", "/api/usuarios", {"codigo": "110485",
                                                      "csv": planilla(maria)})
            check("roster: a site never written answers 404 with the next step",
                  st == 404 and "primero genere el sitio" in body.get("error", ""))

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
                  st == 400 and "cambió de forma" in body.get("error", ""))
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
                  st == 404 and "primero genere el sitio" in body.get("error", ""))
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
            open(stubctl, "w").close()
            open(env_path, "w", encoding="utf-8").write(
                "\n".join(l for l in env_lines if not l.startswith("OFFICE_")) + "\n")

            rc = subprocess.run(["bash", "-n", os.path.join(deis.HERE, "..", "provisioning", "usuarios.sh")],
                                capture_output=True).returncode
            check("the driver parses: bash -n provisioning/usuarios.sh is clean", rc == 0)
            check("the bounds are explicit: TIMEOUTS seed/roster/gate = 1800/1800/300",
                  TIMEOUTS == {"seed": 1800, "roster": 1800, "gate": 300})

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
                                    ("/contenedores", "Contenedores del asistente"),
                                    ("/centro", "Confirmar centro"),
                                    ("/sectores", "Sectores y programas"),
                                    ("/componentes", "Componentes de la suite"),
                                    ("/planilla", "columnas"),
                                    ("/revision", "Revise el plan"),
                                    ("/divergencia", "Divergencia")):
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

                st, text, hdr, setc = b.req("GET", "/api/estado")
                check("estado: the cookie arm serves an API route — the stub's AIO containers answer",
                      st == 200 and '"nombre": "nextcloud-aio-nextcloud"' in text
                      and '"estado"' in text)

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


                st, compo, hdr, setc = b.req("GET", "/componentes")
                check("componentes: the ALL-ON cards render from the live tree — phases and apps",
                      st == 200 and "12-apps.sh" in compo and "20-groups.sh" in compo
                      and "50-users.sh" in compo and "Se ejecuta" in compo
                      and "eurooffice" in compo and "calendar" in compo)

                st, plan, hdr, setc = b.req("GET", "/planilla")
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
                      and 'document.getElementById("paso6").onclick' in plan)

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
            st_hint, body_hint = estado_contenedores()
            os.environ["PATH"] = saved_path
            check("estado: a missing docker answers a 500 fix hint, never a hang or traceback",
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
                        cargando = {"/contenedores": "Consultando el estado",
                                    "/centro": "Cargando el registro",
                                    "/revision": "Preparando la revisión",   # the centre from the server, then the plan
                                    "/divergencia": "Cargando el resultado"}
                        corrio = True
                        for ruta, texto in cargando.items():
                            try:
                                pg.goto(f"https://127.0.0.1:{tport}{ruta}")
                                pg.wait_for_function("t => !document.body.innerText.includes(t)",
                                                     arg=texto, timeout=10000)
                            except Exception as e:   # a Playwright timeout: the arm reports it
                                corrio = False
                                errores.append(f"{ruta}: {e}")
                        for ruta in ("/bienvenida", "/sectores", "/componentes", "/planilla"):
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
                try:
                    req = urllib.request.Request(
                        f"http://127.0.0.1:{fport}/api/generar", method="POST",
                        data=json.dumps({"codigo": "113314", "modo": "ejecutar"}).encode(),
                        headers={"Content-Type": "application/json",
                                 "Authorization": f"Bearer {TOKEN}"})
                    with urllib.request.urlopen(req, timeout=10) as r:
                        return r.status
                finally:
                    globals()["api_generar"] = verdadero

            st = ejecutar_http(False)
            time.sleep(0.5)
            check("finish: a red verdict keeps the installer open for the correction",
                  st == 200 and hilo.is_alive() and not DONE.is_set())
            st = ejecutar_http(True)
            hilo.join(5)
            try:
                socket.create_connection(("127.0.0.1", fport), timeout=2).close()
                cerrado = False
            except OSError:
                cerrado = True
            check("finish: a green verdict closes the port within the grace and serve() answers 0",
                  st == 200 and not hilo.is_alive() and DONE.is_set() and cerrado and servido == [0])
            st, body = call("POST", "/api/generar", {"codigo": "113314", "modo": "ejecutar"})
            check("finish: once done, a second execution inside the grace is refused 409 — nothing runs twice",
                  st == 409 and "ya terminó" in body.get("error", ""))

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
