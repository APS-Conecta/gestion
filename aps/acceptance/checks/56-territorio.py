#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""After «Listo» on a test build: Territorio shows the establishment's comuna data. Territorio's comuna is the centre's,
and through Territorio's own API the administrator finds the comuna's unidades vecinales, each an area, and the centre
among the comuna's health establishments, at a point. A test build cuts the unidades vecinales from the cadastre's CI
subset, one area a comuna, since the ministry's server, the cadastre's origin, does not answer GitHub's runners
(aps/RELEASING.md, section 3). Any other candidate's names are production ones, which a run never claims: there it says
so and passes."""

import base64
import json
import os
import ssl
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from browser import STAGING_ROOTS, machine, mastercontainer_file, suite_name  # noqa: E402

STATE = "/mnt/docker-aio-config/provisionador/state.json"
CONFIGURATION = "/mnt/docker-aio-config/data/configuration.json"  # AIO's, the administrator's password in its secrets
OCC = "sudo docker exec --user www-data nextcloud-aio-nextcloud php /var/www/html/occ --no-ansi"
RECORDS = "/ocs/v2.php/apps/territorio/api/v1/subcategories/{}/{}/features"  # Territorio's records under one pair
HEALTH = ("cesfam", "sapu", "establecimiento")  # the subcategories of «salud» the step files establishments under
AREA = ("Polygon", "MultiPolygon")

if os.environ["TEST_BUILD"] != "true":
    print(f"Territorio's comuna data is checked after «Listo», on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s "
          "names are production ones")
    sys.exit()

centre = json.loads(mastercontainer_file(STATE))["centre"]
comuna = {key: machine(f"{OCC} config:app:get --default-value= territorio {key}").strip()
          for key in ("comuna_cut", "comuna_name")}
print(f"Territorio's comuna: {comuna['comuna_name']} ({comuna['comuna_cut']}); the centre's: {centre['comuna']} "
      f"({centre['comuna_code']})")
wrong = [] if comuna["comuna_cut"] == centre["comuna_code"] else ["Territorio's comuna is not the centre's"]

secrets = json.loads(mastercontainer_file(CONFIGURATION))["secrets"]  # never printed
login = base64.b64encode(f"admin:{secrets['NEXTCLOUD_PASSWORD']}".encode()).decode()
trust = ssl.create_default_context(cafile=STAGING_ROOTS)


def records(category, subcategory):
    """Territorio's records filed under the pair, as its API gives them to the administrator."""
    request = urllib.request.Request(f"https://{suite_name()}{RECORDS.format(category, subcategory)}", headers={
        "Authorization": f"Basic {login}", "OCS-APIRequest": "true", "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=120, context=trust) as answer:
        return json.load(answer)["ocs"]["data"]


areas = records("division_territorial", "unidad_vecinal")
establishments = [record for subcategory in HEALTH for record in records("salud", subcategory)]
shapes = [(record["geometry"] or {}).get("type") for record in areas]
print(f"Territorio shows {len(areas)} unidades vecinales, {sum(shape in AREA for shape in shapes)} of them areas, and "
      f"{len(establishments)} health establishments")
if not areas or any(shape not in AREA for shape in shapes):
    wrong.append("Territorio shows no unidad vecinal of the comuna, or one that is not an area")
own = next((record for record in establishments if record["name"] == centre["name"]), None)
if own is None or (own["geometry"] or {}).get("type") != "Point":
    wrong.append(f"Territorio shows the centre, {centre['name']}, at no point among the comuna's health establishments")
else:
    print(f"the centre, {centre['name']}, is among them, a «{own['subcategory']}» at {own['geometry']['coordinates']}")
sys.exit("\n".join(wrong) or None)
