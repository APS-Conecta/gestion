#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Coolify test's acme-dns account storage, on the machine as root (aps/acceptance/coolify.sh): the HTTP storage
lego reads when the proxy's Traefik solves a name's DNS challenge (ACME_DNS_STORAGE_BASE_URL). GET /<name> answers the
acme-dns account of the APS name «Dirección» claimed, from the credential the Provisionador keeps in the
mastercontainer's volume, so that Traefik updates the name's challenge record through the name service as our Caddy
does. Any other name, or a name not claimed yet, is unknown; a new account is never stored. It logs nothing.

Usage: acme-dns-storage.py <port>
"""

import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CREDENTIAL = "/mnt/docker-aio-config/provisionador/aps-name.json"  # where «Dirección» keeps the name's credential


def credential():
    """The claimed name's credential, or {} before the claim."""
    read = subprocess.run(["docker", "exec", "nextcloud-aio-mastercontainer", "cat", CREDENTIAL], capture_output=True,
                          text=True, check=False)
    try:
        return json.loads(read.stdout) if read.returncode == 0 else {}
    except ValueError:
        return {}


class Storage(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # the account carries the credential's password

    def do_GET(self):
        found = credential()
        if not found or self.path.strip("/") != found.get("name"):
            return self.answer(404, {})
        self.answer(200, {"fulldomain": "", "subdomain": found["subdomain"], "username": found["username"],
                          "password": found["password"], "server_url": found["server_url"]})

    def do_POST(self):
        self.answer(403, {})

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(sys.argv[1])), Storage).serve_forever()
