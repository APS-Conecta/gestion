#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The image test: our mastercontainer, run as vanilla's command runs it and checked from outside.

  image-test.py <image>

It starts <image> with the fixed name and volume, the Docker socket and the interface port, plus the interface
address, and checks through AIO's interface: the Provisionador answers there with AIO's certificate; the log has the
link, its QR code and that certificate's fingerprint; a restart prints a fresh link to the same state; after «Listo»
the same address serves AIO's page, and a restart prints no link. It refuses to run where a mastercontainer exists,
and removes the container and the volume it made.
"""

import hashlib
import http.client
import json
import re
import socket
import ssl
import subprocess
import sys
import time
from urllib.parse import urlsplit

NAME = "nextcloud-aio-mastercontainer"
VOLUME = "nextcloud_aio_mastercontainer"
HOST, PORT = "127.0.0.1", 8080  # the runner opens AIO's interface on its own loopback
ROOT = "/mnt/docker-aio-config/caddy-internal/pki/authorities/local/root.crt"  # the authority AIO's interface uses
LISTO = "/mnt/docker-aio-config/provisionador/listo"
CODE = "110485"  # Posta de Salud Rural Loica, in the shipped register
LINK = re.compile(r"https://\S+/#\S+")
FINGERPRINT = re.compile(r"(?:[0-9A-F]{2}:){31}[0-9A-F]{2}")
QR = re.compile(r"[█▀▄ ]{21,}")
CLOSED = "La instalación terminó en «Listo»"


def docker(*args):
    return subprocess.run(["docker", *args], check=True, capture_output=True, text=True).stdout


def log():
    return subprocess.run(["docker", "logs", NAME], check=True, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL).stdout


def wait(what, ready, timeout=240):
    deadline = time.monotonic() + timeout
    while not (found := ready()):
        if time.monotonic() > deadline:
            sys.exit(f"image test: no {what} after {timeout} s; the log:\n{log()}")
        time.sleep(2)
    return found


def links():
    return LINK.findall(log())


def fingerprint(der):
    h = hashlib.sha256(der).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


def served_certificate():
    """The certificate a TLS client receives at the link's address, as DER; no server name, as for any IP address."""
    context = ssl.create_default_context(cadata=docker("exec", NAME, "cat", ROOT))
    context.check_hostname = False  # the operator checks the fingerprint, not the name
    with context.wrap_socket(socket.create_connection((HOST, PORT), timeout=10)) as tls:
        return tls.getpeercert(binary_form=True)  # the handshake proves AIO's authority signed it


class Browser:
    """A browser at the link's address that trusts AIO's interface certificate and keeps the session cookie."""

    def __init__(self):
        self.context = ssl.create_default_context(cadata=docker("exec", NAME, "cat", ROOT))
        self.context.check_hostname = False
        self.cookie = None
        self.headers = {}

    def request(self, method, path, body=None):
        headers = {"Sec-Fetch-Site": "same-origin"}  # as a browser sends from the page; AIO's page requires it
        if self.cookie:
            headers["Cookie"] = self.cookie
        if body is not None:
            headers["Content-Type"] = "application/json"
        conn = http.client.HTTPSConnection(HOST, PORT, context=self.context, timeout=10)
        try:
            conn.request(method, path, body=None if body is None else json.dumps(body), headers=headers)
            response = conn.getresponse()
            raw = response.read()
            self.headers = {k.lower(): v for k, v in response.getheaders()}
        finally:
            conn.close()
        if "set-cookie" in self.headers:
            self.cookie = self.headers["set-cookie"].split(";", 1)[0]
        is_json = self.headers.get("content-type", "").startswith("application/json")
        return response.status, json.loads(raw) if is_json else raw

    def open(self, link):
        return self.request("POST", "/api/session", {"link": urlsplit(link).fragment})


def status_of(path):
    """The status AIO's interface answers for `path`, or None while it does not answer yet."""
    try:
        return Browser().request("GET", path)[0]
    except OSError:
        return None


def check(condition, message):
    if not condition:
        sys.exit(f"image test: {message}")
    print(f"  ok: {message}")


