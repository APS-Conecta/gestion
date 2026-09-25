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

# 1. nextcloud container running (exec would hang/err on a down stack — detect first). Detection
# flipped with the docker-exec port: the compose-era stack listing needed compose context, which
# neither the probe bed nor an AIO clinic has; `docker ps` by NAME works everywhere and names the
# same container the seam targets. A compose dev stack reads as down here BY DESIGN — its install
# and seed stay addressable through NC_CONTAINER (D5 interim), and this check answering "no AIO
# stack" is the labeled failure, not a compose-context false answer.
docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud-aio-nextcloud \
  || fail "nextcloud-aio-nextcloud is not running — smoke answers an AIO instance (probe: scripts/aio-testbed.sh up; a clinic: the wizard's container start)"

# 2. Nextcloud installed + reachable via occ.
occ status --output=json 2>/dev/null | grep -q '"installed":true' \
  || fail "occ status: Nextcloud not installed / not reachable"

# 3. PostgreSQL accepting connections. Direct docker exec against the AIO sibling's fixed name —
# these two cannot ride the seam (it targets the nextcloud container) and need no compose context.
docker exec nextcloud-aio-database pg_isready -q 2>/dev/null \
  || fail "PostgreSQL (nextcloud-aio-database) is not accepting connections"

# 4. Redis responding to PING. AIO's redis runs with requirepass — the password is read
# IN-CONTAINER from its own env (REDIS_HOST_PASSWORD), never on the host argv (the OC_PASS
# discipline): a bare `redis-cli ping` answers NOAUTH on every real AIO instance (FINDINGS.md P3).
[ "$(docker exec nextcloud-aio-redis sh -c 'redis-cli -a "$REDIS_HOST_PASSWORD" ping' 2>/dev/null | tr -d '\r')" = "PONG" ] \
  || fail "Redis (nextcloud-aio-redis) is not responding to PING"

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

# 6. Background jobs are scheduled, not traffic-driven (phase 06-jobs). Under AIO there is no cron
# CONTAINER: cron.php runs from a 5-minute loop (cron.sh, started by the container's own dinit)
# inside the nextcloud container, so the compose-era "cron service is running" half becomes an
# assertion on that loop process. Both halves still get asserted, because either alone is a silent
# half-fix: the mode without the loop means Nextcloud waits for a cron that never runs (worse than
# ajax), the loop without the mode means it runs while Nextcloud still self-serves jobs on page
# loads.
if ! nc_exec --user www-data -- pgrep -f cron.sh >/dev/null 2>&1; then
  fail "the cron loop (cron.sh) is not running inside nextcloud-aio-nextcloud — background jobs would fall back to page-load scheduling"
fi
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
  || fail "login page still links Nextcloud's manifest, not ours — if the file exists, flush the cache (docker exec nextcloud-aio-redis sh -c 'redis-cli -a \"$REDIS_HOST_PASSWORD\" FLUSHALL')"
# The three icon links are the same static-file mechanism as the manifest and share its failure mode
# (ADR-0004). They are here rather than beside it because they cost nothing extra — this HTML is
# already fetched — and because imagePath() caches under a key holding NO cachebuster and NO theme,
# so adding a file to the theme is invisible until the cache is flushed. Without this the icons are
# silently Nextcloud's and the tab shows the vendor's mark on every screen.
for rel in icon apple-touch-icon mask-icon; do
  printf '%s' "$login_html" | grep -q "rel=\"${rel}\"[^>]*href=\"[^\"]*themes/apsconecta" \
    || fail "login page links Nextcloud's ${rel}, not ours — if themes/apsconecta/core/img/ has the file, flush the cache (docker exec nextcloud-aio-redis sh -c 'redis-cli -a \"$REDIS_HOST_PASSWORD\" FLUSHALL')"
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
  signed=$(nc_exec --user www-data -- sh -c \
    "for a in $patched; do [ -e \"/var/www/html/custom_apps/\$a/appinfo/signature.json\" ] && echo \"\$a\"; done; :" \
    2>/dev/null | tr -d '\r' | tr '\n' ' ')
  [ -z "${signed// /}" ] \
    || fail "patched app(s) still signed: ${signed}— the code-integrity check will fail and admin > Overview will show a red warning. Run 'make seed' (phase 12-apps drops it), then click 'Rescan…' in that warning"
fi

