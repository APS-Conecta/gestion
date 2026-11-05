# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The antivirus, vanilla's: AIO's ClamAV switch (the components step) starts ClamAV, and AIO's Nextcloud container
sets up files_antivirus at its start, in daemon mode against ClamAV, which scans every upload and deletes an infected
one; when ClamAV does not answer that start in time, it leaves the app off instead, and the step fails. Beside vanilla,
what its background scan finds infected later, such as a file that reached the files without the upload's scan, is
deleted too: the step sets its infected-file action to delete instead of vanilla's only_log, which vanilla's start sets
again at every start of Nextcloud. Its part of the end-of-install check: the app on, with that action."""

from steps import configure, differences

NAME = "Antivirus"
NEEDS = ("start",)
APP = "files_antivirus"
ON = {"apps": {APP: {"enabled": "yes"}}}
SETTINGS = {"apps": {APP: {"av_infected_action": "delete"}}}
OFF = ("El antivirus no quedó activo en Nextcloud: AIO lo desactiva cuando ClamAV no responde a tiempo al iniciarse "
       "Nextcloud. Contacte a APS Conecta.")


def off(nextcloud):
    return [OFF] if differences(nextcloud, ON) else []


def run(context):
    return off(context.suite.nextcloud) or configure(context.suite.nextcloud, SETTINGS)


def check(context):
    return off(context.suite.nextcloud) or differences(context.suite.nextcloud, SETTINGS)
