#!/usr/bin/env bash
# scripts/db-dump.sh — a dump AIO can restore, VERIFIED before it is trusted.
#
# WHY PLAIN SQL. AIO's database container decides "there is a dump to restore" by GREPPING for the
# owner line (`Name: oc_appconfig; Type: TABLE; Schema: public; Owner:` — Containers/postgresql/
# start.sh:16); a custom-format dump has no such text and the restore silently never fires.
# pg_dump's default output is therefore not a preference here, it is the contract.
#
# WHY VERIFIED. "pg_dump exited 0" is not "restorable": the AIO path only fires when PG_VERSION is
# absent and the dump is present, and the rehearsal bets the live stack on those bytes. So the
# dump is imported into a throwaway postgres:18 (same major as the live container) and counted
# before this script says done.
#
# THE STASH IS RUNBOOK, NOT SCRIPT (docs/MIGRATION.md): /srv/backups/apsconecta/ keeps only
# top-level FILES across rotations — a directory there dies on the next sweep — and the dump must
# also reach restic. This prints the reminder; it copies nothing anywhere by itself.
set -eu

. "$(dirname -- "$0")/env.sh"

# --- the two dump-shape detectors, parameterized so --self-test can fabricate their reds --------
dump_has_aio_marker() {  # FILE — the exact string AIO's start.sh greps for
  grep -q "Name: oc_appconfig; Type: TABLE; Schema: public; Owner:" "$1"
}
dump_table_count() {  # FILE — the CREATE TABLE count, the truncation detector
  grep -c "^CREATE TABLE" "$1"
}

if [ "${1:-}" = "--self-test" ]; then
  bad=$(mktemp); good=$(mktemp); trap 'rm -f "$bad" "$good"' EXIT
  printf 'CREATE TABLE x;\n' > "$bad"                      # no marker, 1 table
  dump_has_aio_marker "$bad" && { echo "self-test: marker detector went green on a marker-less dump" >&2; exit 1; }
  [ "$(dump_table_count "$bad")" -ge 100 ] && { echo "self-test: table floor passed a 1-table dump" >&2; exit 1; }
  { echo 'Name: oc_appconfig; Type: TABLE; Schema: public; Owner: apsconecta'; for i in $(seq 150); do echo 'CREATE TABLE t;'; done; } > "$good"
  dump_has_aio_marker "$good" && dump_table_count "$good" | grep -q '^1[0-9][0-9]$' \
    || { echo "self-test: detectors failed on a well-formed dump" >&2; exit 1; }
  echo "db-dump self-test: both detectors go red on bad input, green on good"; exit 0
fi

# Flag handling precedes argument defaulting — the comuna-package.sh ordering: run with
# --self-test, $1 is consumed by the flag branch before it can land in DEST, and the two
# sibling scripts read the same for the same pattern.
DEST="${1:-database-dump.sql}"

docker compose exec -T db pg_dump -U apsconecta -d apsconecta > "$DEST"

dump_has_aio_marker "$DEST" \
  || { echo "db-dump: $DEST lacks the AIO restore marker (the oc_appconfig owner line) — is this the apsconecta schema?" >&2; exit 1; }
tables=$(dump_table_count "$DEST")
[ "$tables" -ge 100 ] || { echo "db-dump: $tables CREATE TABLE statements — looks truncated (the live schema holds 185)" >&2; exit 1; }

# --- restorability, proven not assumed ---------------------------------------------------------
scratch="apsconecta-dumpcheck-$$"
docker run -d --name "$scratch" -e POSTGRES_USER=apsconecta -e POSTGRES_PASSWORD=probe \
  postgres:18-alpine >/dev/null
trap 'docker rm -f "$scratch" >/dev/null 2>&1 || true' EXIT INT TERM
for _ in $(seq 1 30); do docker exec "$scratch" pg_isready -U apsconecta >/dev/null 2>&1 && break; sleep 1; done
# The dump's ACL section names roles a vanilla postgres carries no trace of (measured: every
# object in the live schema is owned by oc_admin, the Nextcloud DB user — not apsconecta, the
# superuser pg_dump runs as), and ON_ERROR_STOP kills the import at the first OWNER TO that
# names one. A real restore target creates the roles first — AIO's start.sh does exactly that
# before its restore — so the scratch does too. Extracted from the dump itself, never restated:
# the list self-adjusts the day a role is added, and a hand-kept literal here would be one more
# thing to forget. [a-z_]+ out of the dump's own bytes, so no quoting hazard reaches psql.
roles="$( { grep -oE 'OWNER TO [a-z_]+' "$DEST" | awk '{print $3}';
           grep -oE ' TO [a-z_]+;' "$DEST" | awk '{print $2}' | tr -d ';'; } | sort -u )"
for r in $roles; do
  docker exec "$scratch" psql -U apsconecta -d apsconecta -Atc "SELECT 1 FROM pg_roles WHERE rolname = '$r'" | grep -q 1 \
    || docker exec "$scratch" psql -U apsconecta -d apsconecta -qc "CREATE ROLE \"$r\" NOLOGIN" >/dev/null
done
err=$(mktemp)
if ! docker exec -i "$scratch" psql -U apsconecta -d apsconecta -v ON_ERROR_STOP=1 -q < "$DEST" 2> "$err"; then
  echo "db-dump: scratch restore FAILED — the dump is not restorable:" >&2; head -5 "$err" >&2; rm -f "$err"; exit 1
fi
rm -f "$err"
restored=$(docker exec "$scratch" psql -U apsconecta -d apsconecta -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
[ "$restored" -ge "$tables" ] || { echo "db-dump: scratch restored $restored tables but the dump declares $tables" >&2; exit 1; }

echo "db-dump: $DEST — $tables tables, restored clean into a scratch postgres:18"
echo "  Runbook next: cp $DEST /srv/backups/apsconecta/apsconecta-$(date +%F)-database-dump.sql"
echo "              restic backup /srv/backups/apsconecta/   (MIGRATION.md: the stash is top-level FILES,"
echo "              never a directory — the rotation deletes directories)"