# 11. The legacy render path is branded (ADR-0004). TWO TRANSPORTS, because the reachable screen
# differs. On a compose stack (no overwritehost) an untrusted Host is the ONLY screen in that
# class reachable without mutating the instance — maintenance, the upgrade screens and the setup
# screens all have to be staged — and it is also the strictest of them: failing isTrustedDomain()
# is what makes Server.php hand out a raw \OC_Defaults instead of ThemingDefaults, so this one
# request exercises BOTH halves of the fix at once. The themed stylesheet proves guest.css arrived;
# the absence of the vendor name proves defaults.php did. Everything else in the class shares the
# same two stylesheets and the same layout, so this stands in for all of them.
#
# Under AIO the screen is structurally unreachable by HTTP: the entrypoint sets overwritehost=
# <domain>, and NC redirects an untrusted Host to the canonical base URL BEFORE the legacy 400 can
# render (measured on the probe bed, FINDINGS.md P4 — even a direct request to the apache
# container's internal httpd bounces). AIO's own protection of the legacy class IS that bounce,
# so there the check asserts (a) the bounce still holds — a drift to the raw page means the legacy
# screens became HTTP-reachable, and this goes red for exactly that — and (b) the two branding
# inputs the legacy path reads when it does render: the active theme's guest.css and defaults.php,
# read in-container through the seam (the same contract style as test.sh's vendor-block).
if [ -n "$(occ config:system:get overwritehost 2>/dev/null | tr -d '\r')" ]; then
  _bounce=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: untrusted.invalid' "http://localhost:${HTTP_PORT}/" 2>/dev/null)
  case "${_bounce:-000}" in
    302) : ;;
    *) fail "untrusted-host requests no longer bounce to the canonical domain (HTTP ${_bounce:-none}, expected 302) — the legacy render class became HTTP-reachable; eyeball whether its screens are still branded (ADR-0004)" ;;
  esac
  _theme="$(occ config:system:get theme 2>/dev/null | tr -d '\r')"
  nc_exec --user www-data -- test -f "/var/www/html/themes/${_theme:-apsconecta}/core/css/guest.css" 2>/dev/null \
    || fail "the active theme ships no core/css/guest.css — the legacy render path cannot be branded (ADR-0004)"
  nc_exec --user www-data -- test -f "/var/www/html/themes/${_theme:-apsconecta}/defaults.php" 2>/dev/null \
    || fail "the active theme ships no defaults.php — the legacy render path would name the vendor (ADR-0004)"
else
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
fi

# 12. admin's home carries no stock skeleton. Check 5 is /status.php only and every other branding
# assertion here reads unauthenticated HTML, so none of them can see this. A config read would be
# vacuous — phase 15 writes '' into config.php either way; only the files regress. The listing is
# captured, not piped: an EMPTY home is the passing state, so "clean" and "could not look" are
# indistinguishable by value and only the exit status separates them. Hence no 2>/dev/null.
# The default names the account on both stacks: AIO installs with ADMIN_USER=admin (its
# containers.json), and compose's official image takes the user from the same .env key. The
# data DIRECTORY is read from the instance instead of assumed — AIO installs with
# --data-dir /mnt/ncdata, compose with the image default /var/www/html/data — one occ read,
# correct on both, and failing to read it must not read as a clean home.
datadir=$(occ config:system:get datadirectory 2>/dev/null | tr -d '\r')
[ -n "$datadir" ] \
  || fail "cannot read datadirectory — check 12 cannot answer, so it must not report clean"
home=$(nc_exec --user www-data -- ls -A "${datadir%/}/${NEXTCLOUD_ADMIN_USER:-admin}/files") \
  || fail "cannot list admin's home — check 12 cannot answer, so it must not report clean"
printf '%s' "$home" | grep -qi 'nextcloud' \
  && fail "stock Nextcloud skeleton in admin's home — is NC_skeletondirectory still in compose.yaml? phase 15's skeletondirectory arrives after the image has already created and logged in admin"

# 13. The app store is off (#163). The compose-era loop checked nextcloud AND cron — two
# containers that had to agree. Under AIO there is ONE container to ask: cron.php runs inside
# nextcloud-aio-nextcloud (check 6's loop), so the pair collapses into a single read and the loop
# is deleted rather than kept degenerate. The lever moved with it — from compose.yaml's
# NC_appstoreenabled to the suite's own posture: the probe harness sets the key at bring-up, and
# the suite bakes NC_appstoreenabled="0" into the aio-nextcloud image (patch 020). This asserts
# the LEVER, not the drift it prevents; an absent key reads "" and is not "0", so this cannot
# fail open.
got=$(occ config:system:get appstoreenabled 2>/dev/null | tr -d '\r')
[ "$got" = "0" ] \
  || fail "the app store is enabled (read '$got') — the probe sets appstoreenabled=0 at bring-up and the suite bakes NC_appstoreenabled=0 via patch 020; occ upgrade then re-downloads every enabled app and the VENDOR pins stop meaning anything (#163)"

