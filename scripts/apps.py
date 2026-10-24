#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The suite manifest (apps.json): the one list of the apps the suite installs.

  scripts/apps.py ids          one app id per line, in manifest order
  scripts/apps.py repos        id<TAB>repo per line (repo empty for store apps)
  scripts/apps.py --self-test  the manifest validates and names only defined containers
  --manifest PATH              read another manifest (the packager reads the tag tree's)

Standard library only, on Python 3.10 (Ubuntu 22.04's); the Provisionador imports it like deis.

A row: id; source (own | fork | store); repo (own and fork apps only); optional (false | "on" |
"off"); containers (names from php/containers.json); pin (an exact vX.Y.Z tag, optional); release
(true: the app installs from its own GitHub Release at run time — ADR-0017, own and fork apps
only, and only once its repo publishes releases); name and summary (Spanish, shown in the
wizard; plumbing apps carry neither).
"""
import errno
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "apps.json")
CONTAINERS = os.path.join(HERE, "..", "php", "containers.json")
FIELDS = {"id", "source", "repo", "optional", "containers", "pin", "release", "name", "summary"}
APP_ID = re.compile(r"[a-z][a-z0-9_]*")
REPO = re.compile(r"APS-Conecta/[A-Za-z0-9._-]+")
PIN = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")


def load(path=MANIFEST):
    """The manifest's rows, validated; ValueError is the one Spanish line an operator reads."""
    try:
        return _read(path)
    except (OSError, ValueError) as e:
        raise ValueError(f"no se pudo leer la lista de aplicaciones de la suite "
                         f"({os.path.normpath(path)}): {_cause(e)}") from None


def _cause(e):  # the OS's and json's own texts are English: the common causes in Spanish
    if isinstance(e, json.JSONDecodeError):
        return f"no es JSON válido (línea {e.lineno}, columna {e.colno})"
    if isinstance(e, UnicodeDecodeError):
        return "no está en UTF-8"
    if isinstance(e, OSError):
        known = {errno.ENOENT: "no existe", errno.EACCES: "sin permiso", errno.EISDIR: "es un directorio"}
        return known.get(e.errno) or f"error de archivo ({errno.errorcode.get(e.errno, '?')})"
    return str(e)


def _read(path):
    with open(path, encoding="utf-8") as fh:
        rows = json.load(fh)
    if not isinstance(rows, list) or not rows:
        raise ValueError("no es una lista con al menos una aplicación")
    seen = set()
    for row in rows:
        _check_row(row, seen)
    return rows


def _check_row(row, seen):
    """One plain check per field, in the order the docstring describes a row."""
    app = row.get("id") if isinstance(row, dict) else None
    if not isinstance(app, str) or not APP_ID.fullmatch(app):
        raise ValueError(f"una fila sin id de aplicación válido: {row!r}")
    if app in seen:
        raise ValueError(f"{app} aparece dos veces")
    seen.add(app)
    unknown = set(row) - FIELDS
    if unknown:
        raise ValueError(f"{app}: campos desconocidos {sorted(unknown)}")
    if row.get("source") not in ("own", "fork", "store"):
        raise ValueError(f"{app}: source debe ser own, fork o store")
    _check_repo(app, row)
    optional = row.get("optional")
    if optional is not False and optional not in ("on", "off"):  # `is not False`: 0 == False
        raise ValueError(f'{app}: optional debe ser false, "on" u "off"')
    _check_containers(app, row)
    _check_pin(app, row)
    _check_release(app, row)
    _check_name(app, row)


def _check_repo(app, row):
    """Store apps name no repo; own and fork apps name one of ours (the one rule, said once)."""
    if row["source"] == "store":
        ok = "repo" not in row
    else:
        ok = isinstance(row.get("repo"), str) and bool(REPO.fullmatch(row["repo"]))
    if not ok:
        raise ValueError(f"{app}: las aplicaciones own y fork nombran un repositorio de APS-Conecta; las store, ninguno")


def _check_containers(app, row):
    """containers names this app's php/containers.json containers — ids, never descriptions."""
    declared = row.get("containers")
    if not isinstance(declared, list) or not all(isinstance(c, str) and c for c in declared):
        raise ValueError(f"{app}: containers debe ser una lista de nombres de contenedor")


def _check_pin(app, row):
    """pin is an exact release tag — `v` alone, `main` or a sha names no release there is to pin."""
    if "pin" not in row:
        return
    pin = row["pin"]
    if not (isinstance(pin, str) and PIN.fullmatch(pin)):
        raise ValueError(f"{app}: pin debe ser una etiqueta de release exacta, como v1.2.3")


def _check_release(app, row):
    """release is the bake-or-release switch (ADR-0017): true installs the app from its own
    GitHub Release at run time — a store app can never set it, and it never applies without a
    repo of ours. False or absent: the vendored bake still carries the app (#42 removes it)."""
    release = row.get("release", False)
    if not isinstance(release, bool):
        raise ValueError(f"{app}: release debe ser true o false")
    if release and row["source"] == "store":
        raise ValueError(f"{app}: una aplicación store no se instala desde releases propias")


def _check_name(app, row):
    """name and summary travel together — both or neither (plumbing apps carry neither)."""
    if "name" not in row and "summary" not in row:
        return
    for key in ("name", "summary"):
        text = row.get(key)
        if not isinstance(text, str) or not text:
            raise ValueError(f"{app}: name y summary van juntos y no pueden estar vacíos")


def missing_containers(rows, path=CONTAINERS):
    """(app, container) for every listed container php/containers.json does not define."""
    with open(path, encoding="utf-8") as fh:
        defined = {c["container_name"] for c in json.load(fh)["aio_services_v1"]}
    return [(r["id"], c) for r in rows for c in r["containers"] if c not in defined]


def selftest():
    n = failed = 0

    def check(label, ok):
        nonlocal n, failed
        n += 1
        if not ok:
            failed += 1
            print(f"  FAIL: {label}", file=sys.stderr)

    def refused(rows, containers=("aps-conecta-demo",)):
        """True when the fixture manifest fails to load or names an undefined container."""
        with tempfile.TemporaryDirectory() as tmp:
            manifest, defs = os.path.join(tmp, "apps.json"), os.path.join(tmp, "containers.json")
            with open(manifest, "w", encoding="utf-8") as fh:
                json.dump(rows, fh)
            with open(defs, "w", encoding="utf-8") as fh:
                json.dump({"aio_services_v1": [{"container_name": c} for c in containers]}, fh)
            try:
                return bool(missing_containers(load(manifest), defs))
            except ValueError:
                return True

    try:
        rows = load()
        check("the suite manifest validates", True)
        check("every container the manifest lists is defined in php/containers.json",
              not missing_containers(rows))
    except (OSError, ValueError) as e:
        check(f"the suite manifest validates ({e})", False)

    good = {"id": "demo", "source": "own", "repo": "APS-Conecta/demo", "optional": False,
          "containers": ["aps-conecta-demo"], "name": "Demo", "summary": "Una aplicación de prueba."}
    check("a well-formed row loads", not refused([good]))
    check("a pin that is an exact release tag loads", not refused([{**good, "pin": "v1.2.3"}]))
    check("release: true loads for an own app", not refused([{**good, "release": True}]))
    check("a listed container missing from the definitions is refused",
          refused([good], containers=("aps-conecta-otro",)))

    def without(key):
        return {k: v for k, v in good.items() if k != key}

    for label, bad in (("an empty manifest", []),
                       ("a row that is not an object", ["demo"]),
                       ("an id that is not an app id", [{**good, "id": "Demo App"}]),
                       ("a duplicate id", [good, good]),
                       ("an unknown field", [{**good, "version": "1.0.0"}]),
                       ("an unknown source", [{**good, "source": "lab"}]),
                       ("a store app naming a repo", [{**good, "source": "store"}]),
                       ("an own app without a repo", [without("repo")]),
                       ("optional true", [{**good, "optional": True}]),
                       ("optional 0", [{**good, "optional": 0}]),
                       ("containers as a string", [{**good, "containers": "aps-conecta-demo"}]),
                       ("a pin that is not a tag", [{**good, "pin": "main"}]),
                       ("a bare v", [{**good, "pin": "v"}]),
                       ("an incomplete pin", [{**good, "pin": "v1.2"}]),
                       ("a pre-release pin", [{**good, "pin": "v1.2.3-rc1"}]),
                       ("release as a string", [{**good, "release": "si"}]),
                       ("release on a store app", [{**{k: v for k, v in good.items() if k != "repo"},
                                                     "source": "store", "release": True}]),
                       ("a name without a summary", [without("summary")]),
                       ("an empty summary", [{**good, "summary": ""}])):
        check(f"{label} is refused", refused(bad))

    def cli(*args, rows=None, prepare=None):
        """(status, stdout, stderr) of this script run beside a fixture apps.json — the bash readers'
        view; `prepare(path)` leaves the file as the case needs, else `rows` are written as JSON."""
        with tempfile.TemporaryDirectory() as tmp:
            manifest = os.path.join(tmp, "apps.json")
            if prepare:
                prepare(manifest)
            else:
                with open(manifest, "w", encoding="utf-8") as fh:
                    json.dump(rows, fh)
            run = subprocess.run([sys.executable, os.path.abspath(__file__), "--manifest", "apps.json", *args],
                                 capture_output=True, text=True, check=False, cwd=tmp)
            return run.returncode, run.stdout, run.stderr

    store = {"id": "calendar", "source": "store", "optional": False, "containers": []}
    check("ids: one id per line, in manifest order", cli("ids", rows=[good, store]) == (0, "demo\ncalendar\n", ""))
    check("repos: id and repo tab-separated; a store app's repo is empty",
          cli("repos", rows=[good, store]) == (0, "demo\tAPS-Conecta/demo\ncalendar\t\n", ""))
    check("lines is retired (its only reader discarded the source column)", cli("lines", rows=[good])[0] != 0)

    def contents(data):
        def prepare(path):
            with open(path, "wb") as fh:
                fh.write(data)
        return prepare

    for label, prepare, cause in (
            ("a missing file", lambda path: None, "no existe"),
            ("a directory", os.mkdir, "es un directorio"),
            ("a file that is not UTF-8", contents(b"\xff\xfe[]"), "no está en UTF-8"),
            ("JSON cut off mid-row", contents(b'[{"id": "demo"'), "no es JSON válido (línea 1, columna 15)"),
            ("a duplicate id", contents(json.dumps([good, good]).encode()), "demo aparece dos veces")):
        check(f"{label}: exit 1, no id, the one Spanish line naming the manifest and why",
              cli("ids", prepare=prepare)
              == (1, "", f"no se pudo leer la lista de aplicaciones de la suite (apps.json): {cause}\n"))
    check("an unknown command exits non-zero", cli("todo", rows=[good])[0] != 0)

    print(f"self-test: {n} checks OK" if not failed else f"self-test: {failed} of {n} checks FAILED")
    return 1 if failed else 0


def main(argv):
    if argv == ["--self-test"]:
        return selftest()
    path = MANIFEST
    if argv[:1] == ["--manifest"] and len(argv) > 1:
        path, argv = argv[1], argv[2:]
    if argv not in (["ids"], ["repos"]):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        rows = load(path)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 1
    for r in rows:
        print(r["id"] if argv == ["ids"] else f"{r['id']}\t{r.get('repo', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
