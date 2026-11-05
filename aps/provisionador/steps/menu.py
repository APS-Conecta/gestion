# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Menú personalizado», the custom menu: side_menu, the Custom Menu store app the Suite manifest lists among the
default apps, in the brand token file's dark violet, as old gestion set it; the theme shows the header logo in its
panel. The step installs the app itself, as the apps step does, so no other app's failure holds it back, and without
the app it fails naming it. Its part of the end-of-install check: the app on, in that violet."""

from steps import apps, configure, differences, token

NAME = "Menú personalizado"
NEEDS = ("start",)


def side_menu():
    return [app for app in apps.default() if app["id"] == "side_menu"]


def settings():
    violet = token("--aps-violet-dark")
    return {"apps": {"side_menu": {"background-color": violet, "background-color-to": violet}}}


def run(context):
    return apps.install(context, side_menu()) or configure(context.suite.nextcloud, settings())


def check(context):
    return apps.differences(context, side_menu()) + differences(context.suite.nextcloud, settings())
