#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The suite database image (aio-postgresql) is ready for Buscador Documental — proven on the image
# itself, run in the shape the wizard gives it (php/containers.json's aps-conecta-database:
# read-only root, the two tmpfs, uid 999, init, the data and dump volumes, the same environment).
#
# Usage: scripts/db-image-test.sh [IMAGE]   no IMAGE: builds Containers/postgresql first
# Needs docker. Its container and volumes are removed on exit. Every wait is bounded; a timeout
# prints the container's logs and fails.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-}"
NAME="aps-db-test-$$"
VOL_DATA="aps_db_test_data_$$"
VOL_RESTORED="aps_db_test_restored_$$"
VOL_DUMP="aps_db_test_dump_$$"
DB=nextcloud_database
DB_SUPERUSER=nextcloud # POSTGRES_USER: the cluster superuser
NC_USER=oc_nextcloud   # the Nextcloud user init-user-db.sh creates
n=0; FAILED=0

die() { echo "FATAL: $*" >&2; docker logs --tail 60 "$NAME" >&2 2>/dev/null; exit 1; }
check() { local name="$1"; shift; n=$((n + 1)) # NAME CMD... — a red check is counted, never fatal
  if "$@"; then echo "  ok: $name"; else echo "  FAIL: $name — $*" >&2; FAILED=$((FAILED + 1)); fi; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker volume rm "$VOL_DATA" "$VOL_RESTORED" "$VOL_DUMP" >/dev/null 2>&1
}
trap cleanup EXIT

if [ -z "$IMAGE" ]; then
  IMAGE="aps-conecta-db-test:local"
  docker build -q -t "$IMAGE" "$REPO_ROOT/Containers/postgresql" >/dev/null || die "the image did not build"
fi

start_db() { # DATA_VOLUME — create and start the container the way the wizard does
  docker run -d --name "$NAME" --init --user 999 --read-only \
    --tmpfs /var/lib/postgresql --tmpfs /var/run/postgresql \
    --shm-size 268435456 --cap-drop NET_RAW \
    --volume "$1:/var/lib/postgresql/data" --volume "$VOL_DUMP:/mnt/data" \
    --env POSTGRES_PASSWORD=db-image-test --env POSTGRES_DB="$DB" --env POSTGRES_USER="$DB_SUPERUSER" \
    --env AIO_LOG_LEVEL=warn --env TZ=America/Santiago --env PGTZ=America/Santiago \
    "$IMAGE" >/dev/null || die "docker run failed"
  local i
  for i in $(seq 120); do
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] || die "the database container exited"
    docker exec "$NAME" pg_isready -q -h 127.0.0.1 -p 5432 && break
    [ "$i" -lt 120 ] || die "the database did not accept connections within 240 s"
    sleep 2
  done
  # start.sh's every-start run of aps-roles.sh ends in one line; nothing is asserted before it
  for i in $(seq 60); do
    case "$(docker logs "$NAME" 2>&1)" in
      *"aps-roles: ok"*) return 0 ;;
      *"aps-roles: FAILED"*) die "start.sh's aps-roles run failed" ;;
    esac
    sleep 2
  done
  die "start.sh printed no aps-roles line within 120 s"
}

restart_db() { # DATA_VOLUME — stop as the wizard does (start.sh's trap writes the dump), start again
  docker stop -t 1800 "$NAME" >/dev/null || die "docker stop failed"
  docker rm "$NAME" >/dev/null || die "docker rm failed"
  start_db "$1"
}

sql() { # ROLE SQL — one statement batch over the socket, tuples only
  docker exec "$NAME" psql -X -q -tA -v ON_ERROR_STOP=1 -U "$1" -d "$DB" -c "$2"
}

# What Nextcloud and buscador's migration leave behind, in miniature: a Nextcloud table (the dump's
# owner probe reads oc_appconfig) and buscador's schema, owned by bd_owner, with an unaccented
# text-search column and a vector column. The worker is granted the schema, as buscador does, and
# nothing on the tables.
seed_fixture() {
  sql "$NC_USER" "
    CREATE TABLE oc_appconfig (appid varchar(32) NOT NULL, configkey varchar(64) NOT NULL,
      configvalue text, PRIMARY KEY (appid, configkey));
    INSERT INTO oc_appconfig VALUES ('core', 'installed', 'yes');
    CREATE SCHEMA aps_search AUTHORIZATION bd_owner;
    SET ROLE bd_owner;
    CREATE TEXT SEARCH CONFIGURATION aps_search.spanish_unaccent (COPY = pg_catalog.spanish);
    ALTER TEXT SEARCH CONFIGURATION aps_search.spanish_unaccent
      ALTER MAPPING FOR hword, hword_part, word WITH public.unaccent, pg_catalog.spanish_stem;
    CREATE TABLE aps_search.chunk (chunk_id bigint PRIMARY KEY, text text NOT NULL,
      tsv tsvector GENERATED ALWAYS AS (to_tsvector('aps_search.spanish_unaccent'::regconfig, text)) STORED,
      vec public.halfvec(3) NOT NULL);
    INSERT INTO aps_search.chunk (chunk_id, text, vec) VALUES (1, 'Campaña de vacunación', '[1,0,0]');
    GRANT USAGE ON SCHEMA aps_search TO bd_worker;" >/dev/null || die "the fixture did not load"
}

