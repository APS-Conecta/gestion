#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The app-release resolver (ADR-0017): how an own or fork app leaves its repo's GitHub Release
and reaches the server's lock file. Standard library only, on Python 3.10 (Ubuntu 22.04's), like
apps.py beside it — the manifest is IMPORTED, never re-parsed.

  scripts/releases.py fetch [--manifest PATH] [--lock PATH] [--store PATH] [--pub PATH] \\
                            [--opciones PATH] --nextcloud 34.0.4
      For every manifest row with release: resolve its newest release compatible with the
      running Nextcloud, download it WITHOUT a token, verify it against apps.pub, and record
      the tag in the lock. A row already in the lock downloads nothing. An OPTIONAL row the
      operator did not choose (#39) resolves nothing: the wizard's options record answers
      (default /opt/aps-conecta/aio/opciones), and an unchosen optional app stays absent — a
      leftover lock row never overrides the choice. Spreed always resolves (ADR-0021).
      One Spanish FATAL line per refusal, naming the app and the retry command (the wizard and
      the silent install both surface it verbatim).
  scripts/releases.py plan [--manifest PATH] [--lock PATH] [--pub PATH] \
                            [--opciones PATH] --nextcloud 34.0.4
      The plan `aps-conecta actualizar` prints (#46): per release row, current tag (the lock's
      row, empty when none) and candidate tag — the lock as a FLOOR, never below it, a pin
      never moving. Candidates are verified (signature, hashes, id, version) before they are
      named; a refusal is one Spanish FATAL naming the app. WRITES NOTHING — `--revisar` stops
      here by contract. TSV: id<TAB>current<TAB>candidate, id<TAB>omitida for an unchosen
      optional row, or id<TAB>retirada for a lock row whose app left the manifest (#172).
  scripts/releases.py actualizar [--manifest PATH] [--lock PATH] [--store PATH] \
                            [--pub PATH] [--opciones PATH] --nuevo PATH --nextcloud 34.0.4
      actualizar's fetch leg (#46, ADR-0017): every chosen/default release row re-resolved
      (lock as floor), downloaded and verified into the store, and the WHOLE new lock written
      atomically to --nuevo — moved rows, unchanged rows and carried-over unchosen-optional
      rows, under the running Nextcloud; a row whose app left the manifest is dropped (#172),
      and the host CLI uninstalls it. The server's lock is not touched: the host CLI
      promotes the new lock only when every app applied.
  scripts/releases.py locked APPID
      The lock's row for one app — `tag<TAB>version<TAB>sha256<TAB>tarball` — or nothing
      (exit 0) when the lock names no such app. Phase 12 installs from this line.
  scripts/releases.py --self-test
      Hermetic: fixture releases served from a local HTTP hub (real redirects, real downloads)
      and signed with a throwaway key. No network, no docker, no /opt writes.

THE NORMAL PATH MAKES NO API CALL. `resolve` follows the /releases/latest redirect — one HEAD,
no body, no api.github.com, no token — and verifies that release's info.xml + SHA256SUMS +
signature before anything else moves. Only when the latest release is incompatible does it
make ONE releases-API call (newest first, non-prerelease), GITHUB_TOKEN when set.

THE LOCK WINS. A row already recorded installs from the lock and resolves nothing (a repair
never turns into an upgrade, #33); `use_lock=False` — actualizar's stance, #46 — turns the
lock into a floor instead: candidates below it are never picked. A `pin` takes exactly that
tag, before even the redirect is read. The lock is written atomically (tmp + rename): a server
never reads half a lock.

WHAT `fetch` PROVES BEFORE ANYTHING IS UNPACKED: the SHA256SUMS signature against apps.pub
(signify, the same apt package the clinic verifies with); the hashes of the tarball and of
info.xml; the tarball's one top directory equals the app id, with nothing outside it; no
appinfo/signature.json inside; and the tag equals the version info.xml declares.
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import traceback
import threading
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # apps.py sits beside this file, as deis.py sits beside provisionador.py
import apps  # noqa: E402  — the suite manifest: the one list of the apps the suite installs

# The hub the releases come from and its API. Read at call time (never bound as def-time
# defaults) so the self-test points the whole resolver at its local fixture hub; production
# never overrides them. The same tests-knob shape package-release.sh's GESTION_URL carries.
GH_DEFAULT, API_DEFAULT = "https://github.com", "https://api.github.com"
UA = "aps-conecta-instalador"   # GitHub answers 403 to a bare urllib UA on some routes
TIMEOUT = 30                    # one HTTP request's bound — a wedged fetch never hangs an install
LOCK_DEFAULT = "/opt/aps-conecta/apps.lock.json"   # inside the backup scope (S7 wires /opt/aps-conecta)
STORE_DEFAULT = "/opt/aps-conecta/apps"            # the fetched tarballs, beside the lock
OPCIONES_DEFAULT = "/opt/aps-conecta/aio"          # the wizard's state dir: the install-options record
PUBKEY_DEFAULT = os.path.join(HERE, "..", "apps.pub")
# The retry the operator reads in every per-app refusal: both entrances re-run this leg —
# the wizard's «Revisar y ejecutar» and the silent install (which also re-runs green).
RETRY = "reintente la instalación: «Revisar y ejecutar» en el instalador web, o sudo aps-conecta install"
# actualizar's own retry (#46): the install's retry names the install, and nothing about an
# update failure is repaired by re-installing — the plan's refusal is re-read with --revisar,
# the run retried whole once the cause is fixed.
RETRY_ACTUALIZAR = "corrija la causa y vuelva a ejecutar sudo aps-conecta actualizar"
TAG = re.compile(r"v([0-9]+)\.([0-9]+)\.([0-9]+)$")   # v + semver — the release workflow's own assert


class Refusal(Exception):
    """One operator-visible Spanish cause — the CLI wraps it as `FATAL: <app>: <cause> …` and
    the install stops there (#33: a failed download or verification never continues past itself)."""


def gh():
    return os.environ.get("APS_APPS_GH", GH_DEFAULT)


def api_base():
    return os.environ.get("APS_APPS_API", API_DEFAULT)


def lock_path(explicit=None):
    return explicit or os.environ.get("APS_APPS_LOCK", LOCK_DEFAULT)


def store_path(explicit=None):
    return explicit or os.environ.get("APS_APPS_STORE", STORE_DEFAULT)


def opciones_path(explicit=None):
    """The wizard's install-options record — where the host CLI writes the
    optional apps' choices (#39). APS_APPS_OPCIONES overrides (the self-test's knob); AIO_STATE,
    the host's own override of the same directory, is honoured beside it."""
    return explicit or os.environ.get("APS_APPS_OPCIONES") \
        or os.path.join(os.environ.get("AIO_STATE", OPCIONES_DEFAULT), "opciones")


def elegidas(path=None):
    """The optional apps this server chose, from the wizard's options record (#39): {id: chosen}.
    A missing record — no step 6 yet, or one written before the app existed — reads as all
    unchosen: an optional app installs only by an explicit choice, never by default, and never
    below this gate (the lock's leftover row included — the record is the operator's current
    word, and the seed's side of the same rule never uninstalls what a warm instance runs)."""
    try:
        with open(opciones_path(path), encoding="utf-8") as fh:
            pares = dict(par.split("=", 1) for par in fh.read().split() if "=" in par)
    except OSError:
        return {}
    return {i: v == "1" for i, v in pares.items()}


def pubkey_path():
    return os.environ.get("APS_APPS_PUB", PUBKEY_DEFAULT)


# ── the lock: one JSON document, the per-server record of installed app tags ───────────────


def read_lock(path=None):
    """{"nextcloud": "34.0.4", "apps": {id: {source, repo, tag, version, sha256}}} — {} when no
    lock exists yet. A lock that exists but cannot be read is a Refusal, never a silent reset:
    a hand edit must not read as «no lock» and fetch over a live server."""
    path = lock_path(path)
    try:
        with open(path, encoding="utf-8") as fh:
            lock = json.load(fh)
    except FileNotFoundError:
        return {"nextcloud": "", "apps": {}}
    except (OSError, ValueError) as e:
        causa = (f"no es JSON válido (línea {e.lineno}, columna {e.colno})"
                 if isinstance(e, json.JSONDecodeError) else "no se puede leer")
        raise Refusal(f"el candado de aplicaciones ({path}) {causa} — revíselo: una línea corrupta "
                      "no se borra sola, y re-descargar encima de un servidor vivo nunca es la reparación")
    if not isinstance(lock, dict) or not isinstance(lock.get("apps"), dict):
        raise Refusal(f"el candado de aplicaciones ({path}) no tiene la forma esperada "
                      "(un objeto con «nextcloud» y «apps»)")
    return {"nextcloud": lock.get("nextcloud", ""), "apps": lock["apps"]}


def write_lock(path, lock):
    """Atomic, always: the tmp file lands in the SAME directory (one filesystem), then one
    rename — a reader sees either the whole old lock or the whole new one, never a half. A
    failed rename cleans its own tmp; the previous lock stays the truth. 0644, like estado.txt:
    nothing in it is secret, and «aps-conecta estado» reads such files without sudo."""
    tmp = f"{path}.tmp"
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"nextcloud": lock["nextcloud"], "apps": lock["apps"]}, fh,
                      ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError as e:
        raise Refusal(f"no se pudo escribir el candado de aplicaciones ({path}): {e}") from None
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def store_file(app, tag, store=None):
    """Where one release's tarball lives: <store>/<id>/<tag>.tar.gz — beside the lock, inside
    the backup scope, one file per tag so a later `actualizar` fetches its candidates alongside
    what it may yet roll back to."""
    return os.path.join(store_path(store), app, f"{tag}.tar.gz")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ── the network: three verbs, every one bounded, Spanish on every failure ──────────────────


def latest_tag(repo):
    """The repo's newest release tag, read off the /releases/latest REDIRECT — one HEAD, no
    body, no API call, no token. None when the repo has no releases: GitHub answers 200 and
    redirects to the releases LIST page, so the shape of the final URL is the answer."""
    url = f"{gh()}/{repo}/releases/latest"
    try:
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            final = r.geturl()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise Refusal(f"el repositorio {repo} no existe o no es público ({url})") from None
        raise Refusal(f"GitHub respondió {e.code} al pedir la última release de {repo}") from None
    except (urllib.error.URLError, OSError) as e:
        raise Refusal(f"no se pudo conectar con {gh()} para leer la última release de {repo} "
                      f"({e.reason if isinstance(e, urllib.error.URLError) else e}) — revise la "
                      "conexión de este servidor") from None
    m = re.search(r"/releases/tag/([^/?#]+)$", final)
    return urllib.parse.unquote(m.group(1)) if m else None


def download(repo, tag, name):
    """One release asset's bytes — the fixed-name files the shared release workflow publishes.
    The tarball rides this too; nothing is unpacked before `prove` has seen it."""
    url = f"{gh()}/{repo}/releases/download/{urllib.parse.quote(tag)}/{urllib.parse.quote(name)}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise Refusal(f"la release {tag} de {repo} no publica el archivo {name} (404)") from None
        raise Refusal(f"GitHub respondió {e.code} al descargar {name} de la release {tag} de {repo}") from None
    except (urllib.error.URLError, OSError) as e:
        raise Refusal(f"no se pudo descargar {name} de la release {tag} de {repo} "
                      f"({e.reason if isinstance(e, urllib.error.URLError) else e}) — revise la "
                      "conexión de este servidor") from None


def api_tags(repo, token=None):
    """The releases-API fallback — ONE call, the only leg that ever touches api.github.com:
    tags newest first, no drafts, no prereleases. GITHUB_TOKEN rides it when set; the normal
    path never calls this at all (its rate limit is the reason it is a fallback, not the path)."""
    url = f"{api_base()}/repos/{repo}/releases?per_page=100"
    headers = {"User-Agent": UA, "Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        hint = "" if token else (" — sin token el límite es 60 consultas por hora; defina "
                                 "GITHUB_TOKEN si esto se repite")
        raise Refusal(f"la API de GitHub respondió {e.code} al listar las releases de {repo}{hint}") from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Refusal(f"no se pudo consultar la API de GitHub por las releases de {repo} ({e})") from None
    return [r["tag_name"] for r in data
            if isinstance(r, dict) and r.get("tag_name") and not r.get("draft") and not r.get("prerelease")]


# ── proving a release: the signature first, then the hashes, then the tarball's shape ──────


def verify_signature(sums_path, sig_path):
    """Ed25519 over SHA256SUMS against apps.pub, with the same apt signify the clinic verifies
    a suite release with (D7's rule: a format incompatibility reds CI, never a clinic). The
    signature is the ONLY trust root — the sums and the tarball below are attacker-controlled
    until this passes, so there is no sha-only fallback: without signify there is no install."""
    if shutil.which("signify") is None:
        raise Refusal("signify no está instalado y sin él no se puede verificar ninguna aplicación "
                      "— el paso «preparar» lo instala (sudo apt-get install signify-openbsd)")
    try:
        run = subprocess.run(["signify", "-V", "-p", pubkey_path(), "-m", sums_path, "-x", sig_path],
                             capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise Refusal("signify no respondió en 60 s al verificar SHA256SUMS") from None
    if run.returncode != 0:
        raise Refusal("la firma de SHA256SUMS no verifica contra apps.pub — estos archivos no "
                      "provienen de una release firmada por APS Conecta")


def sums_of(data):
    """SHA256SUMS as {name: sha256} — the two-space sha256sum shape the release workflow writes."""
    out = {}
    for line in data.decode("utf-8", "replace").splitlines():
        m = re.fullmatch(r"([0-9a-f]{64})  (.+)", line.strip())
        if m:
            out[m.group(2)] = m.group(1)
    return out


def info_of(data):
    """info.xml as the four facts the resolver needs: the app id, the version, the Nextcloud
    range. None on a shape this cannot read — fail closed, never guess a range."""
    try:
        root = ET.fromstring(data)
        deps = root.find("dependencies/nextcloud")
        return {"id": (root.findtext("id") or "").strip(),
                "version": (root.findtext("version") or "").strip(),
                "min": int(deps.get("min-version")) if deps is not None and deps.get("min-version") else None,
                "max": int(deps.get("max-version")) if deps is not None and deps.get("max-version") else None}
    except (ET.ParseError, ValueError, TypeError):
        return None


def compatible(info, major):
    """The declared range covers the running major — an app built for another Nextcloud never
    reaches a server (user story 4)."""
    return info["min"] is not None and info["min"] <= major <= (info["max"] or 99)


def prove_tarball(data, app, version):
    """The tarball's own shape, checked BEFORE anything is unpacked: one top directory, equal to
    the app id, nothing outside it (an absolute path or a ../ escape fails the same test — its
    first component is not the id); no appinfo/signature.json (a release of ours never carries
    one, #27's release decisions); and the info.xml inside declares the same version the release
    claims — a mismatch would make the seed re-impose on every run, forever."""
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            members = tar.getmembers()
            tops = {m.name.split("/")[0] for m in members}
            if len(tops) != 1 or app not in tops:
                raise Refusal(f"el paquete descomprime «{sorted(tops)[0] if tops else 'nada'}/», "
                              f"no «{app}/» — el directorio superior debe ser el id de la aplicación")
            names = {m.name for m in members}
            if f"{app}/appinfo/signature.json" in names:
                raise Refusal("el paquete lleva appinfo/signature.json — una release de APS Conecta "
                              "nunca la lleva, y la verificación de integridad de Nextcloud la exigiría")
            inner = tar.extractfile(f"{app}/appinfo/info.xml")
            info = info_of(inner.read()) if inner else None
    except tarfile.TarError as e:
        raise Refusal(f"el paquete no es un tar.gz legible ({e})") from None
    if not info or info["version"] != version:
        raise Refusal(f"el info.xml dentro del paquete declara la versión "
                      f"«{info['version'] if info else '?'}», no la «{version}» de la release")


def inspect_release(row, tag, major=None):
    """The three small assets of one release — info.xml, SHA256SUMS, signature — downloaded and
    proven, without the tarball. Returns {compatible, entry} for a release that IS what it says
    it is; every defect below is a Refusal (fail closed: a bad signature on any published
    release is an incident to stop for, never a candidate to walk past). `compatible` answers
    only when a major was given — a fetch of an already-chosen tag does not re-ask it."""
    app, repo = row["id"], row["repo"]
    firmado = {"info.xml": download(repo, tag, "info.xml"),
               "SHA256SUMS": download(repo, tag, "SHA256SUMS"),
               "SHA256SUMS.minisig": download(repo, tag, "SHA256SUMS.minisig")}
    with tempfile.TemporaryDirectory() as tmp:
        paths = {n: os.path.join(tmp, n) for n in firmado}
        for n, blob in firmado.items():
            with open(paths[n], "wb") as fh:
                fh.write(blob)
        verify_signature(paths["SHA256SUMS"], paths["SHA256SUMS.minisig"])
    sums = sums_of(firmado["SHA256SUMS"])
    for nombre in (f"{app}.tar.gz", "info.xml"):
        if nombre not in sums:
            raise Refusal(f"SHA256SUMS de la release {tag} no nombra {nombre} — la release está "
                          "incompleta respecto del formato que el instalador verifica")
    if sha256_bytes(firmado["info.xml"]) != sums["info.xml"]:
        raise Refusal(f"info.xml no coincide con la suma registrada en SHA256SUMS de la release {tag}")
    info = info_of(firmado["info.xml"])
    if not info or info["id"] != app:
        raise Refusal(f"la release {tag} declara el id «{info['id'] if info else '?'}», no «{app}»")
    if not TAG.fullmatch(tag) or tag[1:] != info["version"]:
        raise Refusal(f"la release {tag} declara la versión «{info['version']}» — la etiqueta y la "
                      "versión deben coincidir (el flujo de publicación lo exige; esta no pasó por él)")
    return {"compatible": compatible(info, major) if major is not None else None,
            "entry": {"source": row["source"], "repo": repo, "tag": tag,
                      "version": info["version"], "sha256": sums[f"{app}.tar.gz"]}}


def order(tag):
    """A release tag as a comparable tuple — the floor rule's arithmetic."""
    m = TAG.fullmatch(tag)
    return tuple(int(g) for g in m.groups()) if m else (0, 0, 0)


def resolve(row, major, lock_entry=None, use_lock=True, token=None):
    """The tag this server installs for one manifest row, and (when the choice was already
    proven) its entry: (tag, entry|None). The rules, in order — a pin beats everything and
    reads nothing off the network; the LOCK WINS over any resolution (a repair never upgrades,
    #33); `use_lock=False` (actualizar's stance, #46) keeps the lock only as a FLOOR no
    candidate may fall below — and when nothing at-or-above the floor is compatible, the
    refusal that follows is the major-bump guard (#46, user story 25); then the latest-release
    redirect, and only when it is incompatible the ONE releases-API call, newest first."""
    floor = lock_entry["tag"] if lock_entry else None
    if use_lock and lock_entry:
        return lock_entry["tag"], None
    pin = row.get("pin")
    if pin:
        return pin, None
    seen, latest = set(), latest_tag(row["repo"])
    if latest is not None:
        seen.add(latest)
        if floor is None or order(latest) >= order(floor):
            visto = inspect_release(row, latest, major)
            if visto["compatible"]:
                return latest, visto["entry"]
    tags = api_tags(row["repo"], token)   # only on an incompatible (or floor-blocked) latest
    for tag in tags:
        if tag in seen or (floor is not None and order(tag) < order(floor)):
            continue
        visto = inspect_release(row, tag, major)
        if visto["compatible"]:
            return tag, visto["entry"]
    if latest is None and not tags:
        raise Refusal(f"{row['repo']} todavía no publica ninguna release")
    if floor:
        # Everything at-or-above the floor being incompatible while the walk exhausted IS the
        # major bump with no release for it (user story 25, #46) — the one refusal the update
        # owes: an app the clinic relies on never loses its release to a Nextcloud jump, and
        # the line names the major and the app's own installed release. (An app at its newest
        # compatible release never reaches here: the walk inspects the floor itself — it sits
        # at-or-above — and returns it, so actualizar prints «sin cambios», not a refusal.)
        raise Refusal(f"ninguna release de {row['repo']} es compatible con Nextcloud {major} — "
                      f"la instalada «{floor}» tampoco lo es: un salto de major de Nextcloud no "
                      "puede dejar una aplicación del establecimiento sin release compatible")
    raise Refusal(f"ninguna release de {row['repo']} es compatible con Nextcloud {major}")


def fetch_release(row, tag, entry=None, store=None):
    """One chosen release, downloaded whole and proven: the tarball's hash against the signed
    sums, then its shape — and only then it lands in the store. Returns the lock entry."""
    app, repo = row["id"], row["repo"]
    data = download(repo, tag, f"{app}.tar.gz")
    if entry is None:
        entry = inspect_release(row, tag)["entry"]
    if sha256_bytes(data) != entry["sha256"]:
        raise Refusal(f"{app}.tar.gz no coincide con la suma firmada de la release {tag}")
    prove_tarball(data, app, entry["version"])
    dest = store_file(app, tag, store)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = f"{dest}.tmp"
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, dest)
    except OSError as e:
        raise Refusal(f"no se pudo guardar {app} {tag} en el almacén ({dest}): {e}") from None
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return entry


def fetch_all(rows, nextcloud, path=None, store=None, eleccion=None):
    """The fetch leg the Provisionador runs (execute mode only, #33): every release row either
    resolves, downloads and enters the lock, or is already recorded and downloads NOTHING — and
    an optional row the operator did not choose resolves nothing at all (#39): the wizard's
    options record answers, the lock never overrides the choice, and the app stays absent.
    The returned lines are console Spanish; the lock is written once, atomically, at the end. A
    per-app Refusal carries the app's name — the operator's one line names what failed."""
    lines, nuevas = [], {}
    lock = read_lock(path)
    major = int(nextcloud.split(".")[0])
    if eleccion is None:
        eleccion = elegidas()
    for row in rows:
        app = row["id"]
        if row.get("optional") is not False and not eleccion.get(app):
            lines.append(f"✓ apps: {app} no elegida — no se instala (la elección del asistente)")
            continue
        try:
            registrado = lock["apps"].get(app)
            if registrado:
                dest = store_file(app, registrado["tag"], store)
                if os.path.isfile(dest) and sha256_file(dest) == registrado["sha256"]:
                    lines.append(f"✓ apps: {app} {registrado['tag']} ya está en este servidor — "
                                 "no se descarga nada")
                    continue
                # the progress line lands BEFORE the download: a hung request leaves it as the
                # last line, so the operator's one error names the app that was in flight
                lines.append(f"aplicaciones: {app} {registrado['tag']} — descargando de nuevo y verificando")
                fetch_release(row, registrado["tag"], registrado, store)   # the repair keeps the locked tag
                lines.append(f"✓ apps: {app} {registrado['tag']} descargada de nuevo y verificada "
                             "(faltaba en el almacén; el candado no cambia)")
                continue
            tag, entry = resolve(row, major, token=os.environ.get("GITHUB_TOKEN"))
            # same reason as the repair's line above: what is in flight is named in the log
            lines.append(f"aplicaciones: {app} {tag} — descargando y verificando")
            entry = fetch_release(row, tag, entry, store)
            nuevas[app] = entry
            lines.append(f"✓ apps: {app} {tag} descargada y verificada (compatible con "
                         f"Nextcloud {nextcloud})")
        except Refusal as e:
            raise Refusal(f"{app}: {e}") from None
    if nuevas:
        lock = {"nextcloud": nextcloud, "apps": {**lock["apps"], **nuevas}}
        write_lock(lock_path(path), lock)
        lines.append(f"aplicaciones: candado actualizado — "
                     + ", ".join(f"{a} {e['tag']}" for a, e in sorted(nuevas.items())))
    return lines


def retired(lock, ids):
    """The lock rows whose app left the manifest (#172): the plan names each, actualizar's new
    lock drops each, and the host CLI uninstalls each. `ids` is EVERY manifest id, not only the
    release rows — a row that moved to the store is still a suite app."""
    return sorted(set(lock["apps"]) - set(ids))


def plan_all(rows, nextcloud, path=None, eleccion=None, *, ids):
    """The plan `aps-conecta actualizar` prints and `--revisar` stops on (#46): for every
    release row, the tag this server RUNS (the lock's row, empty when none) and the tag the run
    would move it to — resolved with the lock as a FLOOR, actualizar's stance, so a candidate
    below the lock is never offered and a pinned row never moves. The three small assets are
    downloaded and verified (a candidate is only named once the trust chain proved it), but
    NOTHING IS WRITTEN: no lock move, no tarball — `--revisar` stops here by contract. TSV per
    row: id<TAB>current<TAB>candidate, or id<TAB>omitida for an unchosen optional one; then
    id<TAB>retirada per lock row whose app left the manifest (`ids`, #172)."""
    lines = []
    lock = read_lock(path)
    major = int(nextcloud.split(".")[0])
    if eleccion is None:
        eleccion = elegidas()
    for row in rows:
        app = row["id"]
        if row.get("optional") is not False and not eleccion.get(app):
            lines.append(f"{app}\tomitida")
            continue
        try:
            registrado = lock["apps"].get(app)
            tag, _ = resolve(row, major, lock_entry=registrado, use_lock=False,
                             token=os.environ.get("GITHUB_TOKEN"))
        except Refusal as e:
            raise Refusal(f"{app}: {e}") from None
        lines.append(f"{app}\t{registrado['tag'] if registrado else ''}\t{tag}")
    lines += [f"{app}\tretirada" for app in retired(lock, ids)]
    return lines


def fetch_next(rows, nextcloud, nuevo, path=None, store=None, eleccion=None, *, ids):
    """actualizar's fetch leg (#46, ADR-0017): every chosen/default release row re-resolved
    with the lock as a FLOOR — never below it — downloaded, verified, and recorded into a NEW
    lock at `nuevo`. The server's lock is NOT touched: the host CLI applies the apps and
    promotes the new lock only when every one of them succeeded. A row whose candidate equals
    its locked tag downloads nothing (the verified tarball is beside the lock); an unchosen
    optional row is CARRIED OVER unchanged, never erased — the choice gates updates, and the
    record that a warm instance still runs the app must survive the run. A row whose app left
    the manifest (`ids`, #172) is the one row the new lock drops: the host CLI uninstalls it."""
    lines, movidas = [], {}
    lock = read_lock(path)
    major = int(nextcloud.split(".")[0])
    if eleccion is None:
        eleccion = elegidas()
    for row in rows:
        app = row["id"]
        if row.get("optional") is not False and not eleccion.get(app):
            if app in lock["apps"]:
                lines.append(f"✓ apps: {app} no elegida — su fila del candado se conserva, no se actualiza")
            else:
                lines.append(f"✓ apps: {app} no elegida — no se instala (la elección del asistente)")
            continue
        try:
            registrado = lock["apps"].get(app)
            tag, entry = resolve(row, major, lock_entry=registrado, use_lock=False,
                                 token=os.environ.get("GITHUB_TOKEN"))
            if registrado and registrado["tag"] == tag:
                dest = store_file(app, tag, store)
                if os.path.isfile(dest) and sha256_file(dest) == registrado["sha256"]:
                    lines.append(f"✓ apps: {app} {tag} ya está en su última versión — no se descarga nada")
                    continue
                lines.append(f"aplicaciones: {app} {tag} — descargando de nuevo y verificando")
                fetch_release(row, tag, registrado, store)   # the repair keeps the locked tag
                lines.append(f"✓ apps: {app} {tag} descargada de nuevo y verificada (faltaba en el almacén)")
                continue
            lines.append(f"aplicaciones: {app} {tag} — descargando y verificando")
            entry = fetch_release(row, tag, entry, store)
            movidas[app] = entry
            lines.append(f"✓ apps: {app} {registrado['tag'] if registrado else '—'} → {tag} descargada "
                         f"y verificada (compatible con Nextcloud {nextcloud})")
        except Refusal as e:
            raise Refusal(f"{app}: {e}") from None
    dropped = retired(lock, ids)
    lines += [f"✓ apps: {app} ya no es parte de la suite — se desinstala" for app in dropped]
    kept = {a: e for a, e in lock["apps"].items() if a not in dropped}
    write_lock(nuevo, {"nextcloud": nextcloud, "apps": {**kept, **movidas}})
    changes = [f"{a} {e['tag']}" for a, e in sorted(movidas.items())] + [f"{a} retirada" for a in dropped]
    lines.append("aplicaciones: candado nuevo listo — " + (", ".join(changes) or "sin cambios"))
    return lines


# ── the CLI ───────────────────────────────────────────────────────────────────────────────


def _parse(argv, flags):
    """`k=v options… --nextcloud V` as the verbs read it: {--flag: value}, the version, and
    whatever is left (non-empty left, or a missing value, is a usage error the caller answers
    with 2). One parser for fetch, plan and actualizar — three verbs, one grammar."""
    opts, nextcloud, args = {}, None, list(argv)
    while args and args[0] in flags:
        if len(args) < 2:
            return opts, None, None
        if args[0] == "--nextcloud":
            nextcloud = args[1]
        else:
            opts[args[0]] = args[1]
        args = args[2:]
    return opts, nextcloud, args


def main(argv):
    if argv == ["--self-test"]:
        return selftest()
    if len(argv) == 2 and argv[0] == "locked":
        try:
            lock = read_lock()
        except Refusal as e:
            print(f"FATAL: {e}", file=sys.stderr)
            return 1
        entry = lock["apps"].get(argv[1])
        if entry:
            print(f"{entry['tag']}\t{entry['version']}\t{entry['sha256']}\t"
                  f"{store_file(argv[1], entry['tag'])}")
        return 0
    if argv and argv[0] in ("fetch", "plan", "actualizar"):
        verbo = argv[0]
        opts, nextcloud, args = _parse(argv[1:],
            ("--lock", "--store", "--pub", "--manifest", "--nextcloud", "--opciones", "--nuevo"))
        if nextcloud is None or args is None or args:
            print(__doc__.split("\n\n")[1], file=sys.stderr)
            return 2
        if verbo == "actualizar" and "--nuevo" not in opts:
            print(__doc__.split("\n\n")[1], file=sys.stderr)
            return 2
        if "--pub" in opts:
            os.environ["APS_APPS_PUB"] = opts["--pub"]
        try:
            # `or apps.MANIFEST`: no --manifest means the suite's own apps.json — load()'s default
            # is a def-time arg, and passing None through was the crash the first clean boot met
            manifest = apps.load(opts.get("--manifest") or apps.MANIFEST)
            rows = [r for r in manifest if r.get("release")]
            ids = [r["id"] for r in manifest]
        except ValueError as e:
            print(f"FATAL: {e}", file=sys.stderr)   # apps.py says the manifest's failure once
            return 1
        if not rows:
            print("✓ apps: ninguna app de la suite se instala aún desde releases — nada que descargar")
            return 0
        try:
            if verbo == "fetch":
                lineas = fetch_all(rows, nextcloud, opts.get("--lock"), opts.get("--store"),
                                   elegidas(opts.get("--opciones")))
            elif verbo == "plan":
                lineas = plan_all(rows, nextcloud, opts.get("--lock"),
                                  elegidas(opts.get("--opciones")), ids=ids)
            else:
                lineas = fetch_next(rows, nextcloud, opts["--nuevo"], opts.get("--lock"),
                                    opts.get("--store"), elegidas(opts.get("--opciones")), ids=ids)
            for line in lineas:
                print(line)
        except Refusal as e:
            reintento = RETRY if verbo == "fetch" else RETRY_ACTUALIZAR
            print(f"FATAL: {e} — {reintento}", file=sys.stderr)
            return 1
        except Exception as e:   # never a bare traceback as the operator's only line: the
            # Spanish FATAL below is what the wizard surfaces; the traceback rides stderr into
            # the install log beside it, where the diagnosis actually lives
            traceback.print_exc()
            print(f"FATAL: la descarga de aplicaciones falló por un error interno "
                  f"({type(e).__name__}) — {RETRY}; revise el registro", file=sys.stderr)
            return 1
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


# ── the self-test: a local hub, real redirects, real downloads, a throwaway key ───────────


def selftest():
    """Hermetic, and real where it can be: the fixtures are served over HTTP from 127.0.0.1
    with true 302s (the redirect path IS the code under test), the signatures are real
    signify crypto over a throwaway keypair, and the arms cover the eight behaviours #33
    names — plus the shapes the wizard and phase 12 read. No network, no docker, no /opt."""
    if shutil.which("signify") is None:
        print("self-test: signify (signify-openbsd) missing — sudo apt-get install signify-openbsd",
              file=sys.stderr)
        return 1
    n = failed = 0

    def check(label, ok):
        nonlocal n, failed
        n += 1
        if not ok:
            failed += 1
            print(f"  FAIL: {label}", file=sys.stderr)

    def refused(fn, *args, **kw):
        """The refusal text, or "" when the call answered — the two answers every verb has."""
        try:
            fn(*args, **kw)
            return ""
        except Refusal as e:
            return str(e)

    import http.server

    tmp = tempfile.mkdtemp(prefix="releases-selftest-")
    real_replace = os.replace
    real_env = dict(os.environ)
    tags = {}          # repo → [tags], NEWEST FIRST — the hub serves this order everywhere
    try:
        os.environ["APS_APPS_LOCK"] = os.path.join(tmp, "lock.json")
        os.environ["APS_APPS_STORE"] = os.path.join(tmp, "store")

        # two real throwaway keypairs: the one apps.pub stands for, and a stranger's
        keydir = os.path.join(tmp, "keys")
        os.makedirs(keydir)
        for name in ("nuestra", "ajena"):
            subprocess.run(["signify", "-G", "-n", "-p", os.path.join(keydir, f"{name}.pub"),
                            "-s", os.path.join(keydir, f"{name}.sec"),
                            "-c", f"self-test {name}"], check=True, capture_output=True)
        os.environ["APS_APPS_PUB"] = os.path.join(keydir, "nuestra.pub")

        # ── the fixture hub: <tree>/<repo>/releases/download/<tag>/<asset>, the redirect and
        #    list pages GitHub answers with, and the one-API page ──
        tree = os.path.join(tmp, "tree")

        def mk_release(repo, tag, version, nc="34", nc_max=None, app=None, top=None,
                       firma="nuestra", suma_tocada=None, version_interna=None, con_firma_nc=False,
                       id_asset=None):
            """One fixture release, exactly the four fixed-name assets the shared workflow
            publishes; every knob is one of the defects an arm refuses."""
            app = app or repo.split("/")[-1].lower().replace("-", "")
            d = os.path.join(tree, repo, "releases", "download", tag)
            os.makedirs(d, exist_ok=True)
            info = (f'<?xml version="1.0"?>\n<info><id>{id_asset or app}</id><version>{version}</version>'
                    f'<dependencies><nextcloud min-version="{nc}"'
                    + (f' max-version="{nc_max}"' if nc_max else "") + "/></dependencies></info>\n").encode()
            raiz = top or app
            archivos = [(f"{raiz}/appinfo/info.xml", info if version_interna is None else
                          info.replace(f"<version>{version}</version>".encode(),
                                       f"<version>{version_interna}</version>".encode())),
                         (f"{raiz}/ARCHIVO", b"fixture\n")]
            if con_firma_nc:
                archivos.append((f"{raiz}/appinfo/signature.json", b"{}\n"))
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w:gz") as tar:
                for name, blob in archivos:
                    member = tarfile.TarInfo(name)
                    member.size = len(blob)
                    tar.addfile(member, io.BytesIO(blob))
            tgz = buf.getvalue()
            with open(os.path.join(d, f"{app}.tar.gz"), "wb") as fh:
                fh.write(tgz)
            with open(os.path.join(d, "info.xml"), "wb") as fh:
                fh.write(info)
            with open(os.path.join(d, "SHA256SUMS"), "w", encoding="utf-8") as fh:
                fh.write(f"{suma_tocada or sha256_bytes(tgz)}  {app}.tar.gz\n"
                         f"{sha256_bytes(info)}  info.xml\n")
            subprocess.run(["signify", "-S", "-s", os.path.join(keydir, f"{firma}.sec"),
                            "-m", os.path.join(d, "SHA256SUMS"),
                            "-x", os.path.join(d, "SHA256SUMS.minisig")],
                           check=True, capture_output=True)
            tags.setdefault(repo, []).append(tag)   # the caller walks newest-first, as GitHub lists

        class Hub(http.server.BaseHTTPRequestHandler):
            """The fixture hub: real 302s off /releases/latest (or the list page when the repo
            has none — GitHub's own tell), real asset bytes, one API page. Every request is
            counted, and every download is checked for the token that must not be there."""

            def _serve(self, head):
                path = urllib.parse.urlparse(self.path).path
                if path.startswith("/repos/"):
                    self.server.hits["api"] += 1
                    repo = path[len("/repos/"):-len("/releases")]
                    body = json.dumps([{"tag_name": t, "prerelease": False, "draft": False}
                                       for t in self.server.tags.get(repo, [])]).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                elif path.endswith("/releases/latest"):
                    self.server.hits["latest"] += 1
                    repo = path[: -len("/releases/latest")]   # carries its leading slash
                    tags_repo = self.server.tags.get(repo[1:])
                    dest = f"{repo}/releases/tag/{tags_repo[0]}" if tags_repo else f"{repo}/releases"
                    self.send_response(302)
                    self.send_header("Location", dest)
                    body = b""
                elif path.endswith("/releases") or "/releases/tag/" in path:
                    self.send_response(200)   # the list page / the release page: present, not parsed
                    body = b"fixture page\n"
                else:
                    self.server.hits["download"] += 1
                    if self.headers.get("Authorization"):
                        self.server.hits["auth"] += 1
                    if not self.headers.get("User-Agent", "").startswith(UA):
                        self.server.hits["sin-ua"] += 1
                    archivo = os.path.join(tree, *path.strip("/").split("/"))
                    if not os.path.isfile(archivo):
                        self.send_error(404)
                        return
                    body = open(archivo, "rb").read()
                    self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head:
                    self.wfile.write(body)

            def do_GET(self):
                self._serve(False)

            def do_HEAD(self):
                self._serve(True)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        server.hits = {"api": 0, "latest": 0, "download": 0, "auth": 0, "sin-ua": 0}
        server.tags = tags
        threading.Thread(target=server.serve_forever, daemon=True).start()
        os.environ["APS_APPS_GH"] = f"http://127.0.0.1:{server.server_address[1]}"
        os.environ["APS_APPS_API"] = f"http://127.0.0.1:{server.server_address[1]}"

        def fila(repo, **extra):   # one manifest row, the shape apps.py validates
            return {"id": repo.split("/")[-1].lower().replace("-", ""), "source": "own",
                    "repo": repo, "optional": False, "containers": [], "release": True, **extra}

        # the repos the arms walk — the hub keeps each one newest-first. The real rows
        # mirror the shipped apps.json's release rows (territorio #33, epidemiologia #34,
        # IntraVox #35, side_menu #38, eurooffice #36, and the optional farmacia #39, estadistica
        # #40 and totem #41): the production-argv arm below reads the SHIPPED manifest, so a
        # release row without its hub repo reds there, at the cause. IntraVox declares the fork's
        # real range (32–35); side_menu's real tag is 6.0.1, the same number the old bake once
        # pinned, which is exactly why the lock/store pair is what proves the channel; eurooffice
        # rides at its real fork release, v11.0.7; totem's v0.3.0 is its first release — the one
        # whose tarball carries the two committed voices (#41).
        mk_release("APS-Conecta/territorio", "v0.80.0", "0.80.0", nc="34", nc_max="34")
        mk_release("APS-Conecta/epidemiologia", "v0.12.0", "0.12.0", nc="34", nc_max="34")
        mk_release("APS-Conecta/IntraVox", "v3.2.0", "3.2.0", nc="32", nc_max="35")
        mk_release("APS-Conecta/farmacia", "v0.12.0", "0.12.0", nc="34", nc_max="34")
        mk_release("APS-Conecta/estadistica", "v0.2.0", "0.2.0", nc="34", nc_max="34")
        mk_release("APS-Conecta/totem", "v0.3.0", "0.3.0", nc="34", nc_max="34")
        mk_release("APS-Conecta/side_menu", "v6.0.1", "6.0.1", nc="34", nc_max="34")
        mk_release("APS-Conecta/eurooffice", "v11.0.7", "11.0.7", nc="34", nc_max="34")
        # #145: spreed's fork — the zero-change fork of nextcloud/spreed whose App release is
        # upstream's own tarball re-proven and re-signed (ADR-0020). The fixture mirrors the
        # real first refresh: v24.0.6, upstream's newest stable for Nextcloud 34.
        mk_release("APS-Conecta/spreed", "v24.0.6", "24.0.6", nc="34", nc_max="34")
        mk_release("APS-Conecta/vieja", "v2.0.0", "2.0.0", nc="35", nc_max="35")
        mk_release("APS-Conecta/vieja", "v1.9.0", "1.9.0", nc="34", nc_max="34")
        mk_release("APS-Conecta/mala-firma", "v1.0.0", "1.0.0", firma="ajena")
        mk_release("APS-Conecta/mala-suma", "v1.0.0", "1.0.0", suma_tocada="0" * 64)
        mk_release("APS-Conecta/mal-dir", "v1.0.0", "1.0.0", top="otro")
        mk_release("APS-Conecta/con-firma-nc", "v1.0.0", "1.0.0", con_firma_nc=True)
        mk_release("APS-Conecta/otra-id", "v1.0.0", "1.0.0", id_asset="distinto")
        mk_release("APS-Conecta/version-interna", "v1.0.0", "1.0.0", version_interna="0.9.0")
        mk_release("APS-Conecta/suelo", "v4.0.0", "4.0.0", nc="35", nc_max="35")
        mk_release("APS-Conecta/suelo", "v3.5.0", "3.5.0")
        mk_release("APS-Conecta/suelo", "v3.0.0", "3.0.0")
        mk_release("APS-Conecta/suelo", "v2.5.0", "2.5.0")
        mk_release("APS-Conecta/techo", "v4.0.0", "4.0.0", nc="35", nc_max="35")
        mk_release("APS-Conecta/techo", "v3.6.0", "3.6.0", nc="35", nc_max="35")
        mk_release("APS-Conecta/techo", "v3.5.0", "3.5.0", nc="35", nc_max="35")
        mk_release("APS-Conecta/techo", "v2.5.0", "2.5.0")
        mk_release("APS-Conecta/clavada", "v2.0.0", "2.0.0")
        mk_release("APS-Conecta/clavada", "v1.5.0", "1.5.0")
        tags.setdefault("APS-Conecta/sin-releases", [])

        # ── the arms ──
        tag, entry = resolve(fila("APS-Conecta/territorio"), 34)
        check("compatible pick: the latest release, via the redirect — no API call, no token on the wire",
              tag == "v0.80.0" and entry and entry["version"] == "0.80.0"
              and server.hits["api"] == 0 and server.hits["auth"] == 0 and server.hits["sin-ua"] == 0)
        tag, entry = resolve(fila("APS-Conecta/vieja"), 34)
        check("fallback: an incompatible latest falls back to the older compatible release — exactly one API call",
              tag == "v1.9.0" and server.hits["api"] == 1)
        check("bad signature refused — the one line names apps.pub",
              "apps.pub" in refused(resolve, fila("APS-Conecta/mala-firma"), 34))
        check("hash mismatch refused — the tarball must match the signed sum",
              "no coincide con la suma firmada" in refused(fetch_release, fila("APS-Conecta/mala-suma"), "v1.0.0"))
        causa = refused(fetch_release, fila("APS-Conecta/mal-dir"), "v1.0.0")
        check("wrong top directory refused — the message names both directories",
              "«otro/»" in causa and "«maldir/»" in causa)
        check("a tarball carrying appinfo/signature.json refused",
              "signature.json" in refused(fetch_release, fila("APS-Conecta/con-firma-nc"), "v1.0.0"))
        check("a release declaring another app id refused",
              "declara el id «distinto»" in refused(inspect_release, fila("APS-Conecta/otra-id"), "v1.0.0", 34))
        causa = refused(fetch_release, fila("APS-Conecta/version-interna"), "v1.0.0")
        check("a tarball whose inner info.xml disagrees with the release refused",
              "0.9.0" in causa and "1.0.0" in causa)
        check("a repo with no releases is a refusal, never a silent stand-in",
              "no publica ninguna release" in refused(resolve, fila("APS-Conecta/sin-releases"), 34))

        tag, entry = resolve(fila("APS-Conecta/suelo"), 34,
                             lock_entry={"tag": "v3.0.0", "version": "3.0.0"}, use_lock=False)
        check("no downgrade: with the lock as a floor the newest ABOVE it wins, never one below",
              tag == "v3.5.0")
        # #46 split the old one refusal in two. An app AT its newest compatible release (the
        # ones above it target a newer Nextcloud) resolves to itself — the walk inspects the
        # floor tag, which sits at-or-above itself — so actualizar prints «sin cambios», never
        # a refusal. And a floor not compatible at the running major is the major-bump guard's
        # one refusal (user story 25): the line names the major, the app's release and the jump.
        tag, entry = resolve(fila("APS-Conecta/suelo"), 34,
                             lock_entry={"tag": "v3.5.0", "version": "3.5.0"}, use_lock=False)
        check("actualizar's stance (#46): an app already at its newest compatible release resolves to itself — the newer ones target another Nextcloud, and that is «sin cambios», never a refusal",
              tag == "v3.5.0")
        causa = refused(resolve, fila("APS-Conecta/territorio"), 35,
                        lock_entry={"tag": "v0.80.0", "version": "0.80.0"}, use_lock=False)
        check("the major bump's guard (#46): a floor not compatible at the new major refuses, naming the major, the app's installed release and the jump",
              "Nextcloud 35" in causa and "«v0.80.0»" in causa and "salto de major" in causa)
        causa = refused(resolve, fila("APS-Conecta/techo"), 34,
                        lock_entry={"tag": "v3.5.0", "version": "3.5.0"}, use_lock=False)
        check("no downgrade: everything at-or-above an incompatible floor exhausted is the same guard — the line names the release that will not move (#46's wording of the old refusal)",
              "tampoco lo es" in causa and "«v3.5.0»" in causa)
        antes = dict(server.hits)
        tag, entry = resolve(fila("APS-Conecta/territorio"), 34,
                             lock_entry={"tag": "v0.79.0", "version": "0.79.0"})
        check("the lock wins: an existing entry installs from the lock, resolving nothing",
              tag == "v0.79.0" and dict(server.hits) == antes)
        antes = dict(server.hits)
        tag, entry = resolve(fila("APS-Conecta/clavada", pin="v1.5.0"), 34)
        check("pin honoured: the exact tag, and not even the redirect was read",
              tag == "v1.5.0" and dict(server.hits) == antes)

        # the atomic lock write: whole-replace, no tmp left behind, 0644, and a failed rename
        # leaves the previous lock intact
        camino = os.path.join(tmp, "candado", "lock.json")

        def fila_lock(app, tag, version):
            return {"nextcloud": "34.0.4", "apps": {app: {"tag": tag, "version": version,
                                                          "sha256": "x" * 64, "source": "own",
                                                          "repo": f"APS-Conecta/{app}"}}}

        write_lock(camino, fila_lock("a", "v1.0.0", "1.0.0"))
        write_lock(camino, fila_lock("b", "v2.0.0", "2.0.0"))
        check("atomic lock write: replaced whole (never appended), no tmp sibling, 0644",
              list(read_lock(camino)["apps"]) == ["b"] and not os.path.exists(camino + ".tmp")
              and oct(os.stat(camino).st_mode & 0o777) == "0o644")

        def _rompe(*_a, **_k):
            raise OSError("simulated crash between tmp and rename")

        os.replace = _rompe
        causa = refused(write_lock, camino, {"nextcloud": "35.0.0", "apps": {}})
        os.replace = real_replace
        check("atomic lock write: a crash mid-write leaves the old lock whole and no tmp behind",
              causa.startswith("no se pudo escribir")
              and list(read_lock(camino)["apps"]) == ["b"] and not os.path.exists(camino + ".tmp"))
        with open(camino, "w", encoding="utf-8") as fh:
            fh.write("{cortado")
        causa = refused(read_lock, camino)
        check("a corrupt lock is a refusal naming the file, never a silent reset",
              "candado" in causa and "no es JSON válido" in causa)

        # the fetch leg end to end, over the hub, as the wizard drives it
        filas = [fila("APS-Conecta/territorio")]
        lineas = fetch_all(filas, "34.0.4")
        guardado = read_lock()
        pkg = store_file("territorio", "v0.80.0")
        check("fetch: downloads, verifies, stores beside the lock, and records tag/version/sha",
              any("territorio v0.80.0 descargada y verificada" in l for l in lineas)
              and guardado["nextcloud"] == "34.0.4"
              and guardado["apps"]["territorio"]["tag"] == "v0.80.0"
              and guardado["apps"]["territorio"]["sha256"] == sha256_file(pkg))
        bytes_lock = open(os.environ["APS_APPS_LOCK"], "rb").read()
        mtime = os.path.getmtime(pkg)
        antes = dict(server.hits)
        lineas = fetch_all(filas, "34.0.4")
        check("a repeated fetch downloads nothing and leaves the lock unchanged",
              any("no se descarga nada" in l for l in lineas) and dict(server.hits) == antes
              and open(os.environ["APS_APPS_LOCK"], "rb").read() == bytes_lock
              and os.path.getmtime(pkg) == mtime)
        os.unlink(pkg)
        lineas = fetch_all(filas, "34.0.4")
        check("a missing tarball re-downloads the LOCKED tag — the lock never moves",
              any("descargada de nuevo" in l for l in lineas)
              and open(os.environ["APS_APPS_LOCK"], "rb").read() == bytes_lock
              and sha256_file(pkg) == guardado["apps"]["territorio"]["sha256"])

        # the CLI, as phase 12 and the executor call it
        with open(os.path.join(tmp, "apps.json"), "w", encoding="utf-8") as fh:
            json.dump([fila("APS-Conecta/territorio")], fh)
        os.environ["APS_APPS_LOCK"] = os.path.join(tmp, "cli-lock.json")
        os.environ["APS_APPS_STORE"] = os.path.join(tmp, "cli-store")
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "fetch",
                              "--manifest", os.path.join(tmp, "apps.json"),
                              "--nextcloud", "34.0.4"],
                             capture_output=True, text=True, timeout=120)
        check("cli fetch: exit 0, the console line, the lock and the store laid out per app and tag",
              run.returncode == 0 and "✓ apps: territorio v0.80.0" in run.stdout
              and read_lock()["apps"]["territorio"]["tag"] == "v0.80.0"
              and os.path.isfile(store_file("territorio", "v0.80.0")))
        # THE PRODUCTION ARGV, exactly as APPS_CMD spells it: `fetch --nextcloud V`, no --manifest.
        # This is the call the first clean boot crashed on (apps.load(None) → TypeError — every
        # other arm passed --manifest, and the wizard's stub hid the argv entirely), so it runs
        # here for real: the manifest it reads is the SHIPPED apps.json, and every release row
        # there must have its fixture on the hub — a new release row without its hub repo reds
        # HERE, at the cause, not four minutes into a clean boot. farmacia (#39),
        # estadistica (#40) and totem (#41) are the optional rows: with no opciones record
        # they resolve NOTHING (the skip line says so, one per row), and with the record
        # choosing them — the second run, --opciones pointing at a fixture — they resolve
        # and lock like any release row: the choice is the gate, the record is the choice.
        os.environ["APS_APPS_LOCK"] = os.path.join(tmp, "prod-lock.json")
        os.environ["APS_APPS_STORE"] = os.path.join(tmp, "prod-store")
        with open(os.path.join(tmp, "prod-opciones"), "w", encoding="utf-8") as fh:
            fh.write("talk=1 grabacion=0 farmacia=1 estadistica=1 totem=1\n")
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "fetch",
                              "--nextcloud", "34.0.4",
                              "--opciones", os.path.join(tmp, "prod-sin-eleccion")],
                             capture_output=True, text=True, timeout=120)
        check("cli fetch without --manifest: the shipped manifest's release rows all resolve and fetch over the hub — a row that reds here lacks its fixture: add mk_release(<repo>, tag, version, nc=…, nc_max=…) to the list above (#33–#41, #119); the optional rows resolve NOTHING unchosen (#39, #40, #41), and spreed resolves with NO record too — an absent record never turns Talk off (#145)",
              run.returncode == 0 and "✓ apps: territorio v0.80.0" in run.stdout
              and "✓ apps: epidemiologia v0.12.0" in run.stdout
              and "✓ apps: intravox v3.2.0" in run.stdout
              and "✓ apps: side_menu v6.0.1" in run.stdout
              and "✓ apps: eurooffice v11.0.7" in run.stdout
              and "✓ apps: spreed v24.0.6" in run.stdout
              and "✓ apps: farmacia no elegida — no se instala" in run.stdout
              and "✓ apps: estadistica no elegida — no se instala" in run.stdout
              and "✓ apps: totem no elegida — no se instala" in run.stdout
              and "farmacia" not in read_lock()["apps"]
              and "estadistica" not in read_lock()["apps"]
              and "totem" not in read_lock()["apps"]
              and read_lock()["apps"]["territorio"]["tag"] == "v0.80.0"
              and read_lock()["apps"]["epidemiologia"]["tag"] == "v0.12.0"
              and read_lock()["apps"]["intravox"]["tag"] == "v3.2.0"
              and read_lock()["apps"]["side_menu"]["tag"] == "v6.0.1"
              and read_lock()["apps"]["eurooffice"]["tag"] == "v11.0.7"
              and read_lock()["apps"]["spreed"]["tag"] == "v24.0.6")
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "fetch",
                              "--nextcloud", "34.0.4",
                              "--opciones", os.path.join(tmp, "prod-opciones")],
                             capture_output=True, text=True, timeout=120)
        check("cli fetch with the wizard's record choosing farmacia, estadistica and totem (#39, #40, #41): they resolve, verify and lock at their tags — the lock rows arrive only with the choice",
              run.returncode == 0 and "✓ apps: farmacia v0.12.0" in run.stdout
              and "✓ apps: estadistica v0.2.0" in run.stdout
              and "✓ apps: totem v0.3.0" in run.stdout
              and "no elegida" not in run.stdout
              and read_lock()["apps"]["farmacia"] == {
                  "source": "own", "repo": "APS-Conecta/farmacia", "tag": "v0.12.0",
                  "version": "0.12.0",
                  "sha256": sha256_file(store_file("farmacia", "v0.12.0"))}
              and read_lock()["apps"]["estadistica"] == {
                  "source": "own", "repo": "APS-Conecta/estadistica", "tag": "v0.2.0",
                  "version": "0.2.0",
                  "sha256": sha256_file(store_file("estadistica", "v0.2.0"))}
              and read_lock()["apps"]["totem"] == {
                  "source": "own", "repo": "APS-Conecta/totem", "tag": "v0.3.0",
                  "version": "0.3.0",
                  "sha256": sha256_file(store_file("totem", "v0.3.0"))})
        # Legacy service selections cannot change signed Talk acquisition (ADR-0021).
        os.environ["APS_APPS_LOCK"] = os.path.join(tmp, "sin-talk-lock.json")
        os.environ["APS_APPS_STORE"] = os.path.join(tmp, "sin-talk-store")
        with open(os.path.join(tmp, "prod-sin-talk"), "w", encoding="utf-8") as fh:
            fh.write("talk=0 grabacion=0 farmacia=1 estadistica=1 totem=1\n")
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "fetch",
                              "--nextcloud", "34.0.4",
                              "--opciones", os.path.join(tmp, "prod-sin-talk")],
                             capture_output=True, text=True, timeout=120)
        check("cli fetch ignores a legacy Talk-off selection and resolves the signed release (#183)",
              run.returncode == 0
              and "✓ apps: spreed v24.0.6" in run.stdout
              and read_lock()["apps"]["spreed"]["tag"] == "v24.0.6"
              and os.path.exists(store_file("spreed", "v24.0.6"))
              and read_lock()["apps"]["territorio"]["tag"] == "v0.80.0"
              and read_lock()["apps"]["farmacia"]["tag"] == "v0.12.0")
        # Plans and updates ignore the same legacy field.
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "plan",
                              "--nextcloud", "34.0.4",
                              "--opciones", os.path.join(tmp, "prod-sin-talk")],
                             capture_output=True, text=True, timeout=120)
        check("cli plan ignores a legacy Talk-off selection (#183)",
              run.returncode == 0 and "spreed\tv24.0.6\tv24.0.6" in run.stdout
              and "territorio\tv0.80.0" in run.stdout)
        candado_sin_talk = os.path.join(tmp, "sin-talk-lock.json")
        write_lock(candado_sin_talk, {"nextcloud": "34.0.4", "apps": {
            "spreed": {"source": "fork", "repo": "APS-Conecta/spreed", "tag": "v24.0.6",
                       "version": "24.0.6", "sha256": sha256_file(store_file("spreed", "v24.0.6"))}}})
        nuevo_sin_talk = os.path.join(tmp, "sin-talk-lock.next.json")
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "actualizar",
                              "--opciones", os.path.join(tmp, "prod-sin-talk"),
                              "--nuevo", nuevo_sin_talk, "--nextcloud", "34.0.4"],
                             capture_output=True, text=True, timeout=120)
        check("cli actualizar verifies and refreshes spreed despite a legacy Talk-off selection (#183)",
              run.returncode == 0
              and "✓ apps: spreed v24.0.6" in run.stdout
              and read_lock(nuevo_sin_talk)["apps"]["spreed"]["tag"] == "v24.0.6")
        os.environ["APS_APPS_LOCK"] = os.path.join(tmp, "cli-lock.json")
        os.environ["APS_APPS_STORE"] = os.path.join(tmp, "cli-store")
        os.environ["APS_APPS_LOCK"] = os.path.join(tmp, "cli-lock.json")
        os.environ["APS_APPS_STORE"] = os.path.join(tmp, "cli-store")
        antes = dict(server.hits)   # the `locked` call below must add nothing to this
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "locked", "territorio"],
                             capture_output=True, text=True, timeout=30)
        campos = run.stdout.rstrip("\n").split("\t")
        offline = dict(server.hits) == antes   # `locked` is the seed's ONLY resolver call: offline by construction
        check("cli locked: phase 12's one line — tag, version, sha, tarball — and it answers offline (the seed's half of «a second seed downloads nothing", #33)",
              run.returncode == 0 and len(campos) == 4
              and campos[:3] == ["v0.80.0", "0.80.0", read_lock()["apps"]["territorio"]["sha256"]]
              and campos[3] == store_file("territorio", "v0.80.0") and offline)
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "locked", "epidemiologia"],
                             capture_output=True, text=True, timeout=30)
        check("cli locked: an app the lock does not name answers nothing, exit 0",
              run.returncode == 0 and run.stdout == "")
        with open(os.path.join(tmp, "apps-mala.json"), "w", encoding="utf-8") as fh:
            json.dump([fila("APS-Conecta/mala-firma")], fh)
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "fetch",
                              "--manifest", os.path.join(tmp, "apps-mala.json"),
                              "--nextcloud", "34.0.4"],
                             capture_output=True, text=True, timeout=120)
        check("cli fetch: a refusal stops with one Spanish line naming the app and the retry command",
              run.returncode == 1 and run.stdout == "" and run.stderr.startswith("FATAL: malafirma: ")
              and "apps.pub" in run.stderr and RETRY in run.stderr)
        # ── #46: actualizar's own two legs — plan reads and names (--revisar's whole leg),
        #    actualizar fetches into a NEW lock the CLI promotes only on success ──
        # The server's posture: territorio at v0.79.0 (a v0.80.0 exists), suelo at v3.5.0
        # (its newest compatible — the ones above target Nextcloud 35), and farmacia with a
        # leftover lock row the operator no longer chose: one row moves, one stays, one is
        # carried over untouched. #172: viejo's app left the manifest — the one row dropped —
        # and tienda's moved to the store: still a suite app, carried over like farmacia's.
        act = os.path.join(tmp, "act")
        os.makedirs(act, exist_ok=True)
        os.environ["APS_APPS_STORE"] = os.path.join(act, "almacen")
        # suelo's row must carry the TRUE sha of its fixture tarball (the unchanged branch
        # re-verifies it against the lock when the tarball is missing) — and the tarball sits
        # in the store, exactly as it does on a real server the install already fetched it to
        entrada_suelo = fetch_release(fila("APS-Conecta/suelo"), "v3.5.0")
        candado = os.path.join(act, "lock.json")
        write_lock(candado, {"nextcloud": "34.0.4", "apps": {
            "territorio": {"source": "own", "repo": "APS-Conecta/territorio",
                           "tag": "v0.79.0", "version": "0.79.0", "sha256": "a" * 64},
            "suelo": entrada_suelo,
            "farmacia": {"source": "own", "repo": "APS-Conecta/farmacia",
                         "tag": "v0.12.0", "version": "0.12.0", "sha256": "c" * 64},
            "viejo": {"source": "fork", "repo": "APS-Conecta/viejo",
                      "tag": "v1.0.0", "version": "1.0.0", "sha256": "e" * 64},
            "tienda": {"source": "fork", "repo": "APS-Conecta/tienda",
                       "tag": "v2.0.0", "version": "2.0.0", "sha256": "f" * 64}}})
        with open(os.path.join(tmp, "apps-act.json"), "w", encoding="utf-8") as fh:
            json.dump([fila("APS-Conecta/territorio"), fila("APS-Conecta/suelo"),
                       fila("APS-Conecta/farmacia", optional="off"),
                       {"id": "tienda", "source": "store", "optional": False, "containers": []}], fh)
        os.environ["APS_APPS_LOCK"] = candado
        opciones_act = os.path.join(act, "opciones")   # no farmacia line: unchosen
        with open(opciones_act, "w", encoding="utf-8") as fh:
            fh.write("talk=1\n")
        bytes_candado = open(candado, "rb").read()
        alm = sorted(os.listdir(os.environ["APS_APPS_STORE"])) \
            if os.path.exists(os.environ["APS_APPS_STORE"]) else []
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "plan",
                              "--manifest", os.path.join(tmp, "apps-act.json"),
                              "--opciones", opciones_act, "--nextcloud", "34.0.4"],
                             capture_output=True, text=True, timeout=120)
        check("cli plan (#46): the move, the stay and the unchosen row as TSV — current and candidate per app",
              run.returncode == 0 and "territorio\tv0.79.0\tv0.80.0" in run.stdout
              and "suelo\tv3.5.0\tv3.5.0" in run.stdout and "farmacia\tomitida" in run.stdout)
        check("cli plan (#172): the lock row whose app left the manifest is named retirada, after the manifest's rows; the row that moved to the store is not",
              run.returncode == 0 and run.stdout.rstrip("\n").split("\n")[-1] == "viejo\tretirada"
              and "tienda" not in run.stdout)
        check("cli plan (#46): --revisar's leg writes nothing — the lock's bytes, the store and no tmp left",
              open(candado, "rb").read() == bytes_candado
              and (sorted(os.listdir(os.environ["APS_APPS_STORE"]))
                   if os.path.exists(os.environ["APS_APPS_STORE"]) else []) == alm
              and not os.path.exists(candado + ".tmp"))
        nuevo = os.path.join(act, "lock.next.json")
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "actualizar",
                              "--manifest", os.path.join(tmp, "apps-act.json"),
                              "--opciones", opciones_act, "--nuevo", nuevo,
                              "--nextcloud", "34.0.4"],
                             capture_output=True, text=True, timeout=120)
        guardado = read_lock(nuevo)
        check("cli actualizar (#46): the move downloaded and verified, the stay untouched, the unchosen row carried over — into the NEW lock, the server's lock byte-identical",
              run.returncode == 0
              and "✓ apps: territorio v0.79.0 → v0.80.0 descargada y verificada" in run.stdout
              and "✓ apps: suelo v3.5.0 ya está en su última versión — no se descarga nada" in run.stdout
              and "✓ apps: farmacia no elegida — su fila del candado se conserva, no se actualiza" in run.stdout
              and "candado nuevo listo" in run.stdout
              and guardado["nextcloud"] == "34.0.4"
              and guardado["apps"]["territorio"]["tag"] == "v0.80.0"
              and guardado["apps"]["territorio"]["sha256"] == sha256_file(store_file("territorio", "v0.80.0"))
              and guardado["apps"]["suelo"]["tag"] == "v3.5.0"
              and guardado["apps"]["suelo"]["sha256"] == entrada_suelo["sha256"]
              and guardado["apps"]["farmacia"]["tag"] == "v0.12.0"
              and open(candado, "rb").read() == bytes_candado)
        check("cli actualizar (#172): the row whose app left the manifest is the one row the new lock drops — its line, the summary naming it; the store-moved row carried over",
              run.returncode == 0
              and "✓ apps: viejo ya no es parte de la suite — se desinstala" in run.stdout
              and "aplicaciones: candado nuevo listo — territorio v0.80.0, viejo retirada" in run.stdout
              and "viejo" not in guardado["apps"]
              and guardado["apps"]["tienda"]["tag"] == "v2.0.0")
        os.unlink(nuevo)   # the refusal arms below start from no new lock
        with open(os.path.join(tmp, "apps-act-mala.json"), "w", encoding="utf-8") as fh:
            json.dump([fila("APS-Conecta/mala-firma"), fila("APS-Conecta/territorio")], fh)
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "actualizar",
                              "--manifest", os.path.join(tmp, "apps-act-mala.json"),
                              "--nuevo", nuevo, "--nextcloud", "34.0.4"],
                             capture_output=True, text=True, timeout=120)
        check("cli actualizar (#46): a bad signature refuses the run before any new lock exists — one FATAL naming the app, apps.pub and actualizar's own retry",
              run.returncode == 1 and run.stdout == "" and run.stderr.startswith("FATAL: malafirma: ")
              and "apps.pub" in run.stderr and RETRY_ACTUALIZAR in run.stderr
              and not os.path.exists(nuevo) and open(candado, "rb").read() == bytes_candado)
        run = subprocess.run([sys.executable, os.path.abspath(__file__), "actualizar",
                              "--manifest", os.path.join(tmp, "apps-act.json"),
                              "--opciones", opciones_act, "--nuevo", nuevo,
                              "--nextcloud", "35.0.0"],
                             capture_output=True, text=True, timeout=120)
        check("cli actualizar (#46): a Nextcloud major bump under an app with no compatible release is refused — the line names the app, the major and the app's installed release; no new lock",
              run.returncode == 1 and run.stdout == "" and run.stderr.startswith("FATAL: territorio: ")
              and "Nextcloud 35" in run.stderr and "salto de major" in run.stderr
              and not os.path.exists(nuevo))
        server.shutdown()
        print(f"self-test: {n} checks OK" if not failed else f"self-test: {failed} of {n} checks FAILED")
        return 1 if failed else 0
    finally:
        os.replace = real_replace
        os.environ.clear()
        os.environ.update(real_env)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
