# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The centre's timezone as AIO's own setting, which AIO gives every container of the suite."""

NAME = "Zona horaria"
NEEDS = ()


def run(context):
    context.suite.timezone(context.centre["timezone"])
