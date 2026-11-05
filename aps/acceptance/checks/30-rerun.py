#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""A rerun of the way in before «Listo» is harmless and prints a fresh link: the Bootstrap again, or a redeploy of the
Coolify resource, which recreates the mastercontainer from the image it ran. The machine's containers, images, volumes,
networks, packages and the install's files stay as they were (browser.state), and the first link and the fresh one
each open «Centro» at the machine's address, in a browser that pins the certificate whose fingerprint was printed. The
mastercontainer pulls the suite's images at each start; the check waits for the first start's pull, and the rerun's
own pull then changes nothing."""

import difflib
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

ACCEPTANCE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ACCEPTANCE), str(ACCEPTANCE.parent / "provisionador")]
from browser import chromium, machine, printed_link, state, verified  # noqa: E402
from playwright.sync_api import expect  # noqa: E402
from provisionador import PULLED  # noqa: E402

PULL_WAIT = 15 * 60  # seconds for the suite's images, several GB

deadline = time.monotonic() + PULL_WAIT
while PULLED not in machine("sudo docker logs nextcloud-aio-mastercontainer 2>&1"):  # the log stays unprinted
    if time.monotonic() > deadline:
        sys.exit(f"the mastercontainer did not log «{PULLED}» within {PULL_WAIT // 60} minutes of its start")
    time.sleep(10)
before = state()
first = printed_link(Path(os.environ["CONSOLE"]).read_text(encoding="utf-8"))
with tempfile.NamedTemporaryFile() as console:  # the fresh link stays out of the log and the evidence
    if subprocess.run([ACCEPTANCE / "one-command.sh", console.name], check=False).returncode:
        sys.exit("the rerun of the way in failed")
    fresh = printed_link(Path(console.name).read_text(encoding="utf-8"))
after = state()
if after != before:
    sys.exit("the rerun changed the machine:\n" + "".join(difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True), "before", "after")))
if fresh[0] == first[0]:
    sys.exit("the rerun printed the first link again, not a fresh one")
links = [(urlsplit(link), printed) for link, printed in (first, fresh)]
if any(url.hostname != os.environ["ADDRESS"] for url, _ in links):
    sys.exit(f"a printed link does not point at the machine's address {os.environ['ADDRESS']}")

with chromium(pinned=[verified(url.hostname, url.port, printed) for url, printed in links]) as browser:
    for url, _ in links:
        page = browser.new_page()  # a context of its own, so no session carries over from the other link
        page.goto(url.geturl())
        expect(page.get_by_role("heading", name="Centro", exact=True)).to_be_visible(timeout=30_000)
print("the rerun changed nothing on the machine and printed a fresh link; the first and the fresh link open «Centro»")
