#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The suite database image (aio-postgresql), proven on the image itself, run in the shape the
# wizard gives it (php/containers.json's aps-conecta-database: read-only root, the two tmpfs,
# uid 999, init, the data and dump volumes, the same environment): it boots, keeps its data
# across a stop and a start, and restores the dump its stop wrote into an empty data volume.
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
  # TCP answers only once the final server runs: initdb's and a restore's servers listen elsewhere
  for _ in $(seq 120); do
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] || die "the database container exited"
    docker exec "$NAME" pg_isready -q -h 127.0.0.1 -p 5432 && return 0
    sleep 2
  done
  die "the database did not accept connections within 240 s"
}

restart_db() { # DATA_VOLUME — stop as the wizard does (start.sh's trap writes the dump), start again
  docker stop -t 1800 "$NAME" >/dev/null || die "docker stop failed"
  docker rm "$NAME" >/dev/null || die "docker rm failed"
  start_db "$1"
}

sql() { # ROLE SQL — one statement batch over the socket, tuples only
  docker exec "$NAME" psql -X -q -tA -v ON_ERROR_STOP=1 -U "$1" -d "$DB" -c "$2"
}

# What Nextcloud leaves behind, in miniature: the table the dump's owner probe reads, owned by
# Nextcloud's user, with one row
seed_fixture() {
  sql "$NC_USER" "
    CREATE TABLE oc_appconfig (appid varchar(32) NOT NULL, configkey varchar(64) NOT NULL,
      configvalue text, PRIMARY KEY (appid, configkey));
    INSERT INTO oc_appconfig VALUES ('core', 'installed', 'yes');" >/dev/null || die "the fixture did not load"
}

nextcloud_row() { # answers «yes oc_nextcloud»: the row's value and its table's owner
  sql "$DB_SUPERUSER" "SELECT a.configvalue || ' ' || pg_get_userbyid(c.relowner)
    FROM oc_appconfig a, pg_class c
    WHERE c.oid = 'oc_appconfig'::regclass AND a.appid = 'core' AND a.configkey = 'installed'"
}

echo "db-image-test: $IMAGE"

# ── a clean boot ──
start_db "$VOL_DATA"
seed_fixture
check "clean boot: Nextcloud's row reads back, owned by its user" [ "$(nextcloud_row)" = "yes $NC_USER" ]

# ── every start after the first: the datadir is kept ──
restart_db "$VOL_DATA"
check "restart: Nextcloud's row reads back, owned by its user" [ "$(nextcloud_row)" = "yes $NC_USER" ]

# ── backup and restore through the dump: an empty datadir and the dump volume make start.sh
# restore the dump (its PG-major-upgrade path) ──
restart_db "$VOL_RESTORED"
check "restore: start.sh restored the dump" docker exec "$NAME" grep -q "Restoring the database from database dump" /mnt/data/database-import.log
docker exec "$NAME" grep -qE '^(psql:.*)?ERROR' /mnt/data/database-import.log; rc=$?
check "restore: the replay raised no error" [ "$rc" -eq 1 ]   # 1 = read and clean; 0 = an error; 2 = unread
check "restore: Nextcloud's row came back, owned by its user" [ "$(nextcloud_row)" = "yes $NC_USER" ]

echo "db-image-test: $n checks, $FAILED failed"
[ "$FAILED" -eq 0 ]
