#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""After «Listo» on a test build: the Provisionador's end-of-install check was clean, every install step green in its
state, and the baseline settings are in place on the real suite. Nextcloud holds the security, background-job and
locale settings, the centre's timezone for its clock and its log among them, and the certificates its own requests
trust verify the suite's name, whose certificate comes from a staging root of AIO's folder of trusted CAs, and the
ISP's site, which serves only its leaf. That site is outside the suite and its step only warns: when the site gives no
answer, or the certificates step recorded its notice, the check says so and passes. Any other candidate's names and
certificates are production ones, which a run never claims: there it says so and passes."""

import json
import os
import sys
from pathlib import Path

ACCEPTANCE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ACCEPTANCE), str(ACCEPTANCE.parent / "provisionador")]
from browser import machine, mastercontainer_file, suite_name  # noqa: E402
from steps import certificates  # noqa: E402

STATE = "/mnt/docker-aio-config/provisionador/state.json"
NEXTCLOUD = "sudo docker exec --interactive --user www-data nextcloud-aio-nextcloud"
SYSTEM = {"remember_login_cookie_lifetime": 0, "session_lifetime": 900, "session_keepalive": False,
          "default_language": "es", "force_language": "es", "default_locale": "es_CL", "default_phone_region": "CL"}
APPS = {"admin_audit": {"enabled": "yes"}, "core": {"backgroundjobs_mode": "cron"}}
VERIFIED = "Verify return code: 0 (ok)"
# In the Nextcloud container, for each host in "$@": the verdict of a TLS handshake against the bundle Nextcloud's own
# HTTP client verifies with.
VERIFY = r"""
set -eu
bundle=$(php -d display_errors=stderr -r 'require "/var/www/html/lib/base.php";
  echo \OCP\Server::get(\OCP\ICertificateManager::class)->getAbsoluteBundlePath();')
for host in "$@"; do
  verdict=$(timeout 30 openssl s_client -connect "$host:443" -servername "$host" -verify_hostname "$host" \
    -CAfile "$bundle" < /dev/null 2>&1 | grep -m 1 'Verify return code' || true)
  echo "$host: ${verdict:-no answer}"
done
"""

if os.environ["TEST_BUILD"] != "true":
    print(f"the baseline runs after «Listo», on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names and "
          "certificates are production ones")
    sys.exit()

state = json.loads(mastercontainer_file(STATE))
steps = state.get("install", {}).get("steps", {})
print("".join(f"{name}: {step['status']} {step.get('reason', '')}\n" for name, step in steps.items()), end="")
if not steps:
    sys.exit("at «Listo», the Provisionador's state has no install steps")
if any(step["status"] != "green" for step in steps.values()):
    sys.exit("at «Listo», the Provisionador's state has an install step that is not green")

zone = state["centre"]["timezone"]
system = {**SYSTEM, "default_timezone": zone, "logtimezone": zone}
held = json.loads(machine(f"{NEXTCLOUD} php /var/www/html/occ config:list --output=json"))
found = {"system": {key: held["system"].get(key) for key in system},
         "apps": {app: {key: held["apps"].get(app, {}).get(key) for key in values} for app, values in APPS.items()}}
print(f"Nextcloud holds {found}")
if found != {"system": system, "apps": APPS}:
    sys.exit("Nextcloud does not hold the baseline settings the install steps declare")

domain = suite_name()
answers = machine(f"{NEXTCLOUD} sh -s {domain} {certificates.ISP}", stdin=VERIFY)
print(answers, end="")
verdicts = {host: verdict.strip() for host, verdict in (line.split(": ", 1) for line in answers.splitlines())}
if verdicts[domain] != VERIFIED:
    sys.exit("Nextcloud's own requests do not verify the suite's name")
if verdicts[certificates.ISP] != VERIFIED:
    if certificates.ISP_UNTRUSTED.format(certificates.ISP) in steps.get("certificates", {}).get("reason", ""):
        print("the ISP's site is not verified, as the certificates step's notice says")
    elif verdicts[certificates.ISP] == "no answer":
        print("the ISP's site gives no answer")
    else:
        sys.exit("the ISP's site answers and Nextcloud's own requests do not verify it, with no notice from the "
                 "certificates step")
print("every install step is green and the baseline settings are in place on the suite")
