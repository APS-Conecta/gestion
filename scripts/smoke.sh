#!/usr/bin/env bash
# Core-stack smoke — is the running APS Conecta stack healthy? (Story 0.4)
# Exits 0 on a healthy stack, non-zero (with a labeled FAIL) on a broken/absent one.
# Checks the core invariants only — the office backend has its own scripts/office-smoke.sh.
set -uo pipefail

# cd to the repo root + load .env, so `bash scripts/smoke.sh` and `make smoke` behave identically
# from any cwd. See scripts/env.sh for why .env is parsed rather than sourced.
# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"

fail() { echo "FAIL: $*"; exit 1; }

# 1. nextcloud container running (exec would hang/err on a down stack — detect first). Detection
# flipped with the docker-exec port: the compose-era stack listing needed compose context, which
# neither the probe bed nor an AIO clinic has; `docker ps` by NAME works everywhere and names the
# same container the seam targets. A compose dev stack reads as down here BY DESIGN — its install
# and seed stay addressable through NC_CONTAINER (D5 interim), and this check answering "no AIO
# stack" is the labeled failure, not a compose-context false answer.
is_aio \
  || fail "aps-conecta-nextcloud is not running — smoke answers an AIO instance (probe: scripts/aio-testbed.sh up; a clinic: the wizard's container start)"
nc_container   # once: the occ calls below run in pipes and $(…), whose cache dies with them

# 2. Nextcloud installed + reachable via occ.
occ status --output=json 2>/dev/null | grep -q '"installed":true' \
  || fail "occ status: Nextcloud not installed / not reachable"
# every HTTP check below rides the suite's public URL (env.sh, #163) — resolved once, here
suite_url_resolve || exit 1

# 3. PostgreSQL accepting connections. Direct docker exec against the AIO sibling's fixed name —
# these two cannot ride the seam (it targets the nextcloud container) and need no compose context.
docker exec aps-conecta-database pg_isready -q 2>/dev/null \
  || fail "PostgreSQL (aps-conecta-database) is not accepting connections"

# 4. Redis responding to PING. AIO's redis runs with requirepass — the password is read
# IN-CONTAINER from its own env (REDIS_HOST_PASSWORD), never on the host argv (the OC_PASS
# discipline): a bare `redis-cli ping` answers NOAUTH on every real AIO instance (FINDINGS.md P3).
[ "$(docker exec aps-conecta-redis sh -c 'redis-cli -a "$REDIS_HOST_PASSWORD" ping' 2>/dev/null | tr -d '\r')" = "PONG" ] \
  || fail "Redis (aps-conecta-redis) is not responding to PING"

