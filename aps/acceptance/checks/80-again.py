#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""After «Listo» on a test build, the way in again keeps the running version: a rerun of the Bootstrap changes nothing
on the machine, and a redeploy of the Coolify resource recreates only the mastercontainer, from the image it ran,
since AIO owns the version (ADR 0029). The machine's containers, images, volumes, networks, packages and the install's
files stay as they were (browser.state), so every container of the suite keeps running the image AIO started it on,
and AIO's interface still serves AIO's page, in a browser that pins the certificate whose fingerprint was printed. Any
other candidate's names and certificates are production ones, which a run never claims, so no suite runs: there it
says so and passes."""

import os
import sys
from pathlib import Path
from urllib.parse import urlsplit

ACCEPTANCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ACCEPTANCE))
from browser import chromium, machine, printed_link, rerun, verified  # noqa: E402

if os.environ["TEST_BUILD"] != "true":
    print(f"the way in after «Listo» runs on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names and "
          "certificates are production ones")
    sys.exit()
link, printed = printed_link(Path(os.environ["CONSOLE"]).read_text(encoding="utf-8"))
url = urlsplit(link)
rerun("the way in again after «Listo»")
running = machine("sudo docker ps --all --filter name=^nextcloud-aio- --format '{{.Names}} {{.State}}'").split()
stopped = [name for name, status in zip(running[::2], running[1::2]) if status != "running"]
if stopped:
    sys.exit(f"after the way in again, these containers of the suite do not run: {stopped}")
with chromium(pinned=[verified(url.hostname, url.port, printed)]) as browser:
    page = browser.new_page()
    page.goto(f"https://{url.netloc}/")
    if urlsplit(page.url).path != "/login":
        sys.exit(f"after the way in again, https://{url.netloc}/ leads to {page.url}, not to AIO's login")
print(f"after «Listo», the way in again ({os.environ['WAY']}) left the machine as it was: every container of the "
      "suite runs the image it ran, and AIO's interface serves AIO's page")
