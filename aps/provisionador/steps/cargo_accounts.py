# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The cargo accounts, as old gestion made them: one per position every establishment has and a jefatura per sector, by
the usernames teams.py reserves, each in its groups. Each gets a first password, made the first time the install names
the account and kept from then on beside the Provisionador's state, readable by its account alone; an account that
exists keeps its own. The app policy turns the breached-password lookup off first, so that no password leaves the
server. Its part of the end-of-install check: each account in its groups."""

import secrets

import teams
from steps.groups import members

NAME = "Cuentas de cargo"
NEEDS = ("app_policy", "groups")
MISSING = ("Estas cuentas de cargo no existen o no están en sus grupos: {}. Presione «Reintentar»; si vuelve a "
           "ocurrir, contacte a APS Conecta.")


def first(passwords, users):
    """Each user's first password, by username: made the first time the install names the account, and kept."""
    kept = passwords.read() or {}
    if new := {user: secrets.token_hex(12) for user in users if user not in kept}:
        kept |= new
        passwords.write(kept)
    return kept


def run(context):
    nextcloud, accounts = context.suite.nextcloud, teams.cargo_accounts(context.teams, context.centre["type"])
    passwords = first(context.passwords, [account["user"] for account in accounts])
    held = members(nextcloud)
    for account in accounts:
        nextcloud.add_user(account["user"], account["name"], passwords[account["user"]])
        for group in account["groups"]:
            if account["user"] not in held.get(group, ()):
                nextcloud.occ("group:adduser", group, account["user"])
    return check(context)


def check(context):
    held = members(context.suite.nextcloud)
    missing = [account["user"] for account in teams.cargo_accounts(context.teams, context.centre["type"])
               if any(account["user"] not in held.get(group, ()) for group in account["groups"])]
    return [MISSING.format(", ".join(missing))] if missing else []
