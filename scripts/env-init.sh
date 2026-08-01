#!/usr/bin/env bash
# `make setup` — create the local env file with four generated secrets (#80).
#
# WHAT THIS REPLACES. README step 2 told a human to copy the template and hand-edit four values.
# Nothing generated them, so every install started with either placeholders left in place or four
# passwords invented under time pressure. This does the invention, once, with a real CSPRNG.
#
# IT REFUSES RATHER THAN OVERWRITES. An existing env file holds secrets the running instance is
# already using: Nextcloud reads the admin password at INSTALL time only, so rewriting the file on a
# live stack does not change the login — it just makes the file disagree with the database, silently,
# which is worse than either. There is no --force. Delete the file yourself if you mean it.
#
# NO SECOND COPY. The env file is the only place these values live: no rendered sheet, no printed
# secret. CONTRIBUTING.md forbids the sheet — one was deleted 2026-07-29 after it was pasted into a
# chat transcript — and a terminal that prints a password puts it in scrollback, shell history and
# any CI log. So this prints WHERE the password is, never what it is.
set -uo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=.env
TEMPLATE=.env.example

[ -f "$TEMPLATE" ] || { echo "FATAL: no $TEMPLATE — are you in the repo root?" >&2; exit 1; }

if [ -f "$ENV_FILE" ]; then
  cat >&2 <<MSG
$ENV_FILE already exists — refusing to overwrite it.

That file holds the secrets this instance was installed with. Nextcloud reads the admin
password only when it first installs itself, so replacing it now would not change any
login — it would just make the file disagree with the database.

  To read a value:   grep '^NEXTCLOUD_ADMIN_PASSWORD=' $ENV_FILE
  To start over:     rm $ENV_FILE   (destroys the only copy of these secrets)
MSG
  exit 1
fi

# HEX, NEVER BASE64. Compose interpolates \$ in env values and scripts/env.sh undoes a \$\$ escape,
# so a value containing \$ breaks the file outright (B-004). Hex has no character that either layer
# treats as syntax, which makes these safe BY CONSTRUCTION rather than by quoting them correctly.
#
# /dev/urandom rather than openssl: the install host is assumed to have python3, bash, git and
# docker (#77) — openssl is on most machines and guaranteed on none, and this needs no cipher, only
# bytes. 32 bytes = 64 hex chars, which also satisfies OFFICE_JWT_SECRET's documented >=32.
# `od` reads exactly N bytes and stops, rather than streaming until `head` slams the pipe shut —
# which made tr print "write error: Broken pipe" four times on the first command an operator runs.
# The value was always correct; it just looked like a failure. Argument is BYTES, output is 2N hex.
secret() { od -An -tx1 -N"${1:-32}" /dev/urandom | LC_ALL=C tr -d ' \n'; }

# Replace a key's VALUE and nothing else: the template's comments explain what each key is for and
# are worth keeping. Anchored to the line start so a key named inside a comment is untouched.
set_key() {  # KEY VALUE
  local k="$1" v="$2"
  grep -qE "^${k}=" "$ENV_FILE" || { echo "FATAL: $TEMPLATE has no ${k}= line" >&2; return 1; }
  # `|` as the delimiter and a hex-only value: no escaping needed, and none attempted.
  sed -i "s|^${k}=.*|${k}=${v}|" "$ENV_FILE"
}

cp "$TEMPLATE" "$ENV_FILE"
# 600 BEFORE anything is written into it. On a shared clinic PC the default (usually 644) means any
# account on that machine can read the admin password. This is not encryption — your own account
# still reads it, and it must stay plain text because compose reads it at boot with nobody present
# to type a passphrase — but it is the difference between "in a file" and "in a file anyone can open".
chmod 600 "$ENV_FILE"

set_key NEXTCLOUD_ADMIN_PASSWORD "$(secret 16)" || exit 1
set_key POSTGRES_PASSWORD        "$(secret 16)" || exit 1
set_key OFFICE_JWT_SECRET        "$(secret 32)" || exit 1
set_key FIXTURE_USER_PASSWORD    "$(secret 12)" || exit 1

echo "✓ $ENV_FILE created, four secrets generated, mode 600"
echo
echo "  Your admin password is in that file and nowhere else:"
echo "      grep '^NEXTCLOUD_ADMIN_PASSWORD=' $ENV_FILE"
echo "  Copy it into your password manager now — nothing else here keeps a copy."
echo
# SITE is the one value no generator can invent, and leaving it unset is what `make install`
# already refuses on. Naming the next step here beats letting the install stop and explain it.
if grep -qE '^SITE=.+' "$ENV_FILE"; then
  echo "  SITE is already set. Next:  make install"
else
  echo "  Still needed — which clinic this serves. Either:"
  echo "      echo 'SITE=los-castanos' >> $ENV_FILE     # the reference clinic that ships"
  echo "      scripts/deis.py cesfam <comuna>           # or pick another from the register"
  echo "  Then:  make install"
fi
