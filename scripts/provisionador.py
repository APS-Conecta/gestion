#!/usr/bin/env python3
"""Provisionador — the host-side wizard that walks an operator from a fresh AIO install to a
provisioned clinic (FRD S5 core + S6 screens).

  scripts/provisionador.py               serve the API + UI (bearer token printed at start)
  scripts/provisionador.py --self-test   the FRD's named self-tests; exit 0 green / 1 red

The operator flow, one establishment per install (D13): DEIS cascade → sectores/programas →
componentes → CSV usuarios → revisar/dry-run → divergencia vacía. This file is built across
installer-design slices 14-17: slice 14 ships the HTTP server, the bearer auth, /api/deis (the
cascade's search leg) and /api/sitio (site.sh generation); slice 15 adds /api/usuarios (the roster:
CSV validation against the site and the shared registry) plus the credentials sealing; slice 16 adds
the executor — /api/generar (the FRD's review/dry-run AND the run: .env convergence, the seed, the
roster driver, the divergence gate); slice 17 the eight es-CL screens over these routes.

Python stdlib only, like deis.py — the install host is assumed to carry python3, bash, git and
docker, nothing else (#77). Plain HTTP on the LAN is the accepted v1.0 ceiling (D9): the CSPRNG
bearer token below is the only auth, so this never faces the public internet — preflight (S7)
reports the port and the clinic's own firewall keeps the edge.

deis.py is IMPORTED, never shelled out to: load/matches/write_site are the pure functions the
endpoints ride, and its ask() — input()-driven, terminal-shaped — is replaced by the UI here, with
ask()'s (gid, display, bare) triple construction replicated exactly: gids flow into SITE_TEAMS,
SITE_FOLDERS mounts and SITE_ACL rows, so a drift here is a divergence event, not a cosmetic one.
deis.py's FATAL paths sys.exit(); on the serving paths the calls catch SystemExit and answer JSON
instead of dying — a half-served wizard page is worse than an honest 4xx — while startup re-exits
fatally with the hint intact, before any socket opens.

The server is STATELESS: no session, no hidden server-side state — every request carries what it
needs (the browser flow keeps the chosen DEIS codigo), so a restart mid-flow costs the operator one
re-entry, and every endpoint is one curl. One deliberate consequence: the token never rides a URL.
log_message() prints request paths, and a token in a query string lands in scrollback, screenshots
and the server log — the Authorization header (and, from slice 17, the login cookie) is the only
carrier.
"""
import csv
import hmac
import io
import json
import os
import re
import secrets
import shlex
import socket
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
    folders = [(r[1], r[2]) for r in rows if r[0] == "folder"]
    print(json.dumps({fid: {"id": int(fid), "mountPoint": m, "groups_list": {}}
                      for m, fid in folders}))
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


def api_deis(payload):
    """POST /api/deis {"q": "cesfam florida"} — the cascade's search leg: every term must appear in
    the row, accent- and case-blind (deis.py matches(), unchanged). The whole register is ~2.7k rows
    serving one LAN operator, so the honest answer is every match plus a count — no pagination to
    get wrong, no cap to silently truncate."""
    q = payload.get("q")
    if not isinstance(q, str) or not q.strip():
        return 400, {"error": "ingrese al menos un término de búsqueda: tipo, comuna o nombre"}
    terms = [deis.fold(t) for t in q.split()]
    found = deis.matches(ROWS, terms)
    return 200, {"snapshot": SNAPSHOT, "total": len(found), "matches": found}


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


