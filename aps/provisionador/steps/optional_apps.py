# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Aplicaciones opcionales», an optional step: the optional apps of the Suite manifest that the operator ticked at
«Revisar», off by default, installed as the apps step installs an own app: from its App release, at the tag and
checksum the manifest pins. Its part of the end-of-install check: each of them enabled at its pinned version."""

from steps import apps

NAME = "Aplicaciones opcionales"
NEEDS = ("start",)
OPTIONAL = True


def chosen(context):
    return [app for app in apps.MANIFEST if app.get("optional") and app["id"] in context.optional]


def run(context):
    return apps.install(context, chosen(context))


def check(context):
    return apps.differences(context, chosen(context))
