#!/usr/bin/env bash
# Core-stack smoke — is the running APS Conecta stack healthy? (Story 0.4)
# Exits 0 on a healthy stack, non-zero (with a labeled FAIL) on a broken/absent one.
# Checks the core invariants only — the office backend has its own scripts/office-smoke.sh.
set -uo pipefail

HTTP_PORT="${HTTP_PORT:-8180}"
OCC="docker compose exec -T --user www-data nextcloud php occ"

fail() { echo "FAIL: $*"; exit 1; }

# 1. nextcloud container running (exec would hang/err on a down stack — detect first).
docker compose ps --status running --services 2>/dev/null | grep -qx nextcloud \
  || fail "nextcloud container is not running (did you 'make up'?)"

# 2. Nextcloud installed + reachable via occ.
$OCC status --output=json 2>/dev/null | grep -q '"installed":true' \
  || fail "occ status: Nextcloud not installed / not reachable"

# 3. PostgreSQL accepting connections.
docker compose exec -T db pg_isready -q 2>/dev/null \
  || fail "PostgreSQL (db) is not accepting connections"

# 4. Redis responding to PING.
[ "$(docker compose exec -T redis redis-cli ping 2>/dev/null | tr -d '\r')" = "PONG" ] \
  || fail "Redis is not responding to PING"

# 5. HTTP surface: GET /status.php → 200 (loopback).
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${HTTP_PORT}/status.php" 2>/dev/null || echo 000)
[ "$code" = "200" ] || fail "GET http://localhost:${HTTP_PORT}/status.php returned HTTP ${code} (expected 200)"

echo "PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200"
