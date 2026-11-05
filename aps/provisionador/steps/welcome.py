# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The welcome page, as old gestion seeded it: every login lands on IntraVox («Inicio», a default fork app, which the
apps step installs), whose home page names the establishment and says where its folders are. IntraVox keeps its pages
in its group folder, which the step names Intranet before IntraVox's own setup makes it, and which the groups of
teams.INTRANET get beside IntraVox's own; a page there already stays as staff left it. IntraVox reports nothing to its
makers. Its part of the end-of-install check: logins land on IntraVox, and the staff read the Intranet folder."""

import json

import teams
from steps import configure, differences
from steps.folders import grant, listed

NAME = "Página de bienvenida"
NEEDS = ("apps", "groups")
APP = "intravox"
MOUNT = "Intranet"  # IntraVox's group folder, as staff see it in Files
SETTINGS = {"system": {"defaultapp": APP}, "apps": {APP: {"groupfolder_name": MOUNT, "telemetry_enabled": "false"}}}
HOME = "page-aps-00000001-0000-4000-8000-000000000001"  # old gestion's home page
LINKS = (("Archivos", "Las carpetas del establecimiento", "/apps/files/", "folder"),
         (teams.TRANSVERSAL, "Lo que lee todo el personal", f"/apps/files/?dir=/{teams.TRANSVERSAL}",
          "folder-multiple"),
         ("Calendario", "La agenda del equipo", "/apps/calendar/", "calendar"),
         ("Contactos", "Teléfonos y correos", "/apps/contacts/", "contacts"),
         ("Talk", "Mensajes y videollamadas", "/apps/spreed/", "chat"))
UNREADABLE = ("El personal no puede leer la página de bienvenida en la carpeta {}. Presione «Reintentar»; si vuelve a "
              "ocurrir, contacte a APS Conecta.").format(MOUNT)


def row(*widgets, **style):
    return {"columns": 1, **style, "widgets": [{"column": 1, "order": n, **w} for n, w in enumerate(widgets, 1)]}


def pages(centre):
    """The home page and the menu, by their path in the Intranet folder."""
    *units, last = teams.UNITS
    folders = (f"En «Archivos» están las carpetas del establecimiento: {teams.TRANSVERSAL}, que lee todo el personal "
               "y ordenan las jefaturas; la de cada sector y cada programa, que gestionan su equipo y las jefaturas; y "
               f"la de cada unidad: {', '.join(units)} y {last}. Las jefaturas y la OIRS editan esta página en la "
               f"carpeta {MOUNT}.")
    home = {"uniqueId": HOME, "title": "Inicio", "language": "es", "layout": {"columns": 1, "sideColumns": [], "rows": [
        row({"type": "heading", "content": "Bienvenida", "level": 3},
            {"type": "heading", "content": centre["name"], "level": 1},
            {"type": "text", "content": f"{centre['comuna']} · {centre['health_service']}"},
            backgroundColor="var(--color-primary-element)"),
        row({"type": "text", "content": folders}),
        row({"type": "links", "title": "", "columns": len(LINKS), "items": [
            {"title": title, "text": text, "url": url, "icon": icon, "target": "_self"}
            for title, text, url, icon in LINKS]})]}}
    menu = {"type": "megamenu", "items": [{"id": "nav_inicio", "title": "Inicio", "uniqueId": HOME, "url": None,
                                           "target": None, "children": []}]}
    return {path: json.dumps(page, ensure_ascii=False, indent=1) + "\n"
            for path, page in (("es/home.json", home), ("es/navigation.json", menu))}


def run(context):
    nextcloud = context.suite.nextcloud
    if wrong := configure(nextcloud, SETTINGS):  # IntraVox names its folder before it makes it
        return wrong
    nextcloud.occ("intravox:setup", "--skip-demo")
    intranet = listed(nextcloud).get(MOUNT)
    if intranet is None:
        return [UNREADABLE]
    grant(nextcloud, intranet, teams.INTRANET)
    nextcloud.seed(intranet["id"], pages(context.centre))
    nextcloud.occ("intravox:reindex")
    return check(context)


def check(context):
    intranet = listed(context.suite.nextcloud).get(MOUNT)
    read = intranet is not None and all(intranet["groups"].get(group) == teams.bits(words)
                                        for group, words in teams.INTRANET.items())
    return differences(context.suite.nextcloud, SETTINGS) + ([] if read else [UNREADABLE])
