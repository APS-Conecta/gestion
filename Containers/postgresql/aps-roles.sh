#!/bin/bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Buscador Documental's database prerequisites, idempotent: a second run changes nothing.
# - bd_owner (no login) owns buscador's schema; Nextcloud's user may SET ROLE to it, never inherit it.
# - bd_worker (login) is the worker's role: it may connect, and is granted nothing on any table.
#   Of its bounds only the connection limit and the temp-file limit bind a compromised worker;
#   the two timeouts are defaults it can lift itself.
# - unaccent and vector live in public: buscador calls public.unaccent. unaccent is a trusted
#   extension; only vector needs the superuser to be created.
# start.sh runs it at every start and, on a restore, before the dump is replayed (the dump
# carries no roles). It connects as the superuser over the local socket and honours PGPORT.

if [ "$AIO_LOG_LEVEL" = 'debug' ]; then
    set -x
fi

psql -X -q -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v "nc_user=oc_$POSTGRES_USER" -v "db=$POSTGRES_DB" <<'EOSQL'
SET client_min_messages = warning;
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bd_owner') AS missing \gset
\if :missing
    CREATE ROLE bd_owner;
\endif
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bd_worker') AS missing \gset
\if :missing
    CREATE ROLE bd_worker;
\endif
ALTER ROLE bd_owner NOLOGIN;
ALTER ROLE bd_worker LOGIN CONNECTION LIMIT 20;
ALTER ROLE bd_worker SET statement_timeout = '10min';
ALTER ROLE bd_worker SET temp_file_limit = '2GB';
ALTER ROLE bd_worker SET idle_in_transaction_session_timeout = '5min';
GRANT CONNECT ON DATABASE :"db" TO bd_worker;
GRANT bd_owner TO :"nc_user" WITH INHERIT FALSE, SET TRUE;
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;
-- A new suite release can ship a newer pgvector on the same postgres: an existing data volume
-- keeps the version it was created with — CREATE IF NOT EXISTS touches nothing — until someone
-- walks pgvector's update scripts (#74). UPDATE walks them and keeps the data; at the image's
-- version it is a no-op, so the second-run contract holds. (A rollback onto an older image
-- finds no update path and fails this script — start.sh logs it and keeps the database running.)
ALTER EXTENSION vector UPDATE;
EOSQL
