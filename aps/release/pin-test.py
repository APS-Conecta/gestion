#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The pin tool's self-test: pin.py against fixture App releases, through a gh on PATH that answers for them, over a
copy of the tree whose Suite manifest the test writes. No network."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent / "pin.py"
TARBALL = "c368e8c2e4a4dc0e756d79dfb85c5f3d7e93f551cebf30b0278b423eaa7c11d8"  # a fixture checksum
# The App releases gh answers for, by repo and tag; "latest" is the release GitHub calls Latest.
RELEASES = {
    "APS-Conecta/territorio": {
        "latest": {"tagName": "v0.81.0", "assets": [{"name": "info.xml", "digest": "sha256:" + "1" * 64},
                                                    {"name": "territorio.tar.gz", "digest": f"sha256:{TARBALL}"}]},
        "v0.80.0": {"tagName": "v0.80.0", "assets": [{"name": "territorio.tar.gz", "digest": "sha256:" + "8" * 64}]},
        "v0.79.0": {"tagName": "v0.79.0", "assets": [{"name": "info.xml", "digest": "sha256:" + "1" * 64}]},
        "v0.78.0": {"tagName": "v0.78.0", "assets": [{"name": "territorio.tar.gz", "digest": None}]}}}
# gh release view [<tag>] -R <repo> --json tagName,assets, answered from $RELEASES; it logs each call.
GH = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
open(os.environ["GH_CALLS"], "a").write(" ".join(args) + "\\n")
tag = args[2] if len(args) == 7 else "latest"
repo, fields = args[args.index("-R") + 1], args[args.index("--json") + 1]
release = json.loads(os.environ["RELEASES"]).get(repo, {}).get(tag)
if args[:2] != ["release", "view"] or fields != "tagName,assets" or release is None:
    sys.exit("release not found")
print(json.dumps(release))
"""
MANIFEST = [
    {"id": "intravox", "name": "Inicio", "source": "fork", "repo": "APS-Conecta/IntraVox", "pin": "v3.2.0",
     "sha256": "f" * 64},
    {"id": "territorio", "name": "Territorio", "source": "own", "repo": "APS-Conecta/territorio", "pin": "v0.80.0",
     "sha256": "8" * 64},
    {"id": "calendar", "name": "Calendario", "source": "store"},
    {"id": "totem", "name": "Tótem", "source": "own", "repo": "APS-Conecta/totem", "pin": "v0.4.0", "sha256": "9" * 64,
     "optional": True, "summary": "Turnos de atención en la sala de espera."}]


class Pin(unittest.TestCase):
    def setUp(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (tmp / "aps" / "release").mkdir(parents=True)
        (tmp / "aps" / "provisionador").mkdir()
        self.tool = tmp / "aps" / "release" / "pin.py"
        shutil.copy(TOOL, self.tool)
        self.manifest = tmp / "aps" / "provisionador" / "apps.json"
        rows = ",\n".join(f"    {json.dumps(row, ensure_ascii=False)}" for row in MANIFEST)
        self.manifest.write_text(f"[\n{rows}\n]\n", encoding="utf-8")
        (tmp / "bin").mkdir()
        (tmp / "bin" / "gh").write_text(GH, encoding="utf-8")
        (tmp / "bin" / "gh").chmod(0o755)
        self.calls = tmp / "gh-calls"
        self.env = {**os.environ, "PATH": f"{tmp / 'bin'}{os.pathsep}{os.environ['PATH']}",
                    "RELEASES": json.dumps(RELEASES), "GH_CALLS": str(self.calls)}

    def pin(self, *args):
        run = subprocess.run([sys.executable, "-I", str(self.tool), *args], capture_output=True, text=True,
                             env=self.env)
        return run.returncode, run.stdout + run.stderr

    def rows(self):
        return json.loads(self.manifest.read_text(encoding="utf-8"))

    def test_an_app_is_pinned_to_its_latest_app_release_and_the_checksum_github_gives_its_tarball(self):
        before = self.manifest.read_text(encoding="utf-8")
        code, out = self.pin("territorio")
        self.assertEqual(code, 0, out)
        self.assertIn("territorio: v0.80.0 → v0.81.0", out)
        self.assertEqual(self.rows()[1], {**MANIFEST[1], "pin": "v0.81.0", "sha256": TARBALL})
        after = self.manifest.read_text(encoding="utf-8").splitlines()
        self.assertEqual([line for n, line in enumerate(after) if n != 2],
                         [line for n, line in enumerate(before.splitlines()) if n != 2], "only its row changes")
        self.assertEqual(self.calls.read_text(), "release view -R APS-Conecta/territorio --json tagName,assets\n")

    def test_an_app_is_pinned_to_the_app_release_of_a_given_tag(self):
        code, out = self.pin("territorio", "v0.80.0")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.rows()[1], {**MANIFEST[1], "sha256": "8" * 64})
        self.assertEqual(self.calls.read_text(),
                         "release view v0.80.0 -R APS-Conecta/territorio --json tagName,assets\n")

    def test_a_release_without_the_apps_tarball_or_its_checksum_pins_nothing(self):
        before = self.manifest.read_text(encoding="utf-8")
        for tag in ("v0.79.0", "v0.78.0", "v0.1.0"):
            with self.subTest(tag=tag):
                code, out = self.pin("territorio", tag)
                self.assertNotEqual(code, 0, out)
                self.assertEqual(self.manifest.read_text(encoding="utf-8"), before)

    def test_a_store_app_or_an_id_the_manifest_does_not_list_has_no_pin(self):
        before = self.manifest.read_text(encoding="utf-8")
        for app in ("calendar", "deck"):
            with self.subTest(app=app):
                code, out = self.pin(app)
                self.assertNotEqual(code, 0, out)
                self.assertIn(app, out)
                self.assertEqual(self.manifest.read_text(encoding="utf-8"), before)
        self.assertFalse(self.calls.exists(), "no release was asked for")


if __name__ == "__main__":
    unittest.main()
