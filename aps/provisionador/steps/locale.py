# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Spanish for everyone, with Chile's formats: core's one Spanish translation (es) whatever the browser asks for, and
the es_CL locale for dates, numbers and phone numbers. And the centre's timezone for Nextcloud's server-side clock and
its log, which are UTC otherwise; AIO's own timezone is the timezone step's."""

from steps import configure, differences

NAME = "Idioma y formato regional"
NEEDS = ("start",)


def settings(context):
    zone = context.centre["timezone"]
    return {"system": {"default_language": "es", "force_language": "es", "default_locale": "es_CL",
                       "default_phone_region": "CL", "default_timezone": zone, "logtimezone": zone}}


def run(context):
    return configure(context.suite.nextcloud, settings(context))


def check(context):
    return differences(context.suite.nextcloud, settings(context))
