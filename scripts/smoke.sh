#!/usr/bin/env bash
# Core-stack smoke — is the running APS Conecta stack healthy? (Story 0.4)
# Exits 0 on a healthy stack, non-zero (with a labeled FAIL) on a broken/absent one.
# Checks the core invariants only — the office backend has its own scripts/office-smoke.sh.
set -uo pipefail

# cd to the repo root + load .env, so `bash scripts/smoke.sh` and `make smoke` behave identically
# from any cwd. See scripts/env.sh for why .env is parsed rather than sourced.
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

HTTP_PORT="${HTTP_PORT:-8180}"

fail() { echo "FAIL: $*"; exit 1; }

# 1. nextcloud container running (exec would hang/err on a down stack — detect first).
docker compose ps --status running --services 2>/dev/null | grep -qx nextcloud \
  || fail "nextcloud container is not running (did you 'make up'?)"

# 2. Nextcloud installed + reachable via occ.
occ status --output=json 2>/dev/null | grep -q '"installed":true' \
  || fail "occ status: Nextcloud not installed / not reachable"

# 3. PostgreSQL accepting connections.
docker compose exec -T db pg_isready -q 2>/dev/null \
  || fail "PostgreSQL (db) is not accepting connections"

# 4. Redis responding to PING.
[ "$(docker compose exec -T redis redis-cli ping 2>/dev/null | tr -d '\r')" = "PONG" ] \
  || fail "Redis is not responding to PING"

