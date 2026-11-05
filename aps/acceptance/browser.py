# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The acceptance harness's one way to open a browser: Chromium through Playwright, whose context adds trust only for
Let's Encrypt's staging roots, which the suite's certificate comes from in CI, and for the certificates a check pins
after verifying them itself, such as the Provisionador's, by the fingerprint the way in printed; and Firefox, for a
check that opens the suite's pages in both, trusting the staging roots alone. No check ignores
certificate errors. A check that calls gets fake media devices: Chromium's fake camera and a microphone that plays a
steady tone.

Checks import it after `sys.path.insert(0, <aps/acceptance>)`. It also runs a check's command lines and the way in on
the machine, reads the machine's state and the files of the mastercontainer there.
"""

import base64
import contextlib
import difflib
import hashlib
import json
import math
import os
import re
import ssl
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

from playwright.sync_api import sync_playwright

STAGING_ROOTS = Path(__file__).with_name("letsencrypt-staging-roots.pem")
# Fake media devices, granted to every page (a headless browser refuses them otherwise), whose sound and video a page
# plays without a click.
FAKE_MEDIA = ("--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream",
              "--autoplay-policy=no-user-gesture-required")


def machine(command, stdin=""):
    """What one command line run on the machine as the operator printed; it fails the check if it fails."""
    run = subprocess.run([os.environ["MACHINE"], command], input=stdin, capture_output=True, text=True, check=False)
    if run.returncode:
        sys.exit(f"on the machine, {command!r} failed:\n{run.stderr}")
    return run.stdout


# The machine's containers, images, volumes, networks, packages and the install's files; the mastercontainer's start
# time is left out, since a rerun restarts it.
STATE = """set -euo pipefail
docker ps --all --quiet | xargs --no-run-if-empty docker inspect --format '{{.Name}} {{.Id}} {{.Image}}' | sort
docker image ls --all --quiet --no-trunc | sort -u
docker volume ls --quiet | sort
docker network ls --quiet --no-trunc | sort
find /etc/apt /etc/sysctl.d -type f -exec sha256sum {} + | sort -k 2
dpkg-query --show
"""


def state():
    """The machine's state, as a harmless run of the way in again leaves it: the Bootstrap restarts the mastercontainer,
    and a redeploy of the Coolify resource recreates it from the image it ran, so on that way its container's ID is
    left out."""
    found = machine("sudo bash -s", STATE)
    if os.environ["WAY"] == "coolify":
        found = re.sub(r"^(/nextcloud-aio-mastercontainer) [0-9a-f]+ ", r"\1 ", found, flags=re.M)
    return found


def rerun(what):
    """What the way in, run again on the machine as the operator does (one-command.sh), printed, its fresh link whole,
    which stays out of the log and the evidence; it fails the check, named by `what`, if the run fails or changes the
    machine's state."""
    before = state()
    with tempfile.NamedTemporaryFile() as console:
        if subprocess.run([Path(__file__).with_name("one-command.sh"), console.name], check=False).returncode:
            sys.exit(f"{what} failed")
        printed = Path(console.name).read_text(encoding="utf-8")
    after = state()
    if after != before:
        sys.exit(f"{what} changed the machine:\n" + "".join(difflib.unified_diff(
            before.splitlines(keepends=True), after.splitlines(keepends=True), "before", "after")))
    return printed


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
    """The link and the certificate's fingerprint in what the way in printed last (the Bootstrap, or the Coolify
    resource's logs). The link's secret is masked in the CI log first."""
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


def tone(path):
    """Five seconds of a 440 Hz tone, which the fake microphone plays in a loop."""
    with wave.open(str(path), "wb") as out:
        out.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
        out.writeframes(b"".join(struct.pack("<h", round(12000 * math.sin(2 * math.pi * 440 * n / 48000)))
                                 for n in range(5 * 48000)))
    return path


def trust_staging(nssdb):
    """A new NSS database in the folder `nssdb` that trusts the staging roots, as a browser reads its own."""
    nssdb.mkdir(parents=True, exist_ok=True)
    subprocess.run(["certutil", "-N", "-d", f"sql:{nssdb}", "--empty-password"], check=True)
    roots = re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----\n", STAGING_ROOTS.read_text(), re.S)
    for n, root in enumerate(roots):
        subprocess.run(["certutil", "-A", "-d", f"sql:{nssdb}", "-n", f"staging-{n}", "-t", "C,,", "-a"],
                       input=root, text=True, check=True)


@contextlib.contextmanager
def chromium(pinned=(), media=False):
    """A Chromium browser trusting the staging roots (in its own NSS database) and the pinned PEM certificates; with
    `media`, its camera and its microphone are the fake ones."""
    with tempfile.TemporaryDirectory() as home, sync_playwright() as playwright:
        trust_staging(Path(home, ".pki", "nssdb"))
        pins = [f"--ignore-certificate-errors-spki-list={','.join(spki(pem) for pem in pinned)}"] if pinned else []
        fake = [*FAKE_MEDIA, f"--use-file-for-fake-audio-capture={tone(Path(home, 'tone.wav'))}"] if media else []
        browser = playwright.chromium.launch(env={**os.environ, "HOME": home}, args=pins + fake)
        try:
            yield browser
        finally:
            browser.close()


@contextlib.contextmanager
def firefox(**options):
    """A Firefox browsing context with the context `options`, its profile's NSS database trusting the staging roots."""
    with tempfile.TemporaryDirectory() as profile, sync_playwright() as playwright:
        trust_staging(Path(profile))
        context = playwright.firefox.launch_persistent_context(profile, **options)
        try:
            yield context
        finally:
            context.close()
