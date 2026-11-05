#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""After «Listo» on a test build: the Suite manifest's apps in the installed suite. Every pinned app, each default own
and fork app and each optional app ticked at «Revisar», runs the version of the App release the manifest pins; no other
optional app is installed, and every default store app is enabled. The store is reachable from the Apps page: the list
the administrator's Apps page draws holds the store's apps beside the installed ones, and offers no store update for a
pinned app. Then a store update, as AIO's update runs it (occ app:update --all), leaves every pinned app at its pin. Any
other candidate's names are production ones, which a run never claims: there it says so and passes."""

import base64
import json
import os
import ssl
import sys
import urllib.request
from pathlib import Path

ACCEPTANCE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ACCEPTANCE), str(ACCEPTANCE.parent / "provisionador")]
from browser import STAGING_ROOTS, machine, mastercontainer_file, suite_name  # noqa: E402
from steps import apps  # noqa: E402

STATE = "/mnt/docker-aio-config/provisionador/state.json"
CONFIGURATION = "/mnt/docker-aio-config/data/configuration.json"  # AIO's, the administrator's password in its secrets
OCC = "sudo docker exec --user www-data nextcloud-aio-nextcloud php /var/www/html/occ --no-ansi"
APPS_PAGE = "/ocs/v2.php/apps/appstore/api/v1/apps?format=json"  # the list the Apps page draws

if os.environ["TEST_BUILD"] != "true":
    print(f"the apps run after «Listo», on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names are production "
          "ones")
    sys.exit()

ticked = json.loads(mastercontainer_file(STATE)).get("optional", [])
pinned = [app for app in apps.MANIFEST if "pin" in app and (not app.get("optional") or app["id"] in ticked)]
store = [app for app in apps.MANIFEST if app["source"] == "store"]
unticked = [app for app in apps.MANIFEST if app.get("optional") and app["id"] not in ticked]
print(f"ticked at «Revisar»: {ticked}")


def differences():
    """What the suite runs that the manifest does not pin, after printing each pinned app's version."""
    listed = json.loads(machine(f"{OCC} app:list --output=json"))
    enabled, installed = listed["enabled"], {**listed["enabled"], **listed["disabled"]}
    print("".join(f"{app['id']}: {enabled.get(app['id'], 'not enabled')}, pinned {app['pin']}\n" for app in pinned),
          end="")
    return ([f"{app['id']} does not run {app['pin']}" for app in pinned if f"v{enabled.get(app['id'])}" != app["pin"]]
            + [f"{app['id']} is not enabled" for app in store if app["id"] not in enabled]
            + [f"{app['id']} is installed, unticked at «Revisar»" for app in unticked if app["id"] in installed])


if wrong := differences():
    sys.exit("\n".join(wrong))

secrets = json.loads(mastercontainer_file(CONFIGURATION))["secrets"]  # never printed
login = base64.b64encode(f"admin:{secrets['NEXTCLOUD_PASSWORD']}".encode()).decode()
request = urllib.request.Request(f"https://{suite_name()}{APPS_PAGE}", headers={
    "Authorization": f"Basic {login}", "OCS-APIRequest": "true", "Accept": "application/json"})
with urllib.request.urlopen(request, timeout=300, context=ssl.create_default_context(cafile=STAGING_ROOTS)) as answer:
    page = {app["id"]: app for app in json.load(answer)["ocs"]["data"]}
offered = sorted(app for app, listed in page.items() if listed.get("appstore") and not listed.get("installed"))
print(f"the Apps page lists {len(page)} apps, {len(offered)} of them from the store and not installed: "
      f"{', '.join(offered[:8])}…")
for app in pinned:
    releases = page.get(app["id"], {}).get("releases") or [{}]
    print(f"{app['id']}: the store's newest is {releases[0].get('version', 'none')}, "
          f"the Apps page offers {page.get(app['id'], {}).get('update', 'no update')}")
if not offered:
    sys.exit("the Apps page lists no app of the store: the store is not reachable from it")
if updates := [app["id"] for app in pinned if "update" in page.get(app["id"], {})]:
    sys.exit(f"the Apps page offers a store update for the pinned apps {updates}")

print(machine(f"{OCC} app:update --all"), end="")
if wrong := differences():
    sys.exit("after a store update:\n" + "\n".join(wrong))
print("every pinned app runs its pin, before and after a store update, and the Apps page lists the store's apps")