def api_sitio(payload):
    """POST /api/sitio {"codigo", "sectors", "programs"} — write sites/<codigo>/site.sh via deis.py
    write_site: the establishment's whole truth in one standalone file, byte-identical to what
    `deis.py <codigo> --new <slug>` writes, with the slug being the codigo itself. D13's
    one-establishment-per-install is settled at SITE= time (slice 16); this endpoint only ever
    touches sites/<codigo>/, its own directory."""
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
    """The accounts phase 50 will create for this site. A roster uid colliding with one of them
    is one account existing twice — once as a POSITION, once as a person — which the divergence
    gate would flag forever; refused here, at the earliest moment. The derivations replicate
    50-users.sh exactly: every sector team `sector-X` gets `jefe.X`; every cat-jefaturas local
    role gets its id minus `role-` with `-` turned into dots (`role-jefe-sar` -> `jefe.sar`);
    the four fixed positions and the wizard's own `admin` account (divergence declares that one
    on its own) are always reserved."""
    reserved = {
        "director": "cargo fijo de la fase 50 (Director/a de CESFAM)",
        "subdirector": "cargo fijo de la fase 50 (Subdirector/a Médico o Jefe Técnico)",
        "jefe.farmacia": "cargo fijo de la fase 50 (Jefe/a de Farmacia)",
        "jefe.some": "cargo fijo de la fase 50 (Jefe/a de SOME)",
        "admin": "la cuenta administradora que crea el asistente de instalación",
    }
    for gid, _ in teams:
        if gid.startswith("sector-"):
            reserved.setdefault("jefe." + gid[len("sector-"):],
                                 f"cargo derivado del sector {gid} (fase 50)")
    for gid, _display, category in roles:
        if category == "cat-jefaturas":
            reserved.setdefault(gid[len("role-"):].replace("-", "."),
                                f"cargo derivado del rol local {gid} (fase 50)")
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
    overwritten); the operator reviews or deletes it by hand. 0600 before content, written to a
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
        fh.write("# Guárdelas en un gestor de contraseñas y elimine este archivo cuando estén "
                "entregadas.\n")
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
    try:
        with SEAL_LOCK:
            fresh, sealed = seal_credentials(codigo, rows, CRED_PATH)
    except ValueError:
        return 409, {"error": f"{CRED_PATH} existe pero no se puede leer como una hoja sellada "
                              "por el Provisionador — revíselo o elimínelo a mano antes de "
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


def api_generar(payload):
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
                              "por el Provisionador — revíselo o elimínelo a mano antes de "
                              "volver a cargar la planilla"}
    missing = [uid for uid, _n, _a, _c, _g, _p in rows if uid not in sealed]
    if missing:
        # the seal happened at upload; a hand-added row with no sealed password must never
        # reach ensure_user — a blank password on user:add is a locked-out account on day one
        return 409, {"error": "la planilla nombra usuarios sin contraseña sellada: "
                              + ", ".join(missing)
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
    try:
        try:
            env_report = env_converge(root, codigo)
        except ValueError as e:
            return 409, {"error": str(e)}
        rc, seed_out = run_tee(["bash", "provisioning/seed.sh"], cwd=root,
                               timeout=TIMEOUTS["seed"])
        if rc is None:
            return 500, {"error": f"la preparación excedió el límite de {TIMEOUTS['seed']} s — "
                                  "revise la salida y el estado de la instancia",
                          "salida": seed_out}
        if rc != 0:
            fatal = next((ln for ln in reversed(seed_out.splitlines())
                          if ln.startswith("FATAL:")), "la preparación falló")
            # the gate never runs after a failed phase (the locked research flow)
            return 500, {"error": fatal, "salida": seed_out}
        records = []
        for uid, nombre, apellidos, _correo, gids, primer in rows:
            records += [uid, f"{nombre} {apellidos}", sealed[uid][0], " ".join(gids),
                        "si" if primer else "no"]
        records.append("")  # the driver's terminator
        rc, roster_out = run_tee(["bash", "provisioning/usuarios.sh"], cwd=root,
                                  timeout=TIMEOUTS["roster"],
                                  stdin_text="\n".join(records) + "\n")
        if rc is None:
            return 500, {"error": f"la planilla excedió el límite de {TIMEOUTS['roster']} s — "
                                  "revise la salida y el estado de la instancia",
                          "salida": seed_out + roster_out}
        if rc != 0:
            fatal = next((ln for ln in reversed(roster_out.splitlines())
                          if ln.startswith("FATAL:")), "la planilla falló")
            return 500, {"error": fatal, "salida": seed_out + roster_out}
        rc, gate_out = run_tee(["bash", "scripts/divergence.sh", "--gate"], cwd=root,
                               timeout=TIMEOUTS["gate"])
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


def run_tee(argv, cwd, timeout, stdin_text=None):
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
            sys.stdout.write(line)
        p.stdout.close()

    # NO start_new_session on purpose: Ctrl+C at the provisionador's terminal must reach the
    # running seed (SIGINT propagates to the process group; a detached session would orphan the
    # phases mid-write). The timeout's p.kill() targets bash only — a wedged docker-CLI
    # grandchild is docker's own timeout's business (the ceiling the docstring names).
    p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE if stdin_text is not None else None,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
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


# ── The UI (slice 17, FRD S6) ───────────────────────────────────────────────────────────
# Eight server-rendered screens over the JSON APIs: login + the seven steps. No frameworks, no
# sessions — the login cookie CARRIES the token (HttpOnly, SameSite=Strict, no Secure flag: the
# D9 LAN ceiling is plain HTTP and a Secure cookie would never be sent over it; documented, not
# an oversight). The screens are SHELLS: server-rendered frames (the stepper, the step's static
# data — register snapshot, phases, app inventory) whose interactive data arrives through the
# same /api routes a CLI would use. The token never rides a URL (log_message prints paths —
# slice 14's rule); the screens use relative links only, so no page names its own address
# either (the FRD's Paso-1 rule generalized).
#
# THE FONT DECISION: the wizard reskin carries Fraunces/Nunito (patch 070's bytes, its own
# gates); this host-side tool serves system stack — a LAN-internal operator screen does not
# re-ship 35 KB of OFL subsets, and the D1 tokens (color) are carried below.

TOKEN_COOKIE = "aps_token"  # the name; the VALUE is the token itself (the credential, compared
                            # constant-time in authorized()'s cookie arm — same code path)

SCREENS = [  # (path, step number, step title) — the stepper the shell renders
    ("/contenedores", 1, "Contenedores"),
    ("/cascada", 2, "Establecimiento"),
    ("/sectores", 3, "Sectores y programas"),
    ("/componentes", 4, "Componentes"),
    ("/planilla", 5, "Planilla de usuarios"),
    ("/revision", 6, "Revisión"),
    ("/divergencia", 7, "Divergencia"),
]



def page_css():
    """The D1 tokens (FRD: primary #7f21fe 5.57:1, background #5315a8, hover #6b01fa, error
    #ea003e, gold #e06f00 large-only, ink #101828, muted #485363) + the minimal layout the
    screens need. One function, inlined into the shell — no extra routes, no cache seams."""
    return """<style>
:root{--primario:#7f21fe;--fondo:#5315a8;--encima:#6b01fa;--error:#ea003e;--oro:#e06f00;
--tinta:#101828;--apagado:#485363;--blanco:#fff;--papel:#faf7ff}
*{box-sizing:border-box}
body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--tinta);
background:var(--papel);line-height:1.55}
header{background:var(--fondo);color:var(--blanco);padding:1.1rem 1.5rem}
header h1{margin:0;font-size:1.35rem;font-weight:600}
header p{margin:.15rem 0 0;color:#e6d7ff;font-size:.9rem}
main{max-width:46rem;margin:1.5rem auto;padding:0 1rem}
.pasos{display:flex;flex-wrap:wrap;gap:.35rem;margin:0 0 1.2rem;padding:0;list-style:none}
.pasos li{font-size:.78rem;color:var(--apagado);border:1px solid #d8ccf5;border-radius:2rem;
padding:.15rem .6rem}
.pasos li.activo{background:var(--primario);color:var(--blanco);border-color:var(--primario)}
.tarjeta{background:var(--blanco);border:1px solid #e5ddf5;border-radius:.6rem;padding:1.1rem 1.3rem;
margin-bottom:1rem}
.tarjeta h2{margin:0 0 .6rem;font-size:1.05rem;color:var(--fondo)}
label{display:block;margin:.7rem 0 .2rem;font-size:.9rem}
input[type=text],input[type=password],input[type=search],input[type=file]{width:100%;
padding:.55rem .65rem;border:1px solid #cbb8f0;border-radius:.35rem;font:inherit}
button{background:var(--primario);color:var(--blanco);border:none;border-radius:.35rem;
padding:.6rem 1.2rem;font:inherit;font-weight:600;cursor:pointer;margin-top:.9rem}
button:hover{background:var(--encima)}
button:disabled{background:var(--apagado);cursor:wait}
.aviso{border-left:.3rem solid var(--oro);background:#fff8ef;padding:.7rem .9rem;margin:.8rem 0}
.error{border-left:.3rem solid var(--error);background:#fff0f3;padding:.7rem .9rem;margin:.8rem 0}
.ok{border-left:.3rem solid var(--primario);background:#f6efff;padding:.7rem .9rem;margin:.8rem 0}
table{border-collapse:collapse;width:100%;font-size:.88rem}
td,th{padding:.4rem .5rem;border-bottom:1px solid #eee;text-align:left;vertical-align:top}
th{color:var(--apagado);font-weight:600}
.resultado{cursor:pointer}
.resultado:hover td{background:#f6efff}
code{background:#f0eafd;padding:.06rem .35rem;border-radius:.25rem;font-size:.92em}
a{color:var(--primario)}
</style>"""


def page_js():
    """The one script every screen rides: the API wrapper (the cookie flows automatically —
    same-origin fetch sends it; the Bearer arm stays for CLI use), the planilla reader with the
    DECODE-OR-WARN rule (a cp1252 hand-off mojibakes under readAsText; the file is read as
    BYTES, decoded UTF-8, and on failure decoded windows-1252 WITH a visible warning — the
    API contract is a UTF-8 string, so the decode is the UI's to own), and the long-run
    execute fetch (minutes: the button locks, the host terminal shows the live progress —
    the provisionador's own stdout is the operator's real-time view)."""
    return """<script>
async function api(ruta, cuerpo){
  const r = await fetch(ruta, {method: cuerpo ? "POST" : "GET",
    headers: {"Content-Type": "application/json"},
    body: cuerpo ? JSON.stringify(cuerpo) : undefined});
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
</script>"""


def shell(step, title, body, aviso=None):
    """The common frame: header, the 8-step stepper (login is the door, the seven steps carry
    numbers), the body, the inline CSS+JS. lang=es and every visible string es-CL formal."""
    pasos = "".join(
        f'<li class="{"activo" if n == step else ""}{" hecho" if n < step else ""}"'
        f'>{n}. {t}</li>' for _p, n, t in SCREENS)
    aviso_html = f'<div class="aviso">{aviso}</div>' if aviso else ""
    return f"""<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Paso {step} de 7 — {title} · Provisionador APS Conecta</title>
{page_css()}</head><body>
<header><h1>Provisionador APS Conecta</h1>
<p>Registro DEIS {SNAPSHOT} · {len(ROWS)} establecimientos</p></header>
<main><ol class="pasos">{pasos}</ol>{aviso_html}{body}</main>
{page_js()}</body></html>"""


def screen_login():
    body = """<div class="tarjeta"><h2>Inicie sesión</h2>
<p>Ingrese el token de acceso. Se imprimió en la consola donde ejecutó
<code>aps-conecta provision</code>.</p>
<form id="f"><label for="token">Token de acceso</label>
<input type="password" id="token" autocomplete="off" required>
<button type="submit">Entrar</button></form>
<div id="m"></div></div>
<script>
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const b = zona("f").querySelector("button"); b.disabled = true;
  const r = await api("/api/login", {token: zona("token").value});
  if (r.estado === 200) { location.href = "/contenedores"; return; }
  b.disabled = false;
  zona("m").innerHTML = '<div class="error">Token incorrecto. Cópielo de nuevo desde la consola.</div>';
});
</script>"""
    # login is the door: no stepper, no step number — the shell below renders no steps
    return f"""<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inicie sesión · Provisionador APS Conecta</title>
{page_css()}</head><body>
<header><h1>Provisionador APS Conecta</h1>
<p>Registro DEIS {SNAPSHOT} · {len(ROWS)} establecimientos</p></header>
<main>{body}</main>
{page_js()}</body></html>"""


def screen_contenedores():
    body = """<div class="tarjeta"><h2>Contenedores del asistente de instalación</h2>
<p>El asistente crea la instancia; el Provisionador la configura. Confirme que la suite esté
en marcha antes de continuar.</p><div id="m">Consultando el estado…</div></div>
<div class="tarjeta"><h2>Continuar</h2>
<p>Si la instancia está en marcha, continúe con la búsqueda del establecimiento.</p>
<button onclick="location.href='/cascada'">Continuar al paso 2</button></div>
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
    return shell(1, "Contenedores", body)


def screen_cascada():
    body = """<div class="tarjeta"><h2>Busque su establecimiento</h2>
<p>Escriba el tipo, la comuna o el nombre — por ejemplo <code>cesfam florida</code>.</p>
<form id="f"><label for="q">Buscar</label>
<input type="search" id="q" placeholder="cesfam florida" required>
<button type="submit">Buscar</button></form>
<div id="m"></div></div>
<script>
let codigo = null;
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const r = await api("/api/deis", {q: zona("q").value});
  if (r.estado !== 200) {
    zona("m").innerHTML = '<div class="error">' + escapear(r.error) + "</div>"; return;
  }
  codigo = null;
  if (!r.total) { zona("m").innerHTML = "Sin resultados. Pruebe con menos términos."; return; }
  zona("m").innerHTML = "<p>" + r.total + " resultado(s). Elija el suyo:</p><table>" +
    "<tr><th>Código</th><th>Nombre</th><th>Comuna</th></tr>" +
    r.matches.slice(0, 60).map(c => '<tr class="resultado" data-c="' + c.codigo +
      '"><td>' + c.codigo + "</td><td>" + escapear(c.nombre) + "</td><td>" +
      escapear(c.comuna) + "</td></tr>").join("") + "</table>" +
    (r.total > 60 ? "<p>Se muestran 60 de " + r.total + ".</p>" : "");
  for (const tr of zona("m").querySelectorAll("tr.resultado")) {
    tr.addEventListener("click", () => {
      codigo = tr.dataset.c;
      for (const t of zona("m").querySelectorAll("tr"))
        { t.style.background = ""; }
      tr.style.background = "#f6efff";
      zona("siguiente") || zona("m").insertAdjacentHTML("beforeend",
        '<p><button id="siguiente">Continuar con el código ' + codigo + "</button></p>");
      document.getElementById("siguiente").onclick = () =>
        { location.href = "/sectores?codigo=" + codigo; };
    });
  }
});
</script>"""
    return shell(2, "Establecimiento", body)


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
const codigo = new URLSearchParams(location.search).get("codigo");
if (!codigo) { zona("m").innerHTML =
  '<div class="error">Falta el código del establecimiento. Vuelva al paso 2.</div>'; }
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const corta = (s) => s.split(",").map(x => x.trim()).filter(x => x);
  const r = await api("/api/sitio", {codigo: codigo,
    sectors: corta(zona("sectores").value), programs: corta(zona("programas").value)});
  if (r.estado === 200) { location.href = "/componentes?codigo=" + codigo; return; }
  zona("m").innerHTML = '<div class="error">' + escapear(r.error) + "</div>";
});
</script>"""
    return shell(3, "Sectores y programas", body)


