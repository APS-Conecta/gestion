#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The pin tool: pins an own or fork app of the Suite manifest (aps/provisionador/apps.json) to one of its App releases.

Usage: pin.py <app id> [<tag>]
  <tag>: the App release to pin; without it, the one GitHub shows as Latest

It asks GitHub, through gh, for the release's tag and the SHA-256 checksum GitHub gives the app's tarball,
<app id>.tar.gz, and writes both to the app's row and nothing else: the install downloads that tarball and refuses any
other bytes. A suite release installs the pins its commit holds.
"""

import json
import subprocess
import sys
from pathlib import Path

MANIFEST = Path(__file__).resolve().parents[1] / "provisionador" / "apps.json"


def release(repo, tag):
    """The release's tag and files, as gh shows them."""
    run = subprocess.run(["gh", "release", "view", *([tag] if tag else []), "-R", repo, "--json", "tagName,assets"],
                         capture_output=True, text=True, check=False)
    if run.returncode:
        sys.exit(f"{repo}: no release {tag or 'Latest'}: {run.stderr.strip()}")
    return json.loads(run.stdout)


def main(argv):
    if len(argv) not in (1, 2):
        sys.exit(__doc__)
    rows = json.loads(MANIFEST.read_text(encoding="utf-8"))
    row = next((row for row in rows if row["id"] == argv[0]), None)
    if row is None or "pin" not in row:
        sys.exit(f"{argv[0]}: not an own or fork app of the Suite manifest")
    found = release(row["repo"], argv[1] if len(argv) == 2 else None)
    asset = f"{row['id']}.tar.gz"
    digest = next((file.get("digest") or "" for file in found["assets"] if file["name"] == asset), "")
    if not digest.startswith("sha256:"):
        sys.exit(f"{row['repo']} {found['tagName']}: no {asset} with a SHA-256 checksum")
    print(f"{row['id']}: {row['pin']} → {found['tagName']} ({digest})")
    row.update(pin=found["tagName"], sha256=digest.removeprefix("sha256:"))
    lines = ",\n".join(f"    {json.dumps(row, ensure_ascii=False)}" for row in rows)
    MANIFEST.write_text(f"[\n{lines}\n]\n", encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1:])
