# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The team folders, as old gestion made them: Transversal with its subfolders, one group folder per unit and one per
team, each with the permissions teams.py declares for its groups and none for any other group, in Groupfolders, a
default store app the step enables. A team folder's mount point nests it under Sectores or Programas, where a first
upload works because the upload guard (files_upload_guard, a default own app) initialises the missing parent. Its part
of the end-of-install check: every folder there, with exactly the declared permissions."""

import json

import teams

NAME = "Carpetas de equipo y permisos"
NEEDS = ("groups",)
MISSING = "Faltan estas carpetas de equipo: {}. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta."
WRONG = ("Estas carpetas de equipo no tienen los permisos declarados: {}. Presione «Reintentar»; si vuelve a ocurrir, "
         "contacte a APS Conecta.")


def listed(nextcloud):
    """Each group folder by its mount point: its id and each group's permissions."""
    found = json.loads(nextcloud.occ("groupfolders:list", "--output=json"))
    return {f["mountPoint"]: {"id": f["id"], "groups": f.get("groups_list") or {}}
            for f in (found.values() if isinstance(found, dict) else found)}


def grant(nextcloud, folder, declared):
    """Give each declared group its permissions in the folder, where it holds others."""
    for group, words in declared.items():
        if folder["groups"].get(group) != teams.bits(words):
            nextcloud.occ("groupfolders:group", str(folder["id"]), group, *words)


def run(context):
    nextcloud = context.suite.nextcloud
    nextcloud.occ("app:enable", "groupfolders")
    held = listed(nextcloud)
    for mount, declared in teams.folders(context.teams).items():
        if mount not in held:
            held[mount] = {"id": int(nextcloud.occ("groupfolders:create", mount)), "groups": {}}
        grant(nextcloud, held[mount], declared)
        for group in held[mount]["groups"].keys() - declared.keys():
            nextcloud.occ("groupfolders:group", str(held[mount]["id"]), group, "--delete")
    nextcloud.seed(held[teams.TRANSVERSAL]["id"], dict.fromkeys(teams.SUBFOLDERS))
    return check(context)


def check(context):
    held, declared = listed(context.suite.nextcloud), teams.folders(context.teams)
    missing = [mount for mount in declared if mount not in held]
    wrong = [mount for mount, grants in declared.items() if mount in held
             and held[mount]["groups"] != {group: teams.bits(words) for group, words in grants.items()}]
    return [reason.format(", ".join(mounts)) for reason, mounts in ((MISSING, missing), (WRONG, wrong)) if mounts]
