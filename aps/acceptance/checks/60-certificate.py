#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The suite's login page answers at its CI APS name with a valid Let's Encrypt staging certificate: our Caddy got it
through the name service's DNS challenge with no inbound port, as the machine sits behind the runner's NAT. The
certificate it serves for the name verifies against the staging roots alone, and a browser that trusts those alone
opens the login page at the name the runner's resolver answers."""

import os
import socket
import ssl
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from browser import STAGING_ROOTS, chromium, suite_name  # noqa: E402
from playwright.sync_api import Error, expect  # noqa: E402

WAIT = 12 * 60  # seconds; the DNS challenge usually takes a minute or two once Caddy runs

address, name = os.environ["ADDRESS"], suite_name()
evidence = Path(os.environ["EVIDENCE"])


def issuer():
    """The issuer of the certificate served for the name at the machine's address, verified for the name against the
    staging roots alone."""
    with socket.create_connection((address, 443), timeout=30) as raw, \
            ssl.create_default_context(cafile=str(STAGING_ROOTS)).wrap_socket(raw, server_hostname=name) as tls:
        return ", ".join(f"{key}={value}" for field in tls.getpeercert()["issuer"] for key, value in field)


deadline = time.monotonic() + WAIT
while True:
    try:
        certificate = issuer()
        break
    except OSError as error:  # no answer yet, or no certificate the staging roots verify for the name
        if time.monotonic() > deadline:
            sys.exit(f"{name} at {address} served no certificate the staging roots verify within {WAIT // 60} minutes: "
                     f"{error}")
        time.sleep(10)
print(f"{name} at {address}: a certificate the staging roots verify, issued by {certificate}")
if "(STAGING)" not in certificate:
    sys.exit(f"{name}'s certificate comes from {certificate}, not from Let's Encrypt's staging service")

with chromium() as browser:
    page = browser.new_page(viewport={"width": 1280, "height": 900})
    try:
        response = page.goto(f"https://{name}/login")
    except Error as error:
        sys.exit(f"the browser does not open https://{name}/login: {error.message.splitlines()[0]}")
    page.screenshot(path=evidence / "login.png")
    print(f"https://{name}/login: HTTP {response.status}")
    if not response.ok:
        sys.exit(f"https://{name}/login answers HTTP {response.status}")
    expect(page.locator("input[type=password]")).to_be_visible()
print(f"the login page answers at https://{name} with a valid staging certificate")
