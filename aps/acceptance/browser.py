# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The acceptance harness's one way to open a browser: Chromium through Playwright, whose context adds trust only for
Let's Encrypt's staging roots, which the suite's certificate comes from in CI, and for the certificates a check pins
after verifying them itself, such as the Provisionador's, by the fingerprint the Bootstrap printed. No check ignores
certificate errors.

Checks import it after `sys.path.insert(0, <aps/acceptance>)`. It also runs a check's command lines on the machine and
reads the files of the mastercontainer there.
"""

import base64
import contextlib
import hashlib
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
from pathlib import Path

from playwright.sync_api import sync_playwright

STAGING_ROOTS = Path(__file__).with_name("letsencrypt-staging-roots.pem")


def machine(command, stdin=""):
    """What one command line run on the machine as the operator printed; it fails the check if it fails."""
    run = subprocess.run([os.environ["MACHINE"], command], input=stdin, capture_output=True, text=True, check=False)
    if run.returncode:
        sys.exit(f"on the machine, {command!r} failed:\n{run.stderr}")
    return run.stdout


def mastercontainer_file(path):
    """A file of the mastercontainer on the machine, such as AIO's settings file; never print a secret it holds."""
    return machine(f"sudo docker exec nextcloud-aio-mastercontainer cat {path}")


def suite_name():
    """The suite's name: AIO's domain, which «Dirección» set."""
    return json.loads(mastercontainer_file("/mnt/docker-aio-config/data/configuration.json")).get("domain") \
        or sys.exit("AIO has no domain: «Dirección» claimed no name")


def fingerprint(pem):
    h = hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


def verified(host, port, printed):
    """The certificate the server presents, if its SHA-256 fingerprint is the printed one, as the operator compares it
    before trusting the Provisionador."""
    pem = ssl.get_server_certificate((host, port))
    if fingerprint(pem) != printed:
        sys.exit(f"{host}:{port} presents the certificate {fingerprint(pem)}, not the printed {printed}")
    return pem


def printed_link(output):
    """The link and the certificate's fingerprint in what the Bootstrap printed last. The link's secret is masked
    in the CI log first."""
    links = re.findall(r"https://\S+#[\w-]+", output)
    printed = re.findall(r"(?:[0-9A-F]{2}:){31}[0-9A-F]{2}", output)
    if not (links and printed):
        sys.exit("no link and certificate fingerprint were printed")
    print(f"::add-mask::{links[-1].rsplit('#', 1)[1]}", flush=True)
    return links[-1], printed[-1]


def spki(pem):
    """The SHA-256 of the certificate's public key, base64, as Chromium pins it."""
    key = subprocess.run(["openssl", "x509", "-pubkey", "-noout"], input=pem, capture_output=True, text=True,
                         check=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=key.encode(), capture_output=True,
                         check=True).stdout
    return base64.b64encode(hashlib.sha256(der).digest()).decode()


@contextlib.contextmanager
def chromium(pinned=()):
    """A Chromium browser trusting the staging roots (in its own NSS database) and the pinned PEM certificates."""
    with tempfile.TemporaryDirectory() as home, sync_playwright() as playwright:
        nssdb = Path(home, ".pki", "nssdb")
        nssdb.mkdir(parents=True)
        subprocess.run(["certutil", "-N", "-d", f"sql:{nssdb}", "--empty-password"], check=True)
        roots = re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----\n", STAGING_ROOTS.read_text(), re.S)
        for n, root in enumerate(roots):
            subprocess.run(["certutil", "-A", "-d", f"sql:{nssdb}", "-n", f"staging-{n}", "-t", "C,,", "-a"],
                           input=root, text=True, check=True)
        pins = [f"--ignore-certificate-errors-spki-list={','.join(spki(pem) for pem in pinned)}"] if pinned else []
        browser = playwright.chromium.launch(env={**os.environ, "HOME": home}, args=pins)
        try:
            yield browser
        finally:
            browser.close()
