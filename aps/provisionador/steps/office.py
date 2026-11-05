# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Office as in any Nextcloud: Nextcloud's own Office entry, its navigation icon and its document hub, lists and creates
the documents, and Euro-Office opens them by default. AIO's office switch starts Euro-Office (the components step) and
AIO's Nextcloud container installs its store connector. Beside vanilla, our Office defaults, as old gestion set them:
ODF opens and edits in Euro-Office, the editor keeps the light theme, and a document opens in a tab of its own.

The step is done once Euro-Office answers Nextcloud, by the connector's own check: Nextcloud asks Euro-Office's
document server for its version, the document server converts a file it fetches from Nextcloud, and Nextcloud fetches
the result. Each calls the other at the suite's address and verifies its certificate with its own trust: Nextcloud
with the CAs the certificates step adds, a test build's staging roots among them, and the document server's Node with
those release.yml gives it. On the APS name, AIO's network resolves the name to our Caddy (ADR 0028), a private
address, which the document server's filter refuses unless the URL comes in a request signed with AIO's JWT secret, as
the connector signs each of its own."""

import json

from steps import configure, differences, until
from suite import Unreachable

NAME = "Office con Euro-Office"
NEEDS = ("certificates",)
OFFICE = "office"  # the app of Nextcloud's own Office entry: its navigation icon and its document hub
ODF = json.dumps(dict.fromkeys(("odt", "ods", "odp"), True), separators=(",", ":"))
# The Office entry on, and the connector's settings as its admin page stores them: ODF opens (defFormats) and edits
# (editFormats) in Euro-Office beside the formats it opens by default, the editor keeps the light theme whatever the
# operating system's, and a document opens in a tab of its own (sameTab off), so the Office entry stays open behind it.
SETTINGS = {"apps": {OFFICE: {"enabled": "yes"}, "eurooffice": {
    "defFormats": ODF, "editFormats": ODF, "customizationTheme": "default-light", "sameTab": "false"}}}
WAIT = 5 * 60  # seconds: Euro-Office may still be starting once AIO reads its container running
SILENT = ("Euro-Office no responde a Nextcloud. Presione «Reintentar» en unos minutos; si vuelve a ocurrir, contacte a "
          "APS Conecta.")


def answers(nextcloud):
    """Whether Euro-Office answers Nextcloud: its connector's own check passes."""
    try:
        nextcloud.occ("eurooffice:documentserver", "--check")
    except Unreachable:
        return False
    return True


def run(context):
    context.suite.nextcloud.occ("app:enable", OFFICE)
    if wrong := configure(context.suite.nextcloud, SETTINGS):
        return wrong
    return [] if until(lambda: answers(context.suite.nextcloud), bool, WAIT) else [SILENT]


def check(context):
    return differences(context.suite.nextcloud, SETTINGS)
