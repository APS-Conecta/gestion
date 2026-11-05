# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The groups, as old gestion made them: the staff-wide group, the four categories, the roles every establishment shares
and one per team «Equipos» declared, by the ids and names teams.py gives them. A group Nextcloud holds already stays as
it is. Its part of the end-of-install check: Nextcloud holds every one of them."""

import json

import teams

NAME = "Grupos y equipos"
NEEDS = ("start",)
MISSING = "Nextcloud no tiene estos grupos: {}. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."


def members(nextcloud):
    """Each group's members, by the group's id."""
    return json.loads(nextcloud.occ("group:list", "--output=json")) or {}


def run(context):
    held = members(context.suite.nextcloud)
    for group, name in teams.groups(context.teams, context.centre["type"]).items():
        if group not in held:
            context.suite.nextcloud.occ("group:add", f"--display-name={name}", group)
    return check(context)


def check(context):
    held = members(context.suite.nextcloud)
    missing = [name for group, name in teams.groups(context.teams, context.centre["type"]).items() if group not in held]
    return [MISSING.format(", ".join(missing))] if missing else []