def screen_componentes(fases, apps):
    """The ALL-ON cards: the suite is one distribution (D12/D4) — everything the executor will
    provision, rendered from the live tree, nothing to choose. The one screen where 'no
    choices' is the honest design: the FRD's 'component cards ALL-ON'."""
    filas = "".join(f"<tr><td>{f}</td><td>Se ejecuta</td></tr>" for f in fases)
    apps_html = "".join(f"<code>{a}</code> " for a in apps)
    body = f"""<div class="tarjeta"><h2>Componentes de la suite</h2>
<p>La suite instala todo esto — es una sola distribución; no hay opciones que desactivar.
Las fases se ejecutan en orden, cada una idempotente.</p>
<table><tr><th>Fase</th><th>Estado</th></tr>{filas}</table></div>
<div class="tarjeta"><h2>Aplicaciones incluidas</h2><p>{apps_html}</p></div>
<div class="tarjeta"><h2>Continuar</h2>
<p>El siguiente paso carga la planilla de usuarios del establecimiento.</p>
<button onclick="location.href='/planilla?codigo=' + new URLSearchParams(location.search).get('codigo')">Continuar al paso 5</button></div>"""
    return shell(4, "Componentes", body)


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
  const {texto, aviso} = await leerPlanilla(zona("archivo").files[0]);
  const codigo = new URLSearchParams(location.search).get("codigo");
  const r = await api("/api/usuarios", {codigo: codigo, csv: texto});
  if (r.estado === 200) {
    zona("m").innerHTML = (aviso ? '<div class="aviso">' + aviso + "</div>" : "") +
      '<div class="ok">Planilla validada: ' + r.usuarios + " usuario(s), primera " +
      "administración: <code>" + escapear(r.primer_admin) + "</code>. Contraseñas selladas en <code>" +
      escapear(r.credenciales) + "</code>.</div>" +
      '<p><button id="paso6">Continuar al paso 6</button></p>';
    // The handler is ATTACHED, never inlined: a quoted onclick inside a built string is the
    // R2-caught syntax-error class — this is screen_cascada's own pattern.
    document.getElementById("paso6").onclick = () =>
      { location.href = "/revision?codigo=" + codigo; };
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
    return shell(5, "Planilla de usuarios", body)


def screen_revision():
    body = """<div class="tarjeta"><h2>Revisión</h2>
<p>Revise el plan antes de ejecutar. La ejecución configura la instancia completa
(minutos); su avance se ve en la consola donde ejecutó <code>aps-conecta provision</code>.</p>
<div id="m">Preparando la revisión…</div>
<button id="ejecutar" disabled>Ejecutar</button></div>
<script>
(async () => {
  const codigo = new URLSearchParams(location.search).get("codigo");
  if (!codigo) { zona("m").innerHTML =
    '<div class="error">Falta el código del establecimiento.</div>'; return; }
  const r = await api("/api/generar", {codigo: codigo, modo: "revision"});
  if (r.estado !== 200) {
    zona("m").innerHTML = '<div class="error">' + escapear(r.error || r.errores) + "</div>"; return;
  }
  zona("m").innerHTML = "<table>" +
    "<tr><th>Establecimiento</th><td>" + escapear(r.sitio) + "</td></tr>" +
    "<tr><th>Usuarios</th><td>" + r.usuarios + " (primera administración: <code>" +
      escapear(r.primer_admin) + "</code>)</td></tr>" +
    "<tr><th>Fases</th><td>" + r.fases.length + ": " + r.fases.join(", ") + "</td></tr>" +
    "<tr><th>Contraseñas</th><td>" + r.contrasenas_selladas + " selladas</td></tr>" +
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
    return shell(6, "Revisión", body)


def screen_divergencia():
    body = """<div class="tarjeta"><h2>Divergencia</h2>
<div id="m">Cargando el resultado…</div>
<button onclick="location.href='/'">Volver al inicio</button></div>
<script>
(async () => {
  const r = JSON.parse(sessionStorage.getItem("resultado") || "null");
  if (!r) { zona("m").innerHTML =
    '<div class="aviso">No hay un resultado en esta sesión. Ejecute de nuevo desde el paso 6.</div>'; return; }
  if (r.estado !== 200) {
    zona("m").innerHTML = '<div class="error">' + escapear(r.error) + "</div>" +
      "<pre>" + escapear((r.salida || "").split("\\n").slice(-12).join("\\n")) + "</pre>"; return;
  }
  if (r.divergencia_vacia) {
    zona("m").innerHTML = '<div class="ok"><strong>Divergencia vacía.</strong> La instancia ' +
      "queda configurada; las contraseñas de primer ingreso están selladas en <code>" +
      escapear(r.credenciales || "/opt/aps-conecta/credentials.txt") +
      "</code> (permiso 600). Entréguelas a cada persona y elimine el archivo.</div>";
  } else {
    zona("m").innerHTML = '<div class="error"><strong>Hay divergencia.</strong> Revise las ' +
      "notas y corrija; luego vuelva a ejecutar el paso 6.</div>" +
      "<pre>" + escapear(r.divergencia) + "</pre>";
  }
})();
</script>"""
    return shell(7, "Divergencia", body)


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
            # Unauthenticated on purpose: the operator's browser must see the service before pasting
            # anything, and preflight (S7) needs a liveness probe that owns no token. Nothing secret
            # rides this — the register's date and size, no establishment data.
            self.send_json(200, {"servicio": "Provisionador APS Conecta", "estado": "listo",
                                 "registro": SNAPSHOT, "establecimientos": len(ROWS)})
            return
        # ── the UI (slice 17): the login screen is public; the seven steps need the cookie ──
        if path == "/login":
            self.send_html(screen_login())
            return
        if path == "/api/estado":
            if not self.authorized():
                self.send_json(401, {"error": "token ausente o inválido"},
                               {"WWW-Authenticate": "Bearer"})
                return
            status, body = estado_contenedores()
            self.send_json(status, body)
            return
        screens = {p: (n, t) for p, n, t in SCREENS}
        if path in screens:
            if not self.authorized():
                # A human gets redirected to the door; an API gets JSON — the split is by route
                # shape (screen routes are the UI, /api routes answer JSON), not by header sniff.
                self.send_response(302)
                self.send_header("Location", "/login")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            n, _t = screens[path]
            if path == "/componentes":
                root = os.path.join(deis.HERE, "..")
                fases = sorted(p for p in os.listdir(os.path.join(root, "provisioning", "phases"))
                               if p[:1].isdigit() and p.endswith(".sh"))
                apps = sorted(os.listdir(os.path.join(root, "provisioning", "apps")))
                self.send_html(screen_componentes(fases, apps))
            else:
                self.send_html({"/contenedores": screen_contenedores,
                                "/cascada": screen_cascada,
                                "/sectores": screen_sectores,
                                "/planilla": screen_planilla,
                                "/revision": screen_revision,
                                "/divergencia": screen_divergencia}[path]())
            return
        self.send_json(404, {"error": "ruta desconocida"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/login":
            # The ONE pre-auth POST: the login form's token. Same constant-time compare as
            # authorized(); success sets the HttpOnly cookie (SameSite=Strict, no Secure — the
            # D9 LAN ceiling is plain HTTP and a Secure cookie would never ride it) and the
            # response never echoes the token.
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
            cookie = (f"{TOKEN_COOKIE}={TOKEN}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200")
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
        if path == "/api/deis":
            status, body = api_deis(payload)
        elif path == "/api/sitio":
            status, body = api_sitio(payload)
        elif path == "/api/usuarios":
            status, body = api_usuarios(payload)
        elif path == "/api/generar":
            status, body = api_generar(payload)
        else:
            status, body = 404, {"error": "ruta desconocida"}
        self.send_json(status, body)

    def authorized(self):
        # Constant-time: this is a bearer credential, and compare_digest is the stdlib's answer to
        # timing oracles. TWO arms (slice 17): the Bearer header serves API calls and the
        # self-test; the login cookie serves the screens. The cookie's VALUE is the token
        # itself — the server is stateless by design (no session store to drift or crash), so
        # the credential is the state.
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

    def send_json(self, status, obj, headers=None):
        body = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html):
        # The screens' single exit: same framing discipline as send_json (one Content-Length
        # site), and the charset is declared — the es-CL copy carries accents.
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Paths only, never headers: the token never rides a URL, so the request line is already
        # safe. Prefix so a clinic operator can tell these lines from docker's in any captured log.
        sys.stderr.write("[provisionador] %s\n" % (fmt % args))


def bind_server(host, ports):
    """Try the named ports in order, then port 0 — the OS assigns one. A busy port is a
    fall-through, never an error: the banner prints whatever actually bound, so the operator never
    needs to know 8081 was taken. Only a full failure — not even port 0 — exits non-zero, with the
    fix hint (FRD S5)."""
    err = None
    for port in (*ports, 0):
        try:
            httpd = ThreadingHTTPServer((host, port), Handler)
            return httpd, httpd.server_address[1]
        except OSError as e:
            err = e
    sys.exit(f"FATAL: no se puede escuchar en {host}: probados {', '.join(map(str, ports))} y un "
             f"puerto asignado por el sistema — {err}\n"
             f"Vea qué puertos están ocupados con:  ss -ltn")


def banner(url, token):
    print("✓ Provisionador APS Conecta")
    print(f"  Registro DEIS: instantánea {SNAPSHOT} ({len(ROWS)} establecimientos)")
    print(f"  Abra {url} — desde otro equipo de la red, reemplace 127.0.0.1 por la IP de este "
          "servidor.")
    print("  Token de acceso ( cópielo en la pantalla de inicio ):")
    print(f"    {token}")
    print("  Detenga el servicio con Ctrl+C.")


def selftest():
    """The FRD's named self-tests for this slice's surfaces, run against a throwaway tree: the
    register fixture redirects deis.HERE (load() and write_site() both read it at call time), so the
    real sites/ is never touched. The HTTP checks are real round-trips against a real server on an
    OS-assigned port — urllib, no frameworks. Every check is named and counted; a failure prints the
    list and exits 1 (B-014: a gate that cannot go red is not a gate)."""
    global TOKEN, SNAPSHOT, ROWS, CRED_PATH, PHASE20
    n = 0
    bad = []

    def check(name, cond):
        nonlocal n
        n += 1
        print(("  ok:   " if cond else "  FAIL: ") + f"{n:2}. {name}")
        if not cond:
            bad.append(name)

    old = deis.HERE
    old_cred, old_p20 = CRED_PATH, PHASE20
    # The stub world must not inherit the caller's exported seed knobs (P37, measured under
    # make test on the probe: a prior section's `source env.sh` leaves OFFICE_* exported and
    # env.sh never unsets, so the compose arm's clean fixture .env could not make the OFFICE_PORT
    # gate fire). Scrub the prefixes the phases read; restore in the finally.
    _scrub = tuple(("OFFICE_", "SITE_", "SEED_", "FIXTURE_", "NC_", "APS_", "TILES_", "HTTP_",
                    "APACHE_", "NEXTCLOUD_", "COMPOSE_"))
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

            # — the banner: the FRD's "print the actual URL + token"
            buf = io.StringIO()
            with redirect_stdout(buf):
                banner("http://127.0.0.1:8081", "tok-selftest")
            text = buf.getvalue()
            check("banner names the URL, the token and the register",
                  "http://127.0.0.1:8081" in text and "tok-selftest" in text
                  and "2099-99-99" in text)

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

            st, body = call("GET", "/")
            check("GET / names the service, no token needed",
                  st == 200 and body["registro"] == "2099-99-99" and body["establecimientos"] == 4)
            st, _ = call("POST", "/api/deis", {"q": "loica"}, token=None)
            check("POST without a token is refused 401", st == 401)
            st, _ = call("POST", "/api/deis", {"q": "loica"}, token="0" * 64)
            check("POST with a wrong token is refused 401", st == 401)
            st, body = call("POST", "/api/deis", {"q": "loica"})
            check("cascade search finds the posta by one term",
                  st == 200 and body["total"] == 1 and body["matches"][0]["codigo"] == "110485")
            st, body = call("POST", "/api/deis", {"q": "ramon"})
            check("cascade search is accent-blind (Ramón ≡ ramon)",
                  st == 200 and any(r["codigo"] == "121567" for r in body["matches"]))
            st, _ = call("POST", "/api/deis", {"q": "   "})
            check("cascade search refuses an empty query", st == 400)
            st, _ = call("POST", "/api/ruta-inexistente", {})
            check("unknown routes answer 404", st == 404)

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
            # ── slice 15: the roster (FRD S5) — /api/usuarios + the credentials sealing ──
            # The credentials sheet redirects to the fixture (CRED_PATH); phase 20 stays the REAL
            # registry file (repo content, read-only — the shared 27 are not site data) and is
            # swapped to a mangled copy only inside its own negative arm, restored immediately.
            CRED_PATH = os.path.join(tmp, "credenciales.txt")

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
                     "all-staff role-matroneria", "si")
            site_pre = open(site_path("113314"), encoding="utf-8").read()

            st, body = call("POST", "/api/usuarios", {"codigo": "113314",
                                                      "csv": "\ufeff" + planilla(maria, juan)})
            check("roster: a BOM semicolon CSV with accents validates (site team accepted)",
                  st == 200 and body["ok"] and body["usuarios"] == 2
                  and body["primer_admin"] == "juan.soto"
                  and body["contrasenas_selladas"] == 2)

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
            check("credentials: sealed 0600, a row per uid, 24-hex, display carries the accents",
                  oct(os.stat(CRED_PATH).st_mode & 0o777) == "0o600"
                  and set(pws) == {"maria.perez", "juan.soto"}
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
            check("roster: standing uids refused — fixed cargo, sector-derived, role-derived, admin",
                  st == 400 and "Director/a de CESFAM" in msgs
                  and "derivado del sector sector-estrella" in msgs
                  and "derivado del rol local role-jefe-sar" in msgs
                  and "cuenta administradora" in msgs)

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

            import hashlib
            snap = {p: hashlib.md5(open(p, "rb").read()).hexdigest()
                    for p in (site_path("113314"), CRED_PATH,
                              os.path.join(deis.HERE, "..", "sites", "113314", "planilla-mia.csv"))}
            execs = [0]
            real_popen = subprocess.Popen
            subprocess.Popen = lambda *a, **k: (execs.__setitem__(0, execs[0] + 1), real_popen(*a, **k))[1]
            st, body = generar("revision")
            subprocess.Popen = real_popen
            same = all(hashlib.md5(open(p, "rb").read()).hexdigest() == h for p, h in snap.items())
            check("generar: revision answers the plan — zero execs, zero writes",
                  st == 200 and body["modo"] == "revision" and body["usuarios"] == 2
                  and body["primer_admin"] == "elena.diaz" and body["contrasenas_selladas"] >= 2
                  and len(body["fases"]) == 14 and execs[0] == 0 and same
                  and body["env"]["FIXTURE_USER_PASSWORD"] == "se generará")

            st, _ = generar("ejecutar-x")
            st2, _ = api_generar({"codigo": "../etc", "modo": "revision"})
            check("generar: a junk modo and a traversal codigo answer 400", st == 400 and st2 == 400)

            st, body = api_generar({"codigo": "121567", "modo": "revision"})
            check("generar: a site never written answers 404 with the next step",
                  st == 404 and "primero genere el sitio" in body.get("error", ""))
            st, body = api_sitio({"codigo": "121567", "sectors": [], "programs": []})
            st, body = api_generar({"codigo": "121567", "modo": "revision"})
            check("generar: a site without a roster answers 409 naming the planilla",
                  st == 409 and "no hay planilla cargada" in body.get("error", ""))

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

            env_path = os.path.join(deis.HERE, "..", ".env")
            open(env_path, "w", encoding="utf-8").write("SITE=otro-lugar\n")
            st, body = generar("revision")
            check("generar: an .env naming another establishment refuses at review time (D13)",
                  st == 409 and "otro-lugar" in body.get("error", "") and "migre" in body.get("error", ""))
            os.remove(env_path)

            st, body = generar("ejecutar")
            drv_at = body["salida"].index("== provisioning complete")
            check("generar: ejecutar runs the whole world green — 14 phases, 2 roster users, gate clean",
                  st == 200 and body["ok"] and body["divergencia_vacia"]
                  and "14 phase(s) run" in body["salida"] and "== roster: 2 usuario(s) ==" in body["salida"]
                  and "user elena.diaz added to group admin" in body["salida"]
                  and "nothing live that the repo does not declare" in body["divergencia"])
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

            env_before = open(env_path, "rb").read()
            st, body = generar("ejecutar")
            drv = body["salida"][body["salida"].index("== provisioning complete"):]
            check("generar: a re-run converges — .env byte-stable, driver noops, gate clean",
                  st == 200 and open(env_path, "rb").read() == env_before
                  and "user maria.perez exists" in drv and "user maria.perez created" not in drv
                  and "user elena.diaz exists" in drv and body["divergencia_vacia"])

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

            # ── slice 17: the UI (FRD S6) — the eight screens, the cookie arm, the estado leg ──
            # A browser-shaped client: http.client (no auto-redirect, the Cookie header set by
            # hand) — the API's Bearer client above stays the API's.
            import http.client

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
            check("login: the screen renders — es-CL, lang=es, the token field, no stepper active",
                  st == 200 and "text/html" in hdr.get("Content-Type", "")
                  and 'lang="es"' in text and "Token de acceso" in text
                  and "Inicie sesión" in text and 'type="password"' in text
                  and "aps-conecta provision" in text
                  and TOKEN not in text)

            with redirect_stderr(errlog):
                st, text, hdr, setc = b.req("POST", "/api/login",
                                            json.dumps({"token": "0" * 64}))
                check("login: a wrong token answers 401 and sets no cookie",
                      st == 401 and setc is None)

                st, text, hdr, setc = b.req("POST", "/api/login",
                                            json.dumps({"token": TOKEN}))
                check("login: the token exchanges for an HttpOnly SameSite=Strict cookie (no Secure)",
                      st == 200 and setc and TOKEN_COOKIE + "=" in setc
                      and "HttpOnly" in setc and "SameSite=Strict" in setc
                      and "Secure" not in setc and TOKEN not in text)

                st, text, hdr, setc = b.req("GET", "/contenedores")
                check("screens: without a cookie the step routes redirect to the door",
                      st == 302 and hdr.get("Location") == "/login")

                b.cookie = f"{TOKEN_COOKIE}=valor-basura"
                st, text, hdr, setc = b.req("GET", "/contenedores")
                check("screens: a garbage cookie also redirects — constant-time, both arms",
                      st == 302 and hdr.get("Location") == "/login")

                b.cookie = f"{TOKEN_COOKIE}={TOKEN}"
                for path, marca in (("/contenedores", "Contenedores del asistente"),
                                    ("/cascada", "Busque su establecimiento"),
                                    ("/sectores", "Sectores y programas"),
                                    ("/componentes", "Componentes de la suite"),
                                    ("/planilla", "columnas"),
                                    ("/revision", "Revise el plan"),
                                    ("/divergencia", "Divergencia")):
                    st, text, hdr, setc = b.req("GET", path)
                    check(f"screens: {path} renders with the cookie arm",
                          st == 200 and marca in text and "text/html" in hdr.get("Content-Type", ""))
                st, text, hdr, setc = b.req("GET", "/contenedores")
                stepper = [f"{n}. {t}" for _p, n, t in SCREENS]
                check("screens: the seven-step stepper rides every step page",
                      all(s in text for s in stepper) and "Paso 1 de 7" in text)

                st, text, hdr, setc = b.req("GET", "/api/estado")
                check("estado: the cookie arm serves an API route — the stub's AIO containers answer",
                      st == 200 and '"nombre": "nextcloud-aio-nextcloud"' in text
                      and '"estado"' in text)

                st, text, hdr, setc = b.req("GET", "/")
                check("screens: GET / stays the identity JSON even with the cookie (the locked contract)",
                      st == 200 and "application/json" in hdr.get("Content-Type", "")
                      and "establecimientos" in text)

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

                st, compo2, hdr, setc = b.req("GET", "/componentes?codigo=113314")
                check("screens: the componentes continue button carries the codigo to the planilla",
                      "location.href='/planilla?codigo=' + new URLSearchParams(location.search)"
                      ".get('codigo')" in compo2)

                # the request log never saw the token in a path (the URL rule, measured)
                errlog.seek(0)
                logged = errlog.read()
                check("screens: the token never rides a URL — the request log carries paths only",
                      TOKEN not in logged and "/api/login" in logged)

            # docker-absent arm: estado answers a fix hint, never a traceback
            saved_path = os.environ["PATH"]
            os.environ["PATH"] = "/nonexistent-dir-for-test"
            st_hint, body_hint = estado_contenedores()
            os.environ["PATH"] = saved_path
            check("estado: a missing docker answers a 500 fix hint, never a hang or traceback",
                  st_hint == 500 and "no se encontró el comando docker" in body_hint["error"])
            httpd.shutdown()
            httpd.server_close()
    finally:
        deis.HERE = old
        CRED_PATH, PHASE20 = old_cred, old_p20
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
    global TOKEN
    # The banner is the operator's only copy of the URL and the token, and `aps-conecta provision`
    # (slice 19) and systemd both PIPE this stdout — block-buffered, a piped banner is invisible
    # (measured: the smoke driver read nothing). Line-buffered is correct for a thing that must be
    # read the moment it prints.
    sys.stdout.reconfigure(line_buffering=True)
    load_register()                        # fail fast: no register, no wizard, no socket
    TOKEN = secrets.token_hex(32)           # 64 hex chars — the env-init size, via the stdlib CSPRNG
    httpd, port = bind_server("", PORTS)   # all interfaces: D9's LAN ceiling, the token is the edge
    banner(f"http://127.0.0.1:{port}", TOKEN)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n✓ Provisionador detenido.")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