ready_for_buscador() { # LABEL — the state the ticket asks for, after any boot
  local ext roles via_owner priv schema
  ext="$(docker exec "$NAME" psql -X -tA -U "$DB_SUPERUSER" -d "$DB" -c '\dx' | cut -d'|' -f1 | sort | xargs)"
  roles="$(sql "$DB_SUPERUSER" "SELECT string_agg(rolname || ':' || rolcanlogin, ' ' ORDER BY rolname)
    FROM pg_roles WHERE rolname IN ('bd_owner', 'bd_worker')")"
  # CONNECT is asserted as bd_worker's own grant: PUBLIC's default CONNECT would answer for any role
  via_owner="$(sql "$NC_USER" "SET ROLE bd_owner; SELECT current_user || ' ' || EXISTS (SELECT 1
    FROM pg_database d, aclexplode(d.datacl) a WHERE d.datname = current_database()
      AND a.grantee = 'bd_worker'::regrole AND a.privilege_type = 'CONNECT')")"
  # privileged relations, then all relations checked: tables, views and sequences outside the catalogs
  priv="$(sql "$DB_SUPERUSER" "SELECT count(*) FILTER (WHERE CASE WHEN c.relkind = 'S'
        THEN has_sequence_privilege('bd_worker', c.oid, 'USAGE, SELECT, UPDATE')
        ELSE has_table_privilege('bd_worker', c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
          OR has_any_column_privilege('bd_worker', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES') END) || ' ' || count(*)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'")"
  schema="$(sql "$DB_SUPERUSER" "SELECT pg_get_userbyid(nspowner)
      || ' ' || (SELECT count(*) FROM aps_search.chunk WHERE vec::text = '[1,0,0]'
                   AND tsv @@ to_tsquery('aps_search.spanish_unaccent', 'vacunacion'))
      || ' ' || has_schema_privilege('bd_worker', 'aps_search', 'USAGE')
    FROM pg_namespace WHERE nspname = 'aps_search'")"
  check "$1: \\dx lists vector and unaccent" [ "$ext" = "plpgsql unaccent vector" ]
  check "$1: the roles bd_owner (no login) and bd_worker (login) exist" [ "$roles" = "bd_owner:false bd_worker:true" ]
  check "$1: Nextcloud's user can SET ROLE bd_owner, and bd_worker may connect" [ "$via_owner" = "bd_owner true" ]
  check "$1: bd_worker holds no privilege on any of the 2 tables" [ "$priv" = "0 2" ]
  check "$1: aps_search is bd_owner's, its row matches unaccented, the worker keeps the schema" [ "$schema" = "bd_owner 1 true" ]
}

snapshot() { # everything aps-roles.sh can touch, in a fixed order
  docker exec -i "$NAME" psql -X -q -tA -v ON_ERROR_STOP=1 -U "$DB_SUPERUSER" -d "$DB" <<'SQL'
SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication,
  rolbypassrls, rolconnlimit, rolvaliduntil, md5(coalesce(rolpassword, ''))
  FROM pg_authid WHERE rolname IN ('bd_owner', 'bd_worker') ORDER BY 1;
SELECT r.rolname, m.rolname, g.rolname, a.admin_option, a.inherit_option, a.set_option
  FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member
  JOIN pg_roles g ON g.oid = a.grantor ORDER BY 1, 2, 3;
SELECT coalesce(d.datname, '*'), coalesce(r.rolname, '*'), s.setconfig::text FROM pg_db_role_setting s
  LEFT JOIN pg_database d ON d.oid = s.setdatabase LEFT JOIN pg_roles r ON r.oid = s.setrole ORDER BY 1, 2;
SELECT e.extname, e.extversion, n.nspname, pg_get_userbyid(e.extowner)
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY 1;
SELECT datname, datacl::text FROM pg_database ORDER BY 1;
SELECT nspname, pg_get_userbyid(nspowner), nspacl::text FROM pg_namespace
  WHERE nspname IN ('public', 'aps_search') ORDER BY 1;
SQL
}

echo "db-image-test: $IMAGE"

# ── a clean boot ──
start_db "$VOL_DATA"
seed_fixture
ready_for_buscador "clean boot"

# ── the script twice: start.sh ran it once; a second run changes nothing ──
before="$(snapshot)" || die "the catalog snapshot failed"
docker exec "$NAME" /aps-roles.sh; rc=$?
after="$(snapshot)" || die "the catalog snapshot failed"
check "a second run exits 0" [ "$rc" -eq 0 ]
check "a second run changes nothing (roles, memberships, settings, extensions, ACLs)" [ "$before" = "$after" ]

# ── every start: drift in everything the script owns is repaired by the next start. The datadir
# is kept, which is also what a borg restore of the database volume gives back. ──
sql "$DB_SUPERUSER" "REVOKE bd_owner FROM $NC_USER;
  REVOKE CONNECT ON DATABASE $DB FROM bd_worker;
  ALTER ROLE bd_worker NOLOGIN CONNECTION LIMIT -1;
  ALTER ROLE bd_worker RESET ALL;
  ALTER ROLE bd_owner LOGIN;" >/dev/null || die "the drift did not apply"
restart_db "$VOL_DATA"
ready_for_buscador "restart"
check "restart: the catalog is back to the state before the drift" [ "$(snapshot)" = "$before" ]

# ── backup and restore through the dump: an empty datadir and the dump volume make start.sh
# import the dump (its PG-major-upgrade path); the roles must exist before the replay ──
restart_db "$VOL_RESTORED"
check "restore: start.sh imported the dump" docker exec "$NAME" grep -q "Restoring the database from database dump" /mnt/data/database-import.log
docker exec "$NAME" grep -qE '^(psql:.*)?ERROR' /mnt/data/database-import.log; rc=$?
check "restore: the replay raised no error" [ "$rc" -eq 1 ]   # 1 = read and clean; 0 = an error; 2 = unread
ready_for_buscador "restore"
check "restore: the catalog matches the backed-up one" [ "$(snapshot)" = "$before" ]

echo "db-image-test: $n checks, $FAILED failed"
[ "$FAILED" -eq 0 ]
