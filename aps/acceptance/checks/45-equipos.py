#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Equipos» in the installed suite, on a test build, from the sectors and programs 40-install typed there: Nextcloud
holds every group the install declares and each group folder with exactly the declared groups' permissions, and each
cargo account is enabled in its groups. A staff member of the first sector and the first program, in the groups a
person of the staff gets, has never signed in: their first WebDAV request, an upload into the sector's nested folder,
succeeds, as one into the program's does, while Transversal, which the staff read, refuses theirs; they see their own
sector's and program's folders and no other team's, and Transversal's subfolders. Their login lands on the welcome
page, which names the centre. The sector's jefatura, a cargo account, signs in with the first password the install
kept: its first request, an upload into the same folder, succeeds, and a unit's folder, which the jefaturas read and
share, refuses its upload. Any other candidate's names are production ones, which a run never claims: there it says so
and passes."""

import base64
import json
import os
import secrets
import ssl
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

ACCEPTANCE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ACCEPTANCE), str(ACCEPTANCE.parent / "provisionador")]
import teams  # noqa: E402
from browser import STAGING_ROOTS, chromium, machine, mastercontainer_file, suite_name  # noqa: E402
from playwright.sync_api import expect  # noqa: E402

STATE = "/mnt/docker-aio-config/provisionador/state.json"
PASSWORDS = "/mnt/docker-aio-config/provisionador/first-passwords.json"  # each created account's, by its username
NEXTCLOUD = "sudo docker exec --interactive --user www-data nextcloud-aio-nextcloud"
OCC = f"{NEXTCLOUD} php /var/www/html/occ"
STAFF, ROLE = "prueba.equipo", "role-enfermeria"  # the staff member: a nurse of the first sector and the first program
DAV = "{DAV:}"

if os.environ["TEST_BUILD"] != "true":
    print(f"«Equipos» is checked on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names are production ones")
    sys.exit()
evidence = Path(os.environ["EVIDENCE"])
state = json.loads(mastercontainer_file(STATE))
declared, centre = state.get("teams", []), state["centre"]
print("«Equipos» declared: " + (", ".join(team["name"] for team in declared) or "no team"))
wrong = [] if {team["kind"] for team in declared} == {"sector", "program"} else [
    "«Equipos» did not declare both a sector and a program"]

held = json.loads(machine(f"{OCC} group:list --output=json")) or {}
wrong += [f"Nextcloud has no group {group}" for group in teams.groups(declared, centre["type"]) if group not in held]
listed = json.loads(machine(f"{OCC} groupfolders:list --output=json"))
grants = {f["mountPoint"]: f.get("groups_list") or {} for f in (listed.values() if isinstance(listed, dict) else listed)}
for mount, declared_grants in teams.folders(declared).items():
    wanted = {group: teams.bits(words) for group, words in declared_grants.items()}
    print(f"{mount}: {grants.get(mount)}")
    if grants.get(mount) != wanted:
        wrong.append(f"the group folder {mount} grants {grants.get(mount)}, not {wanted}")
users = json.loads(machine(f"{OCC} user:list --output=json"))
accounts = teams.cargo_accounts(declared, centre["type"])
for account in accounts:
    if account["user"] not in users:
        wrong.append(f"the cargo account {account['user']} does not exist")
        continue
    info = json.loads(machine(f"{OCC} user:info {account['user']} --output=json"))
    print(f"{account['user']}: {info['display_name']}, enabled {info['enabled']}, in {sorted(info['groups'])}")
    if not (info["enabled"] and set(account["groups"]) <= set(info["groups"])):
        wrong.append(f"the cargo account {account['user']} is not enabled in {account['groups']}")
if wrong:
    sys.exit("\n".join(wrong))

suite = suite_name()
tls = ssl.create_default_context(cafile=STAGING_ROOTS)
sector = next(team for team in declared if team["kind"] == "sector")
program = next(team for team in declared if team["kind"] == "program")


def dav(user, password, method, path, body=None):
    """The suite's WebDAV answer to the user's request for `path` in their files: its status and its body."""
    login = base64.b64encode(f"{user}:{password}".encode()).decode()
    headers = {"Authorization": f"Basic {login}", **({"Depth": "1"} if method == "PROPFIND" else {})}
    request = urllib.request.Request(f"https://{suite}/remote.php/dav/files/{user}/{quote(path)}", data=body,
                                     method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=300, context=tls) as answer:
            return answer.status, answer.read()
    except urllib.error.HTTPError as refusal:
        return refusal.code, refusal.read()


def folder(user, password, path=""):
    """The names the folder `path` holds, as the user's WebDAV listing shows them."""
    status, body = dav(user, password, "PROPFIND", path)
    if status != 207:
        sys.exit(f"{user}'s listing of /{path} answered HTTP {status}")
    itself = unquote(urlsplit(f"https://{suite}/remote.php/dav/files/{user}/{quote(path)}").path).rstrip("/")
    hrefs = (unquote(response.findtext(f"{DAV}href")).rstrip("/") for response in ET.fromstring(body).iter(
        f"{DAV}response"))
    return {href.rsplit("/", 1)[-1] for href in hrefs if href != itself}


