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

# 6. Session posture: the login form must not offer "remember me" (phase 05-security).
# Assert the EFFECT, not the config key. `occ config:system:get` would confirm we wrote 0 while
# telling us nothing about whether the form still offers the option — and the option is the thing
# that matters. Nextcloud renders `loginCanRememberme` into the page's initial state from
# core/Controller/LoginController.php:153 (`remember_login_cookie_lifetime > 0`), so this reads
# back Nextcloud's own conclusion. Unauthenticated, so no credentials in the runner (AD-2).
login_html=$(curl -s -w '\n%{http_code}' "http://localhost:${HTTP_PORT}/login" 2>/dev/null || echo $'\n000')
login_code=${login_html##*$'\n'}
login_html=${login_html%$'\n'*}
[ "$login_code" = "200" ] || fail "GET /login returned HTTP ${login_code} (expected 200)"
remember=$(printf '%s' "$login_html" | python3 -c '
import sys, re, base64, html
h = sys.stdin.read()
m = re.search(r"id=\"initial-state-core-loginCanRememberme\"[^>]*value=\"([^\"]*)\"", h)
if not m:
    print("ABSENT"); raise SystemExit
try:
    print(base64.b64decode(html.unescape(m.group(1))).decode().strip())
except Exception:
    print("UNDECODABLE")
' 2>/dev/null)
case "$remember" in
  false) : ;;
  true)  fail "session posture: the login form still offers 'remember me' — is 'remember_login_cookie_lifetime' 0? (phase 05-security)" ;;
  *)     fail "session posture: could not read loginCanRememberme from /login (got '${remember}') — upstream may have renamed the initial state key" ;;
esac

echo "PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200, no branding leak, no remember-me"
