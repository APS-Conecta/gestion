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

# 6. Background jobs are scheduled, not traffic-driven (phase 06-jobs + the `cron` service).
# Both halves are checked because either alone is a silent half-fix: the mode set without the
# container means Nextcloud waits for a cron that never runs (worse than ajax — jobs stop
# entirely), and the container without the mode means it runs while Nextcloud still self-serves
# on page loads.
docker compose ps --status running --services 2>/dev/null | grep -qx cron \
  || fail "the cron container is not running — background jobs would fall back to page-load scheduling (did you 'make up'?)"
jobs_mode=$($OCC config:app:get core backgroundjobs_mode 2>/dev/null | tr -d '\r')
[ "$jobs_mode" = "cron" ] \
  || fail "backgroundjobs_mode is '${jobs_mode:-unset}', expected 'cron' — run 'make seed' (phase 06-jobs)"

# Fetch the login page ONCE — checks 7 and 9 both read it, and it is the only unauthenticated page
# that carries both the manifest link and the login form's initial state.
login_html=$(curl -s -w '\n%{http_code}' "http://localhost:${HTTP_PORT}/login" 2>/dev/null || echo $'\n000')
login_code=${login_html##*$'\n'}
login_html=${login_html%$'\n'*}
[ "$login_code" = "200" ] || fail "GET /login returned HTTP ${login_code} (expected 200)"

# 7. The login page serves OUR webmanifest, and it has not drifted from the themed one.
# Nextcloud's guest layout hardcodes image_path('core', 'manifest.json') — layout.user.php and
# layout.public.php pass the appid so theming intercepts, but layout.guest.php does not. So the
# login page advertised {"name":"Nextcloud"} to anything offering "install app". The fix is a file
# at themes/<theme>/core/img/manifest.json, which URLGenerator::imagePath() prefers over core's.
#
# It is a STATIC copy of values that live in `occ theming:config`, so the failure mode is drift,
# not absence. Compare against the app's generated manifest, which is the source of truth.
theme_man=$(curl -s "http://localhost:${HTTP_PORT}/apps/theming/manifest" 2>/dev/null)
static_man=$(curl -s "http://localhost:${HTTP_PORT}/themes/apsconecta/core/img/manifest.json" 2>/dev/null)
drift=$(printf '%s\n---SPLIT---\n%s' "$theme_man" "$static_man" | python3 -c '
import sys, json
raw = sys.stdin.read().split("\n---SPLIT---\n")
try:
    gen, static = json.loads(raw[0]), json.loads(raw[1])
except Exception as e:
    print("unreadable: %s" % e); raise SystemExit
bad = [f"{k}: themed={gen.get(k)!r} static={static.get(k)!r}"
       for k in ("name", "short_name", "theme_color", "background_color", "description")
       if gen.get(k) != static.get(k)]
print("; ".join(bad) if bad else "OK")
' 2>/dev/null)
[ "$drift" = "OK" ] \
  || fail "webmanifest drift between themes/apsconecta/core/img/manifest.json and /apps/theming/manifest: ${drift:-could not compare}"
# And confirm the guest layout actually picked ours up. imagePath() results are stored in a
# distributed cache, so on an instance whose cache was warm before the file existed this stays
# core's until the cache is flushed — the symptom looks like the fix silently not working.
printf '%s' "$login_html" | grep -q 'rel="manifest" href="[^"]*themes/apsconecta' \
  || fail "login page still links Nextcloud's manifest, not ours — if the file exists, flush the cache (docker compose exec redis redis-cli FLUSHALL)"

# 8. App policy holds: staff do not see Nextcloud's product surface (phase 16-app-policy).
# One container round-trip, not one per app — smoke runs on every `make test`.
# `enabled` is the whole state: "yes" = everyone, "no" = off, ["admin"] = admin only
# (AppManager::enableAppForGroups stores json_encode($groupIds)). So reading that one key per app
# is an exact assertion, not a proxy for one.
policy=$(docker compose exec -T --user www-data nextcloud php -r '
$want = [
  "support" => "[\"admin\"]", "updatenotification" => "[\"admin\"]", "serverinfo" => "[\"admin\"]",
  "recommendations" => "[\"admin\"]", "related_resources" => "[\"admin\"]", "weather_status" => "[\"admin\"]",
  "survey_client" => "no", "nextcloud_announcements" => "no",
];
require "/var/www/html/lib/base.php";
// \OC::$server->getConfig() was REMOVED in Nextcloud 34 — resolve through the container instead,
// or this whole check silently degrades to "could not read app config" and reports drift that
// is not there.
$c = \OC::$server->get(\OCP\IAppConfig::class);
$bad = [];
foreach ($want as $app => $exp) {
  $cur = $c->getValueString($app, "enabled", "");
  if ($cur !== $exp) { $bad[] = "$app=" . ($cur === "" ? "unset" : $cur) . " (want $exp)"; }
}
echo $bad ? implode("; ", $bad) : "OK";
' 2>/dev/null | tr -d '\r')
[ "$policy" = "OK" ] \
  || fail "app policy drift (phase 16-app-policy): ${policy:-could not read app config}"

# 9. Session posture: the login form must not offer "remember me" (phase 05-security).
# Assert the EFFECT, not the config key. `occ config:system:get` would confirm we wrote 0 while
# telling us nothing about whether the form still offers the option — and the option is the thing
# that matters. Nextcloud renders `loginCanRememberme` into the page's initial state from
# core/Controller/LoginController.php:153 (`remember_login_cookie_lifetime > 0`), so this reads
# back Nextcloud's own conclusion. Unauthenticated, so no credentials in the runner (AD-2).
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

echo "PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200, no branding leak, cron scheduling, app policy, no remember-me"
