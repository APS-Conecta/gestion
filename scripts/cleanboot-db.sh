#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Clean boot: the database of the suite just installed is ready for Buscador Documental — the state
# scripts/db-image-test.sh proves on the image alone (#44), read here on a whole install: vector and
# unaccent, both buscador roles, and no worker privilege on any of Nextcloud's relations.
#
# The database must run the suite tag's own image first, so an image without /aps-roles.sh honestly
# means a tag older than #44: that is named in a notice and not asserted, once psql has answered.
#
# Usage: scripts/cleanboot-db.sh SUITE_TAG   one copy for both clean-boot jobs
set -uo pipefail

TAG="${1:-}"
DB=aps-conecta-database
fail=0

die() { echo "FAIL: $*" >&2; exit 1; }
sql() { docker exec "$DB" psql -X -q -tA -v ON_ERROR_STOP=1 -U nextcloud -d nextcloud_database -c "$1"; }
check() { # NAME WANT GOT
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 — expected «$2», got «$3»" >&2; fail=1; fi; }

[ -n "$TAG" ] || die "usage: $0 SUITE_TAG — the suite tag the run installed"
want="ghcr.io/aps-conecta/aio-postgresql:$TAG"
image="$(docker inspect -f '{{.Config.Image}}' "$DB")" || die "no $DB container"
[ "$image" = "$want" ] || die "$DB runs $image, not $want — the run did not install the suite tag's images"

ext="$(sql "SELECT string_agg(extname, ' ' ORDER BY extname) FROM pg_extension")" \
  || die "psql could not read nextcloud_database in $DB"
roles="$(sql "SELECT string_agg(rolname || ':' || rolcanlogin, ' ' ORDER BY rolname)
  FROM pg_roles WHERE rolname IN ('bd_owner', 'bd_worker')")" || die "psql could not read the roles in $DB"
echo "$image: extensions «$ext», buscador roles «$roles»"

if ! docker exec "$DB" test -e /aps-roles.sh; then
  echo "::notice::suite tag $TAG is older than buscador's database (#44): $want has no /aps-roles.sh, so nothing is asserted"
  exit 0
fi

# privileged relations, then all relations checked: tables, views and sequences outside the catalogs
# (db-image-test.sh's query, here over the whole of Nextcloud's schema)
priv="$(sql "SELECT count(*) FILTER (WHERE CASE WHEN c.relkind = 'S'
      THEN has_sequence_privilege('bd_worker', c.oid, 'USAGE, SELECT, UPDATE')
      ELSE has_table_privilege('bd_worker', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
        OR has_any_column_privilege('bd_worker', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES') END) || ' ' || count(*)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'")" \
  || die "psql could not read bd_worker's privileges in $DB"
read -r held total <<<"$priv"

check "vector and unaccent are installed" "unaccent vector" \
  "$(tr ' ' '\n' <<<"$ext" | grep -xE 'unaccent|vector' | paste -sd' ')"
check "bd_owner exists without login, bd_worker with login" "bd_owner:false bd_worker:true" "$roles"
check "bd_worker holds no privilege on any of the $total relations" "0" "$held"
[ "${total:-0}" -gt 0 ] || { echo "  FAIL: no relation was read — the privilege check saw nothing" >&2; fail=1; }

[ "$fail" -eq 0 ] || die "the database is not ready for buscador"
echo "the database is ready for buscador (suite tag $TAG)"