def upload(user, password, into, expected):
    """A file the user uploads into the folder `into`, which the suite answers with `expected`, then removes."""
    path = f"{into}/prueba-{secrets.token_hex(4)}.txt"
    status, _ = dav(user, password, "PUT", path, f"{user} sube un archivo a {into}\n".encode())
    print(f"{user} uploads into {into}: HTTP {status}")
    if status == 201:
        dav(user, password, "DELETE", path)
    return [] if status == expected else [f"{user}'s upload into {into} answered HTTP {status}, not {expected}"]


password = secrets.token_urlsafe(18)  # the staff member's, on stdin only
print(f"::add-mask::{password}", flush=True)
member = [teams.STAFF, teams.ROLES[ROLE][1], ROLE, sector["id"], program["id"]]
machine(f"{NEXTCLOUD} sh -c 'read -r OC_PASS && export OC_PASS && php /var/www/html/occ user:add --password-from-env "
        f"--display-name \"Prueba Equipo\" {' '.join(f'--group {group}' for group in member)} {STAFF}'",
        stdin=f"{password}\n")
wrong += upload(STAFF, password, sector["folder"], 201)  # their first request
wrong += upload(STAFF, password, program["folder"], 201)
wrong += upload(STAFF, password, teams.TRANSVERSAL, 403)
seen = {path: folder(STAFF, password, path) for path in ("", "Sectores", "Programas", teams.TRANSVERSAL)}
(evidence / "carpetas.json").write_text(json.dumps({path: sorted(names) for path, names in seen.items()},
                                                   ensure_ascii=False, indent=1), encoding="utf-8")
print(f"{STAFF} sees {json.dumps({path: sorted(names) for path, names in seen.items()}, ensure_ascii=False)}")
if not {teams.TRANSVERSAL, "Sectores", "Programas"} <= seen[""] or "Unidades" in seen[""]:
    wrong.append(f"{STAFF}'s files hold {sorted(seen[''])}: not Transversal, Sectores and Programas without Unidades")
for path, team in (("Sectores", sector), ("Programas", program)):
    if seen[path] != {team["folder"].removeprefix(f"{path}/")}:
        wrong.append(f"{STAFF} sees {sorted(seen[path])} in {path}, not their team's folder alone")
if not set(teams.SUBFOLDERS) <= seen[teams.TRANSVERSAL]:
    wrong.append(f"{STAFF} does not see Transversal's subfolders {teams.SUBFOLDERS}")

with chromium() as browser:
    context = browser.new_context(locale="es-CL", viewport={"width": 1440, "height": 900})
    context.set_default_timeout(120_000)  # a first sign-in right after «Listo» may take longer than 30 s
    page = context.new_page()
    page.goto(f"https://{suite}/login")
    page.fill("#user", STAFF)
    page.fill("#password", password)
    page.click("[data-login-form-submit]")
    page.wait_for_url(lambda url: "/login" not in url)
    print(f"{STAFF}'s login lands on {page.url}")
    if "/apps/intravox" not in page.url:
        page.screenshot(path=evidence / "bienvenida.png")
        sys.exit("\n".join([*wrong, f"{STAFF}'s login lands on {page.url}, not on the welcome page"]))
    expect(page.get_by_text(centre["name"], exact=True).first).to_be_visible(timeout=120_000)
    page.screenshot(path=evidence / "bienvenida.png")

jefe = next(account["user"] for account in accounts if sector["id"] in account["groups"])
first = json.loads(mastercontainer_file(PASSWORDS)).get(jefe)  # never printed
if not first:
    sys.exit(f"the install kept no first password for {jefe}")
print(f"::add-mask::{first}", flush=True)
unit = next(f"Unidades/{name}" for name, roles in teams.UNITS.items() if roles)  # the jefaturas read and share it
wrong += upload(jefe, first, sector["folder"], 201)  # its first request
wrong += upload(jefe, first, unit, 403)
if wrong:
    sys.exit("\n".join(wrong))
print(f"the groups, the group folders with their permissions and the {len(accounts)} cargo accounts are what "
      f"«Equipos» declared; {STAFF}'s first upload into {sector['folder']} and {jefe}'s succeeded, and {STAFF} "
      f"sees their teams' folders, Transversal's subfolders and the welcome page")
