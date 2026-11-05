#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The CI proof of the APS name setup (ADR 0028): on a GitHub runner, which takes no inbound connections, our Caddy
image gets a Let's Encrypt staging certificate for a CI name through the name service's DNS challenge, and the run
frees the name with its own credential.

  name-test.py claim <credential>                claim a CI name with the first DEIS code of ci-codes.txt that no
                                                 one holds, point it at this machine and keep its credential in
                                                 <credential>, readable by its owner only
  name-test.py certificate <credential> <image>  run <image>, our Caddy, for the name with the environment
                                                 community-containers/caddy/caddy.json gives it and Let's Encrypt's
                                                 staging directory, and wait for the certificate it serves
  name-test.py release <credential>              free the name with its own credential; nothing when none was claimed

The names come from the name service's CI deployment, under ci.gestion.apsconecta.cl, through the suite port's own
client. The workflow runs the release even when an earlier step failed. No credential reaches a command line or the
log: the password goes to the containers through the environment and is masked in the log.
"""

import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import suite  # noqa: E402

CI = "https://gestion-nombres-ci.apsconecta.workers.dev"  # the name service's CI deployment
STAGING = "https://acme-staging-v02.api.letsencrypt.org/directory"
CODES = HERE / "ci-codes.txt"
WAIT = 12 * 60  # seconds; the DNS challenge usually takes a minute or two


def reserved():
    """gestion's reserved DEIS codes, in their order."""
    return [code for line in CODES.read_text(encoding="utf-8").splitlines() if (code := line.split("#")[0].strip())]


def mask(value):
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{value}", flush=True)


def stored(path):
    credential = json.loads(Path(path).read_text(encoding="utf-8"))
    mask(credential["password"])
    return credential


def claim(path):
    names = suite.NameService(CI)
    for code in reserved():
        try:
            credential = names.claim(code)
        except suite.Held:
            print(f"::notice::DEIS code {code} holds a CI name already; the run takes the next reserved code.")
            continue
        mask(credential["password"])
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as file:
            json.dump(credential, file)
        names.publish(credential, suite.arrival())
        print(f"{credential['name']} claimed for DEIS code {code}, pointed at this machine's {suite.arrival()}")
        return 0
    sys.exit(f"every reserved DEIS code ({', '.join(reserved())}) holds a CI name. APS Conecta frees a leftover one "
             "with gestion-aio's «APS name release» workflow on the ci deployment.")


def caddy_environment(credential):
    """What AIO hands our Caddy for the name: the environment of its definition, with the values AIO puts in for its
    placeholders. Its own secrets are random, as AIO makes them; a placeholder this proof cannot fill fails it."""
    definition = suite.caddy()
    variables = dict(variable.split("=", 1) for variable in definition["aio_variables"])
    values = {"NC_DOMAIN": credential["name"], "TIMEZONE": "Etc/UTC", "APACHE_PORT": variables["apache_port"],
              "APACHE_IP_BINDING": variables["apache_ip_binding"],
              **{secret: secrets.token_hex(24) for secret in definition["secrets"]}, **suite.acmedns(credential)}
    return dict(re.sub(r"%([^%]+)%", lambda found: values[found.group(1)], entry).split("=", 1)
                for entry in definition["environment"])


def docker(*args, environment=None):
    return subprocess.run(["docker", *args], check=True, capture_output=True, text=True,
                          env=environment and {**os.environ, **environment}).stdout.strip()


def served(port, name):
    """The issuer and the names of the certificate served for `name` on this machine's loopback, as openssl prints
    them; empty while there is none."""
    pem = subprocess.run(["openssl", "s_client", "-connect", f"127.0.0.1:{port}", "-servername", name],
                         input="", capture_output=True, text=True, timeout=30).stdout
    return subprocess.run(["openssl", "x509", "-noout", "-issuer", "-ext", "subjectAltName"], input=pem,
                          capture_output=True, text=True).stdout.strip()


def certificate(path, image):
    credential = stored(path)
    name, run = credential["name"], f"aps-name-test-{os.getpid()}"
    environment = {**caddy_environment(credential), "ACME_CA": STAGING}
    with tempfile.TemporaryDirectory() as nextcloud:
        # What upstream's Caddy start waits for: Nextcloud's port, and the admin's Caddy folder in Nextcloud's data,
        # which the image's www-data reads.
        folder = Path(nextcloud, "admin", "files", "nextcloud-aio-caddy")
        folder.mkdir(parents=True)
        (folder / "allowed-countries.txt").touch()
        for directory in (nextcloud, folder.parents[1], folder.parent, folder):
            os.chmod(directory, 0o755)
        try:
            docker("network", "create", run)
            docker("run", "--detach", "--name", f"{run}-nextcloud", "--network", run, "--network-alias",
                   "nextcloud-aio-nextcloud", "--env", "XDG_DATA_HOME=/tmp", "--entrypoint", "caddy", image, "respond",
                   "--listen", ":9001")
            docker("run", "--detach", "--name", f"{run}-caddy", "--network", run, "--network-alias",
                   "nextcloud-aio-caddy", "--add-host", "host.docker.internal:host-gateway", "--volume",
                   f"{run}:/data", "--volume", f"{nextcloud}:/nextcloud:ro", "--publish", "127.0.0.1::443",
                   *[part for key in environment for part in ("--env", key)], image, environment=environment)
            port = docker("port", f"{run}-caddy", "443/tcp").splitlines()[0].rsplit(":", 1)[1]
            deadline = time.monotonic() + WAIT
            while "(STAGING)" not in (found := served(port, name)) and time.monotonic() < deadline:
                time.sleep(10)
            print(f"{name}, served by our Caddy with no inbound port:\n{found or 'no certificate'}")
            if "(STAGING)" not in found or f"DNS:{name}" not in found:
                log = subprocess.run(["docker", "logs", f"{run}-caddy"], capture_output=True, text=True)
                print((log.stdout + log.stderr).replace(credential["password"], "[credential]")[-6000:])
                sys.exit(f"Let's Encrypt's staging service issued no certificate for {name} within {WAIT // 60} "
                         "minutes")
        finally:
            subprocess.run(["docker", "rm", "--force", "--volumes", f"{run}-caddy", f"{run}-nextcloud"],
                           capture_output=True)
            subprocess.run(["docker", "volume", "rm", run], capture_output=True)
            subprocess.run(["docker", "network", "rm", run], capture_output=True)
    return 0


def release(path):
    try:
        credential = stored(path)
    except FileNotFoundError:
        print("No CI name was claimed, so none is freed.")
        return 0
    suite.NameService(CI).release(credential)
    Path(path).unlink()
    print(f"{credential['name']} freed with its own credential")
    return 0


def main(argv):
    commands = {"claim": (claim, 1), "certificate": (certificate, 2), "release": (release, 1)}
    if not argv or argv[0] not in commands or len(argv) != commands[argv[0]][1] + 1:
        sys.exit(__doc__)
    try:
        return commands[argv[0]][0](*argv[1:])
    except suite.Unreachable as refused:
        sys.exit(f"name service: {refused}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
