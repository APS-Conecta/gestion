# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Aplicaciones», the apps step: the suite's default apps, as the Suite manifest (apps.json, beside the Provisionador)
lists them. Each own and fork app comes from its App release, at the tag the manifest pins, and only when the download's
SHA-256 checksum is the one the manifest pins: a download that does not match is refused, and nothing of it is
installed. It then goes into Nextcloud's apps folder. An app that fails is named with its reason while every other app
installs, and «Reintentar» installs them all again."""

import hashlib
import json
from pathlib import Path

from suite import Unreachable

NAME = "Aplicaciones"
NEEDS = ("start",)
MANIFEST = json.loads((Path(__file__).resolve().parents[1] / "apps.json").read_text(encoding="utf-8"))
FAILED = "«{}»: {}"  # an app's name and why it is not installed
ALTERED = ("La descarga de su versión {} no coincide con la suma de verificación que fija la suite, así que no se "
           "instaló. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS Conecta.")
DIFFERENT = ("Nextcloud no tiene activadas estas aplicaciones en la versión que fija la suite: {}. Presione "
             "«Reintentar»; si vuelve a ocurrir, contacte a APS Conecta.")


class Refused(Exception):
    """A download that is not the App release the Suite manifest pins; the message says why."""


def pinned(suite, app):
    """The app's tarball from its App release at the pinned tag, once its checksum is the pinned one."""
    tarball = suite.app_release(app["repo"], app["pin"], f"{app['id']}.tar.gz")
    if hashlib.sha256(tarball).hexdigest() != app["sha256"]:
        raise Refused(ALTERED.format(app["pin"]))
    return tarball


def install(context, apps):
    """Install each app: a store app as the app store installs it, which leaves one already installed as it is, and an
    own or fork app from its App release; the «name»: reason of each that failed."""
    reasons = []
    for app in apps:
        try:
            if app["source"] == "store":
                context.suite.nextcloud.occ("app:enable", app["id"])
            else:
                context.suite.nextcloud.install_app(app["id"], pinned(context.suite, app))
        except (Refused, Unreachable) as failure:
            reasons.append(FAILED.format(app["name"], failure))
    return reasons


def differences(context, apps):
    """Of the apps, those Nextcloud does not run enabled, an own or fork app at its pinned version, as one Spanish reason
    in a list, or none."""
    held = json.loads(context.suite.nextcloud.occ("config:list"))["apps"]
    wrong = [app["name"] for app in apps if held.get(app["id"], {}).get("enabled") != "yes"
             or "pin" in app and held[app["id"]].get("installed_version") != app["pin"].removeprefix("v")]
    return [DIFFERENT.format(", ".join(wrong))] if wrong else []


def default():
    """The default apps, in the manifest's order."""
    return [app for app in MANIFEST if not app.get("optional")]


def startup():
    """The default store apps: vanilla's startup-apps switch, which the start step gives AIO's start, installs them at
    Nextcloud's first start."""
    return [app["id"] for app in MANIFEST if app["source"] == "store" and not app.get("optional")]


def run(context):
    return install(context, default())


def check(context):
    return differences(context, default())