def the_first_start():
    link = wait("link in the log", links)[0]
    text = log()
    check(urlsplit(link).netloc == f"{HOST}:{PORT}", f"the link names the interface address: {urlsplit(link).netloc}")
    check(QR.search(text), "the log has the link's QR code")
    secret = urlsplit(link).fragment
    check(all(link in line for line in text.splitlines() if secret in line),
          "the secret appears only in the line that prints the link")
    printed = FINGERPRINT.search(text)
    check(printed and printed.group(0) == fingerprint(served_certificate()),
          "the printed fingerprint is the certificate AIO's authority issued for the link's address")
    return link


def the_provisionador_answers(link):
    browser = Browser()
    status, page = browser.request("GET", "/")
    check(status == 200 and b'<html lang="es-CL">' in page and b"<h1>Centro</h1>" in page,
          "8080 serves the Provisionador's page")
    policy = browser.headers.get("content-security-policy", "")
    check("img-src 'self' data: https://tile.openstreetmap.org;" in policy and "trusted-types default;" in policy
          and "require-trusted-types-for 'script';" in policy
          and browser.headers.get("cross-origin-embedder-policy") == "require-corp",
          "the page has AIO's headers, with images also from data: and OpenStreetMap's tiles, and a default Trusted "
          "Types policy")
    assets = re.findall(rb'(?:src|href)="(/[^"]+)"', page)
    fonts = re.findall(rb'url\("(/[^"]+)"\)', browser.request("GET", "/app.css")[1])
    for path in assets + fonts:
        check(browser.request("GET", path.decode())[0] == 200, f"{path.decode()} loads")
    browser.request("GET", "/aps/tokens.css")
    check("trusted-types 'none';" in browser.headers.get("content-security-policy", ""),
          "the brand files under /aps/ keep AIO's own policy")
    status, _ = browser.open(link)
    check(status == 200 and browser.cookie, "the link opens a session")
    status, body = browser.request("POST", "/api/centre", {"code": CODE})
    check(status == 200 and body["centre"]["timezone"] == "America/Santiago", "«Centro» keeps the establishment")
    session = browser.cookie.split("=", 1)[1]
    check(session not in log(), "the log never shows a session")
    return browser


def a_restart(first, operator):
    docker("restart", NAME)
    second = wait("fresh link after the restart", lambda: links()[1:])[0]
    check(second != first, "a restart prints a fresh link")
    printed = FINGERPRINT.findall(log())
    check(len(printed) == 2 and printed[1] == fingerprint(served_certificate()),
          "the fingerprint printed again is the certificate served")
    check(Browser().open(first)[0] == 401, "the link before the restart stops working")
    check(Browser().open(second)[0] == 200, "the fresh link opens a session")
    status, body = operator.request("GET", "/api/state")
    check(status == 200 and body["centre"]["code"] == CODE, "the session and the state survive the restart")


def listo():
    docker("exec", "--user", "www-data", NAME, "touch", LISTO)  # «Listo», as the Provisionador reaches it
    browser = Browser()
    status, _ = browser.request("GET", "/")
    check(status == 302 and browser.headers.get("location") == "setup"
          and "trusted-types 'none';" in browser.headers.get("content-security-policy", ""),
          "after «Listo», 8080 serves AIO's page, with AIO's own headers")
    docker("restart", NAME)
    wait("note that the install ended", lambda: CLOSED in log())
    check(len(links()) == 2, "a restart after «Listo» prints no link")
    wait("AIO's page after the restart", lambda: status_of("/") == 302)
    check(True, "after the restart, 8080 still serves AIO's page")


def main(image):
    if docker("ps", "--all", "--quiet", "--filter", f"name=^{NAME}$") or docker("volume", "ls", "--quiet", "--filter",
                                                                               f"name=^{VOLUME}$"):
        sys.exit(f"image test: {NAME} or {VOLUME} already exists here; run it on a machine of its own")
    try:
        docker("run", "--detach", "--init", "--sig-proxy=false", "--name", NAME, "--restart", "always",
               "--publish", f"{PORT}:8080", "--env", f"APS_INTERFACE_ADDRESS={HOST}",
               "--volume", f"{VOLUME}:/mnt/docker-aio-config",
               "--volume", "/var/run/docker.sock:/var/run/docker.sock:ro", image)
        first = the_first_start()
        operator = the_provisionador_answers(first)
        a_restart(first, operator)
        listo()
    finally:
        subprocess.run(["docker", "rm", "--force", NAME], capture_output=True)
        subprocess.run(["docker", "volume", "rm", VOLUME], capture_output=True)
    print("image test: green")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
