# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Which apps staff see, as old gestion's app policy decided it: the administrator keeps every app, and every other
account gets the reduced set. Nextcloud's admin tooling and the panels that only make noise for staff are enabled for
the admin group alone; the first-run tour, the usage survey and the breached-password lookup are off by their own
switches; the usage survey, which reports to Nextcloud whoever sees it, and Nextcloud's announcements, which cannot be
restricted to a group, are disabled. The support app stays as AIO enables it at each start: it shows only to the
administrator. Its part of the end-of-install check: Nextcloud keeps the policy."""

import json

from steps import configure, differences

NAME = "Aplicaciones del personal"
NEEDS = ("start",)
ADMIN = '["admin"]'  # an app enabled for the admin group alone, as Nextcloud keeps it
# Admin tooling, and noise for staff: update notices for an image the suite pins, server monitoring, recommended
# files, the related-items panel, and the weather status, which calls an external weather service.
ADMIN_ONLY = ("updatenotification", "serverinfo", "recommendations", "related_resources", "weather_status")
# The switches: no first-run tour, which is Nextcloud's own voice; the survey's own kill switch, which its monthly job
# reads and so must be set while the survey is still enabled; no lookup of new passwords at an external breach service,
# so that no password leaves the server, not even as a prefix of its hash.
SWITCHES = {"apps": {"firstrunwizard": {"wizard_enabled": "false"}, "survey_client": {"never_again": "true"},
                     "password_policy": {"enforceHaveIBeenPwned": "0"}}}
DISABLED = ("survey_client", "nextcloud_announcements")
POLICY = {"apps": {**SWITCHES["apps"], **{app: {"enabled": ADMIN} for app in ADMIN_ONLY},
                   **{app: {**SWITCHES["apps"].get(app, {}), "enabled": "no"} for app in DISABLED}}}


def run(context):
    nextcloud = context.suite.nextcloud
    held = json.loads(nextcloud.occ("config:list"))["apps"]
    for app in ADMIN_ONLY:
        if held.get(app, {}).get("enabled") != ADMIN:
            nextcloud.occ("app:enable", "--groups=admin", app)
    if wrong := configure(nextcloud, SWITCHES):
        return wrong
    for app in DISABLED:
        if held.get(app, {}).get("enabled") != "no":
            nextcloud.occ("app:disable", app)
    return check(context)


def check(context):
    return differences(context.suite.nextcloud, POLICY)
