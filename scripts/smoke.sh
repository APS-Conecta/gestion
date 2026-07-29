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

# 5. HTTP surface: GET /status.php → 200 (loopback), and the body carries OUR product name.
# We already fetch this body, so grepping it is nearly free — and /status.php is the single
# highest-value branding regression: it is unauthenticated, and if `theming productName` is
# ever unset the response says "Nextcloud" to anyone who asks. Same string also leaks through
# OC.theme, the OCS capabilities and the public-share button, so this one grep covers the family.
body=$(curl -s -w '\n%{http_code}' "http://localhost:${HTTP_PORT}/status.php" 2>/dev/null || echo $'\n000')
code=${body##*$'\n'}
body=${body%$'\n'*}
[ "$code" = "200" ] || fail "GET http://localhost:${HTTP_PORT}/status.php returned HTTP ${code} (expected 200)"
if printf '%s' "$body" | grep -qi 'nextcloud'; then
  fail "branding leak: /status.php still says Nextcloud — is 'occ config:app:set theming productName' set? Body: ${body}"
fi

echo "PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200, no branding leak"