# 14. The browser-facing office URL agrees with how this instance is actually reached (B-019).
#
# `DocumentServerUrl` is the address the BROWSER loads the editor from, and it defaults to
# localhost — correct while the browser is on this box, wrong the moment somebody opens the suite
# from a laptop, where localhost means THEIR loopback. It surfaces as a token/security complaint,
# which sends the search to OFFICE_JWT_SECRET, where nothing is wrong.
#
# This CANNOT be tested from the browser's side: this script runs on the box, where localhost:9980
# answers 200, so a reachability probe passes on precisely the broken configuration. What IS visible
# from here is the CONTRADICTION — an instance that publishes a non-loopback trusted domain is
# reached from somewhere else, and a loopback editor URL cannot be right for that somewhere.
# Both halves must be true to fail, so the local-only posture this repo ships stays green.
_office_url=$(occ config:app:get eurooffice DocumentServerUrl 2>/dev/null | tr -d '\r')
if [ -n "$_office_url" ]; then
  # Loopback in the value, and any trusted domain that is neither a loopback name nor the compose
  # service name phase 14 adds for the callback.
  _remote_domain=$(occ config:system:get trusted_domains 2>/dev/null \
    | tr -d '\r' | grep -vxE 'localhost|127\.0\.0\.1|\[::1\]|nextcloud|' | head -1)
  case "$_office_url" in
    *localhost*|*127.0.0.1*|*'[::1]'*)
      [ -z "$_remote_domain" ] \
        || fail "eurooffice DocumentServerUrl is '$_office_url' but this instance is also reached at '$_remote_domain' — the browser loads the editor from that URL, so for anyone not sitting at this box it points at their OWN loopback and the editor never comes up. It reports a token/security problem, which is not what is wrong: set OFFICE_PUBLIC_URL in .env and re-seed (B-019)" ;;
  esac
  # Scheme, the second half of the same mistake: an http editor inside an https page is blocked as
  # mixed content, so the address can be perfectly reachable and the pane still stays blank.
  _proto=$(occ config:system:get overwriteprotocol 2>/dev/null | tr -d '\r')
  if [ "$_proto" = "https" ]; then
    case "$_office_url" in
      https://*) ;;
      *) fail "overwriteprotocol is https but eurooffice DocumentServerUrl is '$_office_url' — the browser blocks an http editor inside an https page as mixed content, and the pane stays blank with only a console entry. Give OFFICE_PUBLIC_URL an https address and re-seed (B-019)" ;;
    esac
  fi
fi

# 15. Admin settings actions respond <500 (org review L4-01: the vendored desktop_workspace
# shipped saveAdminSettings calling an undefined getLogPath() — every admin "Save" was a
# 500 that lied while the settings PERSISTED). The only authenticated check in smoke: it
# logs in as the admin whose credentials .env already holds, POSTs each admin settings
# route with parameters READ BACK from the instance (query-before-write — a blind
# default POST would reset an admin's real choices), and asserts no answer is a 5xx.
# resetuser is probed with a user that cannot exist: unknown_user answers 404 (<500)
# without writing anything. The password never touches argv — curl reads stdin.
smoke_jar="$(mktemp)"
smoke_login_page=$(curl -s -c "$smoke_jar" "http://localhost:${HTTP_PORT}/login" 2>/dev/null)
smoke_token=$(printf '%s' "$smoke_login_page" | grep -o 'data-request-token="[^"]*"' | head -1 | cut -d'"' -f2)
[ -n "$smoke_token" ] || fail "check 15: no request token on /login — cannot probe admin settings"
code=$(printf 'user=%s&password=%s&requesttoken=%s' "$NEXTCLOUD_ADMIN_USER" "${NEXTCLOUD_ADMIN_PASSWORD:-}" "$smoke_token" \
  | curl -s -o /dev/null -w '%{http_code}' -b "$smoke_jar" -c "$smoke_jar" \
      -H 'Content-Type: application/x-www-form-urlencoded;charset=UTF-8' --data-binary @- \
      "http://localhost:${HTTP_PORT}/login" 2>/dev/null)
