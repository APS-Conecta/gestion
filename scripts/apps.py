#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The suite manifest (apps.json): the one list of the apps the suite installs.

  scripts/apps.py ids          one app id per line, in manifest order
  scripts/apps.py lines        id<TAB>source<TAB>repo per line (repo empty for store apps)
  scripts/apps.py --self-test  the manifest validates and names only defined containers
  --manifest PATH              read another manifest (the packager reads the tag tree's)

Standard library only, on Python 3.10 (Ubuntu 22.04's); the Provisionador imports it like deis.

A row: id; source (own | fork | store); repo (own and fork apps only); optional (false | "on" |
"off"); containers (names from php/containers.json); pin (an exact tag, optional); name and summary
(Spanish, shown in the wizard; plumbing apps carry neither).
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "apps.json")
CONTAINERS = os.path.join(HERE, "..", "php", "containers.json")
FIELDS = {"id", "source", "repo", "optional", "containers", "pin", "name", "summary"}
APP_ID = re.compile(r"[a-z][a-z0-9_]*")
REPO = re.compile(r"APS-Conecta/[A-Za-z0-9._-]+")


def load(path=MANIFEST):
    """The manifest's rows, validated; ValueError names the first bad one."""
    with open(path, encoding="utf-8") as fh:
        rows = json.load(fh)
    if not isinstance(rows, list) or not rows:
        raise ValueError(f"{path} is not a non-empty list of apps")
    seen = set()
    for row in rows:
        app = row.get("id") if isinstance(row, dict) else None
        if not isinstance(app, str) or not APP_ID.fullmatch(app):
            raise ValueError(f"a row without a valid app id: {row!r}")
        if app in seen:
            raise ValueError(f"{app} is listed twice")
        seen.add(app)
        if set(row) - FIELDS:
            raise ValueError(f"{app}: unknown fields {sorted(set(row) - FIELDS)}")
        if row.get("source") not in ("own", "fork", "store"):
            raise ValueError(f"{app}: source is own, fork or store")
        if (row["source"] == "store") != ("repo" not in row) or "repo" in row and not (
                isinstance(row["repo"], str) and REPO.fullmatch(row["repo"])):
            raise ValueError(f"{app}: own and fork apps name an APS-Conecta repo, store apps none")
        if not (row.get("optional") is False or row.get("optional") in ("on", "off")):
            raise ValueError(f"{app}: optional is false, \"on\" or \"off\"")
        if not isinstance(row.get("containers"), list) or not all(
                isinstance(c, str) and c for c in row["containers"]):
            raise ValueError(f"{app}: containers is a list of container names")
        if "pin" in row and not (isinstance(row["pin"], str) and row["pin"].startswith("v")):
            raise ValueError(f"{app}: pin is a tag such as v1.2.3")
        if ("name" in row) != ("summary" in row) or not all(
                isinstance(row[k], str) and row[k] for k in ("name", "summary") if k in row):
            raise ValueError(f"{app}: name and summary come together, both non-empty")
    return rows


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
                       ("a name without a summary", [without("summary")]),
                       ("an empty summary", [{**good, "summary": ""}])):
        check(f"{label} is refused", refused(bad))

    def cli(*args, rows=None):
        """(status, stdout) of this script run on a fixture manifest — the bash readers' view."""
        with tempfile.TemporaryDirectory() as tmp:
            manifest = os.path.join(tmp, "apps.json")
            with open(manifest, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(rows) if rows is not None else "{not json")
            run = subprocess.run([sys.executable, os.path.abspath(__file__), "--manifest", manifest, *args],
                                 capture_output=True, text=True, check=False)
            return run.returncode, run.stdout

    store = {"id": "calendar", "source": "store", "optional": False, "containers": []}
    check("ids: one id per line, in manifest order", cli("ids", rows=[good, store]) == (0, "demo\ncalendar\n"))
    check("lines: id, source and repo tab-separated; a store app's repo is empty",
          cli("lines", rows=[good, store]) == (0, "demo\town\tAPS-Conecta/demo\ncalendar\tstore\t\n"))
    check("an unreadable manifest exits non-zero and prints no id", cli("ids") == (1, ""))
    check("an invalid manifest exits non-zero and prints no id", cli("ids", rows=[good, good]) == (1, ""))
    check("an unknown command exits non-zero", cli("todo", rows=[good])[0] != 0)

    print(f"self-test: {n} checks OK" if not failed else f"self-test: {failed} of {n} checks FAILED")
    return 1 if failed else 0


def main(argv):
    if argv == ["--self-test"]:
        return selftest()
    path = MANIFEST
    if argv[:1] == ["--manifest"] and len(argv) > 1:
        path, argv = argv[1], argv[2:]
    if argv not in (["ids"], ["lines"]):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        rows = load(path)
    except (OSError, ValueError) as e:
        print(f"FATAL: the suite manifest is unreadable: {e}", file=sys.stderr)
        return 1
    for r in rows:
        print(r["id"] if argv == ["ids"] else f"{r['id']}\t{r['source']}\t{r.get('repo', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
