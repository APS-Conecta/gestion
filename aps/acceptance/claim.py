#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Centro» and «Dirección» on a test build, through the Provisionador's API from a page that opened a link: the first
of gestion's reserved DEIS codes (aps/provisionador/ci-codes.txt) whose CI name no one holds, on the name service's CI
deployment. The claimed name's credential goes to NAMES, which run.sh frees at its end with that credential.

  claim.py <console> <code>   open the link the way in printed to <console>, in a browser that pins the certificate
                              whose fingerprint it printed, and claim the name of <code>, as a reinstall does
"""

import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

ACCEPTANCE = Path(__file__).resolve().parent
sys.path.insert(0, str(ACCEPTANCE))
from browser import chromium, mastercontainer_file, printed_link, verified  # noqa: E402
from playwright.sync_api import expect  # noqa: E402

CODES = ACCEPTANCE.parent / "provisionador" / "ci-codes.txt"
CREDENTIAL = "/mnt/docker-aio-config/provisionador/aps-name.json"  # where «Dirección» keeps the name's credential


def reserved():
    """gestion's reserved DEIS codes, in their order."""
    return [code for line in CODES.read_text(encoding="utf-8").splitlines() if (code := line.split("#")[0].strip())]


def api(page, method, path, body=None):
    """The Provisionador's answer to a request the page sends with its session: (status, JSON)."""
    return page.evaluate("""async ([method, path, body]) => {
      const answer = await fetch(path, {method, headers: {"Content-Type": "application/json"},
                                        body: body === null ? undefined : JSON.stringify(body)});
      return [answer.status, await answer.json().catch(() => null)];
    }""", [method, path, body])


def keep(code):
    """The claimed name's credential, from the mastercontainer's volume into NAMES; its password is masked first."""
    credential = json.loads(mastercontainer_file(CREDENTIAL))
    print(f"::add-mask::{credential['password']}", flush=True)
    path = Path(os.environ["NAMES"]) / f"{code}.json"
    path.unlink(missing_ok=True)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as file:
        json.dump(credential, file)


def claim(page, codes, patience=0):
    """The name «Dirección» claims for the first of `codes` no one holds, «Centro» confirming each code in turn. Only a
    test build claims, as run.sh tells (TEST_BUILD): any other candidate's names are production ones. The name service
    shows a name it has just freed held for some seconds more, so a code held is asked again for `patience` seconds."""
    if os.environ["TEST_BUILD"] != "true":
        sys.exit(f"{os.environ['TAG']} is not a test build: its names are production ones, and a run claims CI names "
                 "only")
    for code in codes:
        deadline = time.monotonic() + patience
        status, answer = api(page, "POST", "/api/centre", {"code": code})
        if status != 200:
            sys.exit(f"«Centro» refused DEIS code {code}: HTTP {status} {answer}")
        status, answer = api(page, "POST", "/api/address", {})
        while status == 409 and "settings" not in answer and time.monotonic() < deadline:
            time.sleep(10)
            status, answer = api(page, "POST", "/api/address", {})
        if status == 200:
            keep(code)
            print(f"{answer['address']['name']} claimed for DEIS code {code}")
            return answer["address"]["name"]
        if status != 409:
            sys.exit(f"«Dirección» answered HTTP {status}: {answer}")
        if "settings" in answer:  # on a Coolify server, the AIO settings its proxy does not run with yet
            sys.exit(f"«Dirección» asks for these settings in Coolify's proxy first: {answer['settings']}")
        print(f"::notice::DEIS code {code} holds a CI name already; the run takes the next reserved code.")
    sys.exit(f"every reserved DEIS code ({', '.join(codes)}) holds a CI name. APS Conecta frees a leftover one with "
             "gestion-aio's «APS name release» workflow on the ci deployment.")


def main(console, code):
    link, printed = printed_link(Path(console).read_text(encoding="utf-8"))
    url = urlsplit(link)
    with chromium(pinned=[verified(url.hostname, url.port, printed)]) as browser:
        page = browser.new_page()
        page.goto(link)
        expect(page.get_by_role("heading", name="Centro", exact=True)).to_be_visible(timeout=30_000)
        claim(page, [code], patience=120)  # the reset freed this code's name moments ago


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