case "$code" in 200|302) ;; *) fail "check 15: admin login answered HTTP $code — cannot probe admin settings" ;; esac
# a fresh token for authenticated POSTs (the login-page token was consumed by the login)
smoke_page=$(curl -s -b "$smoke_jar" -c "$smoke_jar" "http://localhost:${HTTP_PORT}/index.php/apps/desktop_workspace/" 2>/dev/null)
smoke_token=$(printf '%s' "$smoke_page" | grep -o 'data-request-token="[^"]*"' | head -1 | cut -d'"' -f2)
# form-encode every read-back value: a group name carrying & + or % would otherwise
# split/decode the body and turn the "no-op" POST into a real config write.
enc() { printf '%s' "$1" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))'; }
exp_dis=$(occ config:app:get desktop_workspace experimental_files_disabled 2>/dev/null | tr -d '\r'); [ -n "$exp_dis" ] || exp_dis=no
read_exp_grp=$(occ config:app:get desktop_workspace experimental_files_groups 2>/dev/null | tr -d '\r'); [ -n "$read_exp_grp" ] || read_exp_grp='[]'
exp_grp=$(enc "$read_exp_grp")
read_multi=$(occ config:app:get desktop_workspace multi_window_apps 2>/dev/null | tr -d '\r'); [ -n "$read_multi" ] || read_multi='[]'
multi=$(enc "$read_multi")
deco=$(occ config:app:get desktop_workspace user_decorations_enabled 2>/dev/null | tr -d '\r'); [ -n "$deco" ] || deco=yes
fbt=$(occ config:app:get desktop_workspace show_files_new_tab 2>/dev/null | tr -d '\r'); [ -n "$fbt" ] || fbt=yes
smoke_body="$(mktemp)"
smoke_post() {  # PATH PARAMS(already encoded) -> HTTP code
  printf '%s&requesttoken=%s' "$2" "$smoke_token" > "$smoke_body"
  curl -s -o /dev/null -w '%{http_code}' -b "$smoke_jar" -H "requesttoken: $smoke_token" \
    -H 'Content-Type: application/x-www-form-urlencoded;charset=UTF-8' --data-binary "@$smoke_body" \
    "http://localhost:${HTTP_PORT}/index.php/apps/desktop_workspace/$1" 2>/dev/null
}
for probe in \
  "settings/admin|experimental_disabled=$exp_dis&experimental_groups=$exp_grp&multi_window_apps=$multi&user_decorations_enabled=$deco" \
  "settings/admin/decorations|enabled=$deco" \
  "settings/admin/files-button|enabled=$fbt" \
  "settings/admin/resetuser|userId=__smoke_no_such_user__"
do
  p="${probe%%|*}"; q="${probe#*|}"
  case "$(smoke_post "$p" "$q")" in
    5*) fail "check 15: desktop_workspace /$p answered HTTP 5xx — an admin settings action is a 500 (org L4-01: is 01-settings-getlogpath.patch applied? run make seed)" ;;
  esac
done
rm -f "$smoke_jar" "$smoke_body"
# 16. Territorio's tile_url is not the B-019 shape (org review L5-07 — the mirror of check 14
# for the basemap): phase 16 defaults it to the loopback tiles service, which works for a
# browser on this box and for nobody else — a public-domain install passes every other gate
# green while every off-host browser shows «No se pudo cargar el fondo de mapa». The same
# contradiction test as eurooffice's: a loopback tile_url together with a non-loopback
# trusted domain cannot both be right. From THIS box the tiles URL is reachable either way,
# so reachability is not the gate — the CONTRADICTION is (B-019's own lesson).
_tiles_url=$(occ config:app:get territorio tile_url 2>/dev/null | tr -d '\r')
if [ -n "$_tiles_url" ]; then
  _remote_domain=$(occ config:system:get trusted_domains 2>/dev/null \
    | tr -d '\r' | grep -vxE 'localhost|127\.0\.0\.1|\[::1\]|nextcloud|' | head -1)
  case "$_tiles_url" in
    *localhost*|*127.0.0.1*|*'[::1]'*)
      [ -z "$_remote_domain" ] \
        || fail "territorio tile_url is '$_tiles_url' but this instance is also reached at '$_remote_domain' — off-host browsers get no basemap. Set TILES_PUBLIC_URL in .env and re-seed (phase 16-app-policy) — the B-019 shape, mirrored (org L5-07)" ;;
  esac
fi

echo "PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200, no branding leak, cron scheduling, app policy, no remember-me, no stale app signature, legacy screens branded, clean admin home, app store off, office URL matches how this instance is reached"