# 5. HTTP surface: GET /status.php → 200, and the body carries OUR product name. The highest-value
# branding regression there is: unauthenticated, and if `theming productName` is unset it says
# "Nextcloud" to anyone who asks. The same string leaks through OC.theme, the OCS capabilities and
# the public-share button, so this one grep covers the family.
body=$(suite_curl -s -w '\n%{http_code}' "$SUITE_URL/status.php" 2>/dev/null || echo $'\n000')
code=${body##*$'\n'}
body=${body%$'\n'*}
[ "$code" = "200" ] || fail "GET $SUITE_URL/status.php returned HTTP ${code} (expected 200)$SUITE_D10"
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
  fail "the cron loop (cron.sh) is not running inside aps-conecta-nextcloud — background jobs would fall back to page-load scheduling"
fi
jobs_mode=$(occ config:app:get core backgroundjobs_mode 2>/dev/null | tr -d '\r')
[ "$jobs_mode" = "cron" ] \
  || fail "backgroundjobs_mode is '${jobs_mode:-unset}', expected 'cron' — run 'make seed' (phase 06-jobs)"

# Fetch the login page ONCE — checks 7 and 9 both read it, and it is the only unauthenticated page
# that carries both the manifest link and the login form's initial state.
login_html=$(suite_curl -s -w '\n%{http_code}' "$SUITE_URL/login" 2>/dev/null || echo $'\n000')
login_code=${login_html##*$'\n'}
login_html=${login_html%$'\n'*}
[ "$login_code" = "200" ] || fail "GET /login returned HTTP ${login_code} (expected 200)"

# 7. The login page serves OUR webmanifest, and it has not drifted. layout.guest.php hardcodes
# image_path('core', 'manifest.json') without the appid, so theming cannot intercept and the login
# page advertised {"name":"Nextcloud"} to anything offering "install app". The fix is a static file
# at themes/<theme>/core/img/manifest.json, which URLGenerator::imagePath() prefers over core's —
# and being static, its failure mode is DRIFT from `occ theming:config`, not absence. So compare
# against the app's generated manifest, which is the source of truth.
theme_man=$(suite_curl -s "$SUITE_URL/apps/theming/manifest" 2>/dev/null)
static_man=$(suite_curl -s "$SUITE_URL/themes/apsconecta/core/img/manifest.json" 2>/dev/null)
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
  || fail "login page still links Nextcloud's manifest, not ours — if the file exists, flush the cache (docker exec aps-conecta-redis sh -c 'redis-cli -a \"$REDIS_HOST_PASSWORD\" FLUSHALL')"
# The three icon links are the same static-file mechanism as the manifest and share its failure mode
# (ADR-0004). They are here rather than beside it because they cost nothing extra — this HTML is
# already fetched — and because imagePath() caches under a key holding NO cachebuster and NO theme,
# so adding a file to the theme is invisible until the cache is flushed. Without this the icons are
# silently Nextcloud's and the tab shows the vendor's mark on every screen.
for rel in icon apple-touch-icon mask-icon; do
  printf '%s' "$login_html" | grep -q "rel=\"${rel}\"[^>]*href=\"[^\"]*themes/apsconecta" \
    || fail "login page links Nextcloud's ${rel}, not ours — if themes/apsconecta/core/img/ has the file, flush the cache (docker exec aps-conecta-redis sh -c 'redis-cli -a \"$REDIS_HOST_PASSWORD\" FLUSHALL')"
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

# 10. No release app carries the store's signature (#71, phase 12-apps; #133). The bake-era
# check globbed `provisioning/apps/<app>/*.patch` — a path ADR-0018 deleted with the bake, so
# under #42 the glob watched a signal nobody could produce and passed vacuously on every run.
# What the suite guarantees today is the same invariant at its live edge: white-label renames
# arrive as commits of the fork's own repos (#36), a release never packs appinfo/signature.json
# (releases.py refuses one that does), and the seed re-imposes the release's bytes when the
# installed tree grows one — so the file's presence on a release app is PROOF the bytes are
# upstream's tarball, not the fork's release: the rename is gone. A store app keeps its own
# signature, true by construction (unmodified upstream, lib.sh's #82 rule), which is why this
# reads only the manifest's release rows (apps.py repos: the id where the repo is non-empty).
# An unreadable manifest is apps.py's to report — its one Spanish line is already on stderr.
# smoke runs without errexit, so exit by hand, with nothing added beside that one line (pipefail
# carries apps.py's failure through the filter pipe).
release_ids=$(python3 scripts/apps.py repos | python3 -c '
import sys
print(" ".join(l.split("\t", 1)[0] for l in sys.stdin if "\t" in l and l.split("\t", 1)[1].strip()))
') || exit $?
# The check 8 refusal: an EMPTY want-set satisfies the probe below while asserting nothing at all.
[ -n "$release_ids" ] || fail "apps.json names no release app — the signature check would assert nothing"
signed=$(nc_exec --user www-data -- sh -c \
  "for a in $release_ids; do [ -e \"/var/www/html/custom_apps/\$a/appinfo/signature.json\" ] && echo \"\$a\"; done; :" \
  2>/dev/null | tr -d '\r' | tr '\n' ' ')
[ -z "${signed// /}" ] \
  || fail "release app(s) carrying the store's signature: ${signed}— upstream's tarball replaced the fork's release, so the white-label rename is gone. Run 'make seed' (provisioning re-imposes the release's bytes, which carry no signature)"

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
# render (measured on the probe bed, FINDINGS.md P4, apache's internal httpd included). That bounce
# IS AIO's protection of the legacy class, so the check asks it of the internal httpd from inside
# the apache container — the leg every posture shares; a clinic's 443 front serves only the suite's
# own name (#163) — and asserts (a) it still holds: a drift to the raw page means the legacy screens
# became HTTP-reachable; (b) the two branding inputs the legacy path reads when it does render: the
# active theme's guest.css and defaults.php, read in-container through the seam (test.sh's
# vendor-block style).
_oh="$(occ config:system:get overwritehost 2>/dev/null | tr -d '\r')"
if [ -n "$_oh" ]; then
  _resp=$(docker exec aps-conecta-apache sh -c 'printf "GET / HTTP/1.0\r\nHost: untrusted.invalid\r\n\r\n" | nc -w 5 127.0.0.1 8000' 2>/dev/null | tr -d '\r')
  [ -n "$_resp" ] || fail "check 11: no answer from apache's internal httpd (docker exec aps-conecta-apache … nc 127.0.0.1 8000) — apache down or no nc in its image, not a lost bounce"
  _status=$(printf '%s\n' "$_resp" | head -1 | cut -d' ' -f2)
  _location=$(printf '%s\n' "$_resp" | sed -n 's/^[Ll]ocation: //p' | head -1)
  [ "$_status" = 302 ] && [[ $_location == "https://$_oh/"* ]] \
    || fail "untrusted-host requests no longer bounce to https://$_oh/ (status ${_status:-none}, Location ${_location:-none}) — the legacy render class became HTTP-reachable (ADR-0004)"
  _theme="$(occ config:system:get theme 2>/dev/null | tr -d '\r')"
  nc_exec --user www-data -- test -f "/var/www/html/themes/${_theme:-apsconecta}/core/css/guest.css" 2>/dev/null \
    || fail "the active theme ships no core/css/guest.css — the legacy render path cannot be branded (ADR-0004)"
  nc_exec --user www-data -- test -f "/var/www/html/themes/${_theme:-apsconecta}/defaults.php" 2>/dev/null \
    || fail "the active theme ships no defaults.php — the legacy render path would name the vendor (ADR-0004)"
else
untrusted=$(suite_curl -s -H 'Host: untrusted.invalid' "$SUITE_URL/" 2>/dev/null)
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

# 13. The app store is off (#163, #42). The compose-era loop checked nextcloud AND cron — two
# containers that had to agree. Under AIO there is ONE container to ask: cron.php runs inside
# aps-conecta-nextcloud (check 6's loop), so the pair collapses into a single read and the loop
# is deleted rather than kept degenerate. The lever moved with it — from compose.yaml's
# NC_appstoreenabled to the image's own ENV: NC_appstoreenabled="0" baked into aio-nextcloud
# (patch 020), with the scoped per-command installs (#42) as the only openings, none of them on
# a smoke's path. This asserts the LEVER, not the drift it prevents; an absent key reads "" and
# is not "0", so this cannot fail open.
got=$(occ config:system:get appstoreenabled 2>/dev/null | tr -d '\r')
[ "$got" = "0" ] \
  || fail "the app store is enabled (read '$got') — the image bakes NC_appstoreenabled=0 (patch 020) and only #42's scoped installs open it, one command at a time; occ upgrade would re-download every enabled app (#163)"

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

# 16. Territorio's comuna. The map itself is OpenStreetMap's tile service, loaded by each user's browser
# (ADR-0021 in territorio): nothing is provisioned for it, so no tile_url is asserted — a stale one on an
# upgraded install is the app's own repair step to delete, not this suite's to police. What phase 16
# still writes, and the app derives the map's opening extent from, is the comuna's CUT and name: an
# empty comuna_cut is also the silent disarm of the import door (ComunaConfig reads it as "not chosen"),
# so both must be set.
_comuna_cut="$(occ config:app:get territorio comuna_cut 2>/dev/null | tr -d '\r')"
_comuna_name="$(occ config:app:get territorio comuna_name 2>/dev/null | tr -d '\r')"
[ -n "$_comuna_cut" ] \
  || fail "territorio comuna_cut is not set — the map has no extent to open on and the import door is disarmed (ComunaConfig reads empty as 'not chosen'). Re-seed: phase 16-app-policy writes it from sites/<slug>/site.sh's SITE_COMUNA_CUT"
[ -n "$_comuna_name" ] \
  || fail "territorio comuna_name is not set — the admin section and the import refusal have no name to show. Re-seed: phase 16-app-policy writes it from sites/<slug>/site.sh's SITE_COMUNA"

echo "PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200, no branding leak, cron scheduling, app policy, no remember-me, no store signature on a release app, legacy screens branded, clean admin home, app store off, office URL matches how this instance is reached, territorio's comuna set"