# 5. HTTP surface: GET /status.php → 200, and the body carries OUR product name. The highest-value
# branding regression there is: unauthenticated, and if `theming productName` is unset it says
# "Nextcloud" to anyone who asks. The same string leaks through OC.theme, the OCS capabilities and
# the public-share button, so this one grep covers the family.
body=$(curl -s -w '\n%{http_code}' "http://localhost:${HTTP_PORT}/status.php" 2>/dev/null || echo $'\n000')
code=${body##*$'\n'}
body=${body%$'\n'*}
[ "$code" = "200" ] || fail "GET http://localhost:${HTTP_PORT}/status.php returned HTTP ${code} (expected 200)"
if printf '%s' "$body" | grep -qi 'nextcloud'; then
  fail "branding leak: /status.php still says Nextcloud — is 'occ config:app:set theming productName' set? Body: ${body}"
fi

# 6. Background jobs are scheduled, not traffic-driven (phase 06-jobs + the `cron` service). Both
# halves, because either alone is a silent half-fix: the mode without the container means Nextcloud
# waits for a cron that never runs (worse than ajax), the container without the mode means it runs
# while Nextcloud still self-serves on page loads.
docker compose ps --status running --services 2>/dev/null | grep -qx cron \
  || fail "the cron container is not running — background jobs would fall back to page-load scheduling (did you 'make up'?)"
jobs_mode=$(occ config:app:get core backgroundjobs_mode 2>/dev/null | tr -d '\r')
[ "$jobs_mode" = "cron" ] \
  || fail "backgroundjobs_mode is '${jobs_mode:-unset}', expected 'cron' — run 'make seed' (phase 06-jobs)"

# Fetch the login page ONCE — checks 7 and 9 both read it, and it is the only unauthenticated page
# that carries both the manifest link and the login form's initial state.
login_html=$(curl -s -w '\n%{http_code}' "http://localhost:${HTTP_PORT}/login" 2>/dev/null || echo $'\n000')
login_code=${login_html##*$'\n'}
login_html=${login_html%$'\n'*}
[ "$login_code" = "200" ] || fail "GET /login returned HTTP ${login_code} (expected 200)"

# 7. The login page serves OUR webmanifest, and it has not drifted. layout.guest.php hardcodes
# image_path('core', 'manifest.json') without the appid, so theming cannot intercept and the login
# page advertised {"name":"Nextcloud"} to anything offering "install app". The fix is a static file
# at themes/<theme>/core/img/manifest.json, which URLGenerator::imagePath() prefers over core's —
# and being static, its failure mode is DRIFT from `occ theming:config`, not absence. So compare
# against the app's generated manifest, which is the source of truth.
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
# The three icon links are the same static-file mechanism as the manifest and share its failure mode
# (ADR-0004). They are here rather than beside it because they cost nothing extra — this HTML is
# already fetched — and because imagePath() caches under a key holding NO cachebuster and NO theme,
# so adding a file to the theme is invisible until the cache is flushed. Without this the icons are
# silently Nextcloud's and the tab shows the vendor's mark on every screen.
for rel in icon apple-touch-icon mask-icon; do
  printf '%s' "$login_html" | grep -q "rel=\"${rel}\"[^>]*href=\"[^\"]*themes/apsconecta" \
    || fail "login page links Nextcloud's ${rel}, not ours — if themes/apsconecta/core/img/ has the file, flush the cache (docker compose exec redis redis-cli FLUSHALL)"
done

# 8. App policy holds: staff do not see Nextcloud's product surface (phase 16-app-policy).
# `enabled` is the whole state — "yes" = everyone, "no" = off, ["admin"] = admin only — so reading
# that one key per app is an exact assertion, not a proxy. One round-trip for all of them, because
# smoke runs on every `make test`, and through `occ config:list` rather than a PHP script that
# boots the server: \OC::$server->getConfig() was REMOVED in NC34 and degrades silently.
# The inventory is read from provisioning/app-policy.sh, the same declaration phase 16 applies —
# it used to be typed out again here, which is two lists that must silently agree.
. provisioning/app-policy.sh
policy=$(occ config:list --output=json 2>/dev/null | POLICY_ADMIN_ONLY="${POLICY_ADMIN_ONLY:-}" \
  POLICY_DISABLED="${POLICY_DISABLED:-}" POLICY_CONFIG="${POLICY_CONFIG:-}" python3 -c '
import sys, json, os
# "disabled" is TWO valid values, not one: the literal "no" (was enabled, then disabled) and an
# ABSENT key (never enabled here). `occ app:disable` on an already-absent key is a no-op and does
# not write "no", so demanding the literal would fail forever on a fresh instance. Measured
# 2026-07-29 by deleting the key and re-seeding. Restricted apps have exactly one valid value.
ADMIN_ONLY = "[\"admin\"]"
UNSET = "unset"
admin_only = os.environ["POLICY_ADMIN_ONLY"].split()
disabled = os.environ["POLICY_DISABLED"].split()
config = os.environ["POLICY_CONFIG"].split()

# Reading the policy from a file means the file can fail to arrive, and an EMPTY want-set satisfies
# every assertion below — the check would print OK while asserting nothing at all. That is the one
# failure this shape adds over the hand-typed copy it replaces, so it is refused first.
if not admin_only or not disabled or not config:
    print("app-policy.sh declared nothing — POLICY_ADMIN_ONLY/DISABLED/CONFIG empty or unsourced")
    raise SystemExit

want = {a: [ADMIN_ONLY] for a in admin_only}
want.update({a: ["no", ""] for a in disabled})

apps = json.load(sys.stdin)["apps"]
bad = []
for app, accepted in want.items():
    cur = apps.get(app, {}).get("enabled", "")
    if cur not in accepted:
        shown = " or ".join(v or UNSET for v in accepted)
        bad.append(f"{app}={cur or UNSET} (want {shown})")
# The config switches are policy too, and the only lever with no visible effect on `enabled`:
# firstrunwizard stays enabled by design, so nothing above would notice its tour coming back on.
for entry in config:
    app, key, val = entry.split(":", 2)
    cur = apps.get(app, {}).get(key, "")
    if cur != val:
        bad.append(f"{app}.{key}={cur or UNSET} (want {val})")
print("; ".join(bad) if bad else "OK")
' 2>/dev/null | tr -d '\r')
[ "$policy" = "OK" ] \
  || fail "app policy drift (phase 16-app-policy): ${policy:-could not read app config}"

# 9. Session posture: the login form must not offer "remember me" (phase 05-security). Assert the
# EFFECT, not the key — `config:system:get` would confirm we wrote 0 while saying nothing about
# whether the form still offers the option, which is the thing that matters. `loginCanRememberme`
# is Nextcloud's own conclusion from that key. Unauthenticated, so no credentials in the runner.
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

# 10. No patched app still carries its vendor signature (#71, phase 12-apps). What it costs when one
# does, and why an `occ app:update` from the UI puts it back: docs/adr/0002-app-patches.md § Code
# integrity. PATCHED means "has a .patch file", NOT "has a directory under provisioning/apps/" —
# since #98 every app has a directory, and reading it as "patched" fails the two whose untouched
# upstream signature is correct. The list comes from provisioning/apps/, so a new patched app is
# covered automatically.
patched=$(find provisioning/apps -mindepth 2 -maxdepth 2 -name '*.patch' -printf '%h\n' 2>/dev/null \
          | sort -u | xargs -r -n1 basename | tr '\n' ' ')
if [ -n "$patched" ]; then
  signed=$(docker compose exec -T --user www-data nextcloud sh -c \
    "for a in $patched; do [ -e \"custom_apps/\$a/appinfo/signature.json\" ] && echo \"\$a\"; done; :" \
    2>/dev/null | tr -d '\r' | tr '\n' ' ')
  [ -z "${signed// /}" ] \
    || fail "patched app(s) still signed: ${signed}— the code-integrity check will fail and admin > Overview will show a red warning. Run 'make seed' (phase 12-apps drops it), then click 'Rescan…' in that warning"
fi

# 11. The legacy render path is branded (ADR-0004). An untrusted Host is the ONLY screen in that
# class reachable without mutating the instance — maintenance, the upgrade screens and the setup
# screens all have to be staged — and it is also the strictest of them: failing isTrustedDomain()
# is what makes Server.php hand out a raw \OC_Defaults instead of ThemingDefaults, so this one
# request exercises BOTH halves of the fix at once. The themed stylesheet proves guest.css arrived;
# the absence of the vendor name proves defaults.php did. Everything else in the class shares the
# same two stylesheets and the same layout, so this stands in for all of them.
untrusted=$(curl -s -H 'Host: untrusted.invalid' "http://localhost:${HTTP_PORT}/" 2>/dev/null)
printf '%s' "$untrusted" | grep -q 'themes/apsconecta/core/css/guest.css' \
  || fail "legacy-rendered screens carry no theme CSS — themes/apsconecta/core/css/guest.css is not linked on the untrusted-domain screen (maintenance, upgrade, 429 and the setup screens render through the same path)"
# Two vendor URLs are EXEMPT and are listed here rather than assumed (CONTEXT.md, "vendor
# reference"): the admin documentation link, whose visible label is "documentación" and which is the
# real page explaining trusted_domains, and the sync-client URL, which points at clients that can
# actually be installed. Renaming either would ship a lie, which is the worse defect. They are
# stripped by exact host so that ANY other occurrence — including a different nextcloud.com link, or
# the word in visible text — still fails. Backslashes go first: both appear JSON-escaped in the
# initial state as well as in href attributes.
visible=$(printf '%s' "$untrusted" | tr -d '\\' \
  | sed -e 's|https://docs\.nextcloud\.com[^" ]*||g' -e 's|https://nextcloud\.com/install[^" ]*||g')
if printf '%s' "$visible" | grep -qi 'nextcloud'; then
  fail "branding leak on the legacy render path: the untrusted-domain screen names Nextcloud outside the two exempt URLs — themes/apsconecta/defaults.php is the only thing that answers there (ThemingDefaults is bypassed for an untrusted host)"
fi

# 12. admin's home carries no stock skeleton. Check 5 is /status.php only and every other branding
# assertion here reads unauthenticated HTML, so none of them can see this. A config read would be
# vacuous — phase 15 writes '' into config.php either way; only the files regress. The listing is
# captured, not piped: an EMPTY home is the passing state, so "clean" and "could not look" are
# indistinguishable by value and only the exit status separates them. Hence no 2>/dev/null.
home=$(docker compose exec -T --user www-data nextcloud ls -A "/var/www/html/data/${NEXTCLOUD_ADMIN_USER:-admin}/files") \
  || fail "cannot list admin's home — check 12 cannot answer, so it must not report clean"
printf '%s' "$home" | grep -qi 'nextcloud' \
  && fail "stock Nextcloud skeleton in admin's home — is NC_skeletondirectory still in compose.yaml? phase 15's skeletondirectory arrives after the image has already created and logged in admin"

echo "PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200, no branding leak, cron scheduling, app policy, no remember-me, no stale app signature, legacy screens branded, clean admin home"
