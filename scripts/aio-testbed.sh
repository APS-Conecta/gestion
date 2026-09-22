#!/usr/bin/env bash
# AIO test-bed harness — a disposable All-in-One instance for the installer probe (design slice 1).
#
# WHY THIS EXISTS. Three couplings decide whether every later gate of the installer program can be
# trusted — the docker-exec port, the bake-wins probe, divergence-as-gate — and this org's
# documented defect class is the silent green: BUGS.md B-001…B-007 came from the first bring-up
# that was complete on paper and never run; B-014 was a gate that could not go red; 11 of 19
# handoff claims measured wrong at the 2026-09-13 stand-up (FINDINGS.md). So the couplings are
# proven on a REAL AIO stack — stock upstream images, no S1 dependency — before anything is
# built on them. This script is also S8's CI harness in embryo: when the port lands, cleanboot's
# compose bring-up retires and this is what replaces it (probe scaffolding converts into S8's
# machinery).
#
# WHERE IT RUNS. A disposable VM (the approved probe host) or any Ubuntu+docker host with ≥3.5 GiB
# available. It NEVER claims host 80/443: the wizard publishes :8080, apache and domaincheck
# publish loopback-only on a high port (APACHE_IP_BINDING=127.0.0.1) — gate.sh posture on a
# shared box is untouched. NO Let's Encrypt: with APACHE_PORT≠443 the apache Caddy runs
# auto_https off, and the mastercontainer's acme issuer is on-demand only, never triggered by
# IP:8080 browsing.
#
# Wizard automation is the same request sequence upstream's initial-setup Playwright spec drives
# minus the browser: capture the one-time initial password from the first GET /setup (login is
# blocked once apache runs), log in, set the domain, set the timezone, save the options form
# (ABSENCE disables: talk/whiteboard/imaginary stay off, office stays eurooffice by default),
# start the containers, then wait bounded. SKIP_DOMAIN_VALIDATION + an RFC-2606 .invalid domain
# installs without DNS; the domain is immutable afterwards, which a disposable instance does not
# care about.
#
# DELIBERATELY STANDALONE: no scripts/env.sh, no gestion occ() — the docker-exec port (slice 2)
# is what will bind gestion to this instance, and the harness must work before that lands. Every
# occ below is the upstream canonical console form: `--user www-data` (readme.md:822) — root
# occ trips Nextcloud's console config-owner check and dies mid-flow.
#
# Findings from every run belong in /opt/aps-conecta-org/FINDINGS.md as they happen — recorded,
# not fixed opportunistically (house rule).
#
# Usage:
#   scripts/aio-testbed.sh up        preflight → run mastercontainer → capture → configure → start → bounded waits → probe state (store off, skeleton cleared, theme seeded) → gate
#   scripts/aio-testbed.sh down      remove every nextcloud-aio* container, volume and the state dir
#   scripts/aio-testbed.sh gate      assert no non-loopback port outside the wizard is claimed
#   scripts/aio-testbed.sh status    what runs, what it publishes, where the passwords are
#
# Env: AIO_TEST_IMAGE (default upstream latest), AIO_TEST_PORT (8080), AIO_TEST_APACHE_PORT
# (11000), AIO_TEST_DOMAIN (aio-test.invalid). State: /tmp/aio-testbed/ — secrets 0600, values
# never printed, only their paths (env-init rule).
set -uo pipefail

STATE=/tmp/aio-testbed
MC=nextcloud-aio-mastercontainer            # fixed by Containers/mastercontainer/start.sh:164-170
NC=nextcloud-aio-nextcloud                   # fixed by php/containers.json:145
IMAGE="${AIO_TEST_IMAGE:-ghcr.io/nextcloud-releases/all-in-one:latest}"
WIZARD_PORT="${AIO_TEST_PORT:-8080}"
APACHE_PORT="${AIO_TEST_APACHE_PORT:-11000}"
DOMAIN="${AIO_TEST_DOMAIN:-aio-test.invalid}"
WIZ="https://127.0.0.1:${WIZARD_PORT}"
# Enabled set after the options form: office stays eurooffice (suite default; phase 14 and
# office-smoke need the DS), the three heavyweight optionals stay off. NC + five siblings.
SIBLINGS="nextcloud-aio-apache nextcloud-aio-database nextcloud-aio-redis nextcloud-aio-notify-push nextcloud-aio-eurooffice"

die() { echo "FATAL: $*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing prerequisite on this host: $1"; }

port_free() {  # PORT — rule-10 discipline: check before exposing, not after docker fails
  ss -ltn "sport = :$1" 2>/dev/null | tail -n +2 | grep -q . && return 1
  return 0
}

check_ram() {
  # Self-applied resource rule: refuse rather than oversubscribe — on a shared box that would
  # be production; on a disposable VM it is just a smaller VM than the stack needs.
  local kb
  kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)" || kb=0
  [ "${kb:-0}" -ge 3600000 ] || die "only $((kb/1024)) MiB available — the probe stack needs ~3.5 GiB (container set, eurooffice DS included). Use a bigger VM."
  say "RAM ok: $((kb/1024)) MiB available"
  local la cores
  la="$(awk '{print int($1)}' /proc/loadavg)"; cores="$(nproc 2>/dev/null || echo 1)"
  [ "$la" -lt "$cores" ] || say "NOTE: load ${la} ≥ ${cores} cores — bring-up will be slow, not unsafe"
}

wpost() {  # PATH CSRF_NAME CSRF_VALUE [extra --data-urlencode args…] — POST the wizard config API
  local path="$1" name="$2" value="$3"; shift 3
  local code
  code="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 15 \
    --data-urlencode "csrf_name=$name" --data-urlencode "csrf_value=$value" "$@" "$WIZ$path")" \
    || die "POST $path: curl failed at the transport level"
  # ConfigurationController answers 201 on success and 422 with the reason in the body; nothing else.
  [ "$code" = "201" ] || die "POST $path returned $code (expected 201) — the configuration was rejected"
}

start_post() {  # CSRF_NAME CSRF_VALUE — POST api/docker/start
  local name="$1" value="$2" code
  # /api/docker/start is a SYNCHRONOUS streaming response: the recursive walk — delete,
  # create-volume, PULL, create, start, per container — happens inside the request
  # (DockerController.php:216-262, NonBufferedBody, ignore_user_abort). So the bound here is
  # the PULL BUDGET, not a handshake timeout: 30 min covers the ~6 GB the container set costs
  # on a slow VM. The state proof remains the container wait below; dying here means the pulls
  # are too slow for this VM — worth stopping for, not watching a hang.
  code="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 1800 \
    --data-urlencode "csrf_name=$name" --data-urlencode "csrf_value=$value" \
    "$WIZ/api/docker/start" 2>/dev/null)" || die "POST api/docker/start: curl failed at the 30 min pull bound"
  case "$code" in
    200|201|302) say "start completed (HTTP $code)" ;;
    *) die "POST api/docker/start returned $code — login or CSRF state is stale" ;;
  esac
}

cmd_gate() {
  # gate.sh posture applied to the probe: non-zero exit = STOP. Scoped by name — only
  # nextcloud-aio* containers are ours to judge, so a production host's own 80/443 listeners
  # are not false alarms. MUST be able to go red (B-014): the negative test plants a labelled
  # fake — docker run -d --name nextcloud-aio-gate-negative \
  #   --label com.docker.compose.project=nextcloud-aio -p 80:80 nginx — and this command must
  # fail until it is removed.
  local fail=0 seen=0 c line bind pub_pat
  pub_pat="*:${WIZARD_PORT}"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    seen=1
    while IFS= read -r line; do
      case "$line" in *" -> "*) ;; *) continue ;; esac   # unpublished ports are not claims
      bind="${line##* -> }"
      case "$bind" in
        127.0.0.1:*|localhost:*|\[::1\]:*) ;;            # loopback: never fights production
        $pub_pat) ;;                                     # the one public port, by design
        *) echo "FAIL: $c publishes $bind — the probe must not claim non-loopback ports"; fail=1 ;;
      esac
    done < <(docker port "$c" 2>/dev/null)
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -x 'nextcloud-aio-.*' || true)
  [ "$seen" = 1 ] || { echo "gate: nothing nextcloud-aio* running — nothing to check"; return 0; }
  if [ "$fail" = 0 ]; then echo "GATE: PASS — only :${WIZARD_PORT} and loopback claimed"; return 0; fi
  echo "GATE: *** FAIL ***"
  return 1
}

cmd_up() {
  need docker; need curl; need awk; need ss; need sed
  [ -S /var/run/docker.sock ] || die "no /var/run/docker.sock — the mastercontainer requires it (read-only mount)"
  docker inspect "$MC" >/dev/null 2>&1 && die "$MC already exists — run '$0 down' first, or '$0 status' to look"
  # The invariant this harness exists for, enforced not defaulted: the wizard port is NEVER a
  # production port. (cmd_gate blesses whatever ${WIZARD_PORT} is, so this guard is load-bearing.)
  case "$WIZARD_PORT" in
    80|443) die "AIO_TEST_PORT must never be 80/443 — the probe stays off the production ports by construction" ;;
  esac
  mkdir -p "$STATE"; chmod 700 "$STATE"
  # 0600 BEFORE content for everything written under $STATE (env-init rule) — passwords and the
  # session cookie alike; the explicit chmods below are assertions, not protection.
  umask 077
  check_ram
  port_free "$WIZARD_PORT" || die "port ${WIZARD_PORT} is already in use — set AIO_TEST_PORT to a free one (ss -tlnp shows the owner)"
  port_free "$APACHE_PORT" || die "loopback port ${APACHE_PORT} is already in use — set AIO_TEST_APACHE_PORT to a free one"
  # ghcr reachability, bounded: any HTTP answer — 401 included — proves DNS+TCP+TLS; 000 means
  # the image pulls would hang with no one watching.
  local code
  # curl prints 000 itself when no response arrives; `|| true` only swallows the exit status —
  # `|| echo 000` here would APPEND to it (code="000000") and the die below would never fire.
  code="$(curl -so /dev/null -w '%{http_code}' --max-time 10 https://ghcr.io/v2/ 2>/dev/null || true)"
  [ "$code" != "000" ] || die "https://ghcr.io/v2/ unreachable (bounded 10s) — fix the VM's network before pulling"

  say "run $MC from $IMAGE"
  # NEXTCLOUD_STARTUP_APPS= (empty, on purpose — slice 5's ratified forced amendment): AIO's default
  # startup set 'deck twofactor_totp tasks calendar contacts notes' (ConfigurationManager) would
  # app:install the four undeclared ones from the store while the store is still on at first boot;
  # empty skips the entrypoint's whole startup loop (its `[ -n "$STARTUP_APPS" ]` gate), so the
  # probe's custom_apps holds only what the seed and the entrypoint's notify_push/eurooffice legs
  # put there — the divergence gate's probe-green criterion depends on it, and zero store legs is
  # the acquisition-gate posture anyway. The mastercontainer's charset validator on this env is
  # `[ -n ]`-gated (start.sh:291-298): empty BYPASSES it, never trips it.
  docker run -d \
    --init --sig-proxy=false \
    --name "$MC" \
    --restart always \
    --publish "${WIZARD_PORT}:8080" \
    --env SKIP_DOMAIN_VALIDATION=true \
    --env NEXTCLOUD_STARTUP_APPS= \
    --env "APACHE_PORT=${APACHE_PORT}" \
    --env APACHE_IP_BINDING=127.0.0.1 \
    --volume nextcloud_aio_mastercontainer:/mnt/docker-aio-config \
    --volume /var/run/docker.sock:/var/run/docker.sock:ro \
    "$IMAGE" >/dev/null || die "docker run failed"

  say "wait for the wizard (bounded 2 min)"
  local setup_html="" i
  for i in $(seq 60); do
    sleep 2
    setup_html="$(curl -sk --max-time 5 "$WIZ/setup" 2>/dev/null || true)"
    case "$setup_html" in *'id="initial-password"'*) break ;; esac
  done
  case "$setup_html" in
    *'id="initial-password"'*) ;;
    *) die "wizard never served the initial password on $WIZ/setup within 2 min (docker logs $MC)" ;;
  esac
  # One-time page: the password is generated on the first GET and the page stops rendering it
  # the moment the instance is configured. Capture now or never — after start, login is blocked
  # while apache runs.
  local pw
  pw="$(printf '%s' "$setup_html" | sed -n 's/.*id="initial-password"[^>]*>\([^<]*\)<.*/\1/p' | head -1)"
  [ -n "$pw" ] || die "found the setup page but no password in it"
  printf '%s\n' "$pw" > "$STATE/master.pw"; chmod 600 "$STATE/master.pw"
  say "wizard password captured — $STATE/master.pw (0600)"

  say "login + configure through the wizard's own API"
  local html name value code2
  html="$(curl -sk -c "$STATE/cookies" --max-time 10 "$WIZ/login" 2>/dev/null)" || die "could not GET $WIZ/login"
  name="$(printf '%s' "$html"  | sed -n 's/.*name="csrf_name" value="\([^"]*\)".*/\1/p' | head -1)"
  value="$(printf '%s' "$html" | sed -n 's/.*name="csrf_value" value="\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$name" ] && [ -n "$value" ] || die "no CSRF pair on /login — the wizard API cannot be driven anonymously"
  # Persistent-token mode: the pair is session-scoped and reused for every POST below.
  code2="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 20 \
    --data-urlencode "password=$pw" \
    --data-urlencode "csrf_name=$name" --data-urlencode "csrf_value=$value" \
    "$WIZ/api/auth/login" 2>/dev/null)" || die "login POST failed at the transport level"
  [ "$code2" = "201" ] || die "wizard login returned $code2 (expected 201) — check $STATE/master.pw"

  # The containers page is a load-bearing step, not eye candy: serving it is where the
  # mastercontainer creates the nextcloud-aio network (ConnectMasterContainerToNetwork,
  # php/public/index.php:97). Every upstream flow — a human browsing the wizard, the Playwright
  # suite (logInToContainersPage, initial-setup.spec.js:8) — loads it right after login, so by
  # the time anyone presses Start the network exists. This API-driven harness skipped it, and
  # the first sibling's start died with "network nextcloud-aio not found" (FINDINGS.md, probe
  # P1, 2026-09-22). It also starts domaincheck (no domain set yet) — upstream first-run
  # behavior, loopback-only via APACHE_IP_BINDING, and the start walk stops it again before
  # apache. One GET, before any configuration POST.
  curl -sk -b "$STATE/cookies" --max-time 15 "$WIZ/containers" -o /dev/null \
    || die "GET /containers failed — the mastercontainer needs it to create the nextcloud-aio network"
  say "containers page visited — the nextcloud-aio network exists"

  wpost /api/configuration "$name" "$value" --data-urlencode "domain=$DOMAIN" --data-urlencode "skip_domain_validation=1"
  say "domain accepted: $DOMAIN (validation skipped — env + posted flag)"
  wpost /api/configuration "$name" "$value" --data-urlencode "timezone=America/Santiago"
  # Options form: ABSENCE is the off-switch (isset semantics). Posting only the form key
  # disables talk/whiteboard/imaginary and leaves office_suite alone — eurooffice is the
  # default upstream and in the suite (D3), so it is never posted.
  wpost /api/configuration "$name" "$value" --data-urlencode "options-form=1"
  say "options saved: talk/whiteboard/imaginary off, office stays eurooffice"

  start_post "$name" "$value"

  say "asserting the container set (bounded 20 min — the POST above already pulled and started everything; this proves it converged)"
  local c all
  all=0
  for i in $(seq 120); do
    all=1
    for c in "$NC" $SIBLINGS; do
      docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c" || { all=0; break; }
    done
    [ "$all" = 1 ] && break
    sleep 10
  done
  [ "$all" = 1 ] || die "the container set never converged within 20 min — start with: docker ps -a --filter name=nextcloud-aio-"

  say "waiting for Nextcloud to finish installing itself (bounded 10 min)"
  local st=""
  for i in $(seq 120); do
    st="$(docker exec --user www-data "$NC" php /var/www/html/occ status --output=json 2>/dev/null || true)"
    case "$st" in *'"installed":true'*) break ;; esac
    sleep 5
  done
  case "$st" in *'"installed":true'*) ;; *) die "occ status never reported installed:true within 10 min (docker logs $NC)" ;; esac

  say "waiting for the config to stop moving (wait-ready pattern, #96)"
  local prev cur settled=0
  prev="$(docker exec --user www-data "$NC" php /var/www/html/occ config:list --output=json 2>/dev/null | sha256sum)"
  for i in $(seq 24); do
    sleep 5
    cur="$(docker exec --user www-data "$NC" php /var/www/html/occ config:list --output=json 2>/dev/null | sha256sum)"
    if [ "$cur" = "$prev" ]; then settled=1; break; fi
    prev="$cur"; printf '~'
  done
  echo
  [ "$settled" = 1 ] || die "Nextcloud's config never stopped changing for 2 minutes after install (#96) — probing now would be a race"

  # Probe state, set ONCE outside any seed (B-018's rule is about a PHASE re-writing the key
  # every run; this is the harness preparing the instance). The suite ships the same posture
  # baked as ENV via patch 020: with the store on, `occ upgrade` re-downloads every enabled app
  # and no VENDOR pin can hold, so seed-idempotent could never converge.
  say "probe state: app store off (the suite bakes this as ENV via patch 020)"
  docker exec --user www-data "$NC" php /var/www/html/occ config:system:set appstoreenabled --value 0 --type integer >/dev/null 2>&1 \
    || die "occ config:system:set appstoreenabled failed"
  local got
  got="$(docker exec --user www-data "$NC" php /var/www/html/occ config:system:get appstoreenabled 2>/dev/null)"
  [ "$got" = "0" ] || die "appstoreenabled reads '$got' after setting 0 — the probe baseline cannot be trusted"

  # Probe state, second key: the skeleton. NC_skeletondirectory="" is the suite's own posture
  # (compose.yaml:90) — AIO's entrypoint only sets the key when NEXTCLOUD_SKELETON_DIRECTORY is
  # forwarded, and containers.json does not forward it, so the admin AIO created during install
  # already carries the vendor's stock files (Nextcloud Manual.pdf, the flyer, ...): exactly
  # what smoke's check 12 exists to catch. Set the key for every FUTURE account, then drop the
  # already-copied files from the throwaway admin home and rescan so the filecache stays honest.
  docker exec --user www-data "$NC" php /var/www/html/occ config:system:set skeletondirectory --value="" >/dev/null 2>&1 \
    || die "occ config:system:set skeletondirectory failed"
  docker exec --user www-data "$NC" sh -c 'rm -rf /mnt/ncdata/admin/files/*' >/dev/null 2>&1 || true
  docker exec --user www-data "$NC" php /var/www/html/occ files:scan admin >/dev/null 2>&1 || true

  # The theme the seed brands with. The suite's image bakes themes/apsconecta in (patch 030,
  # S3); this probe runs the STOCK upstream image — no theme, no bind mount — so the repo's
  # tree is copied in the way the bake will ship it. phase 15's theming_image_set and smoke's
  # checks 7/11 read /var/www/html/themes/apsconecta in-container; without this the phase
  # dies mid-seed on the probe. docker cp, not the seam: this is bring-up, and the harness is
  # deliberately seam-free. The source path resolves through $0 so the harness stays
  # cwd-independent; re-`up` after a theme edit re-copies fresh (up requires the clean slate
  # `down` gives).
  local repo_root
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  [ -d "$repo_root/themes/apsconecta/core" ] \
    || die "no themes/apsconecta/core in this checkout — the probe brands with the repo's theme"
  docker cp "$repo_root/themes/apsconecta" "$NC":/var/www/html/themes/ >/dev/null \
    || die "could not copy themes/apsconecta into $NC — phase 15 and smoke's checks 7/11 need it in-container"
  say "theme seeded: themes/apsconecta -> $NC (the bake's stand-in on a stock image)"

  # The containers page shows the generated Nextcloud admin password once the set is up — kept
  # for manual inspection; automated gates use their own accounts.
  local ncpw
  ncpw="$(curl -sk -b "$STATE/cookies" --max-time 10 "$WIZ/containers" 2>/dev/null | sed -n 's/.*id="initial-nextcloud-password"[^>]*>\([^<]*\)<.*/\1/p' | head -1)"
  if [ -n "$ncpw" ]; then
    printf '%s\n' "$ncpw" > "$STATE/nextcloud.pw"; chmod 600 "$STATE/nextcloud.pw"
    say "nextcloud admin password captured — $STATE/nextcloud.pw (0600)"
  else
    say "NOTE: no initial nextcloud password on /containers (harmless — seeds create their own users)"
  fi

  cmd_gate || die "GATE FAILED — the probe claimed a port it must not claim; inspect with '$0 status'"

  echo
  echo "✓ probe instance up: stock upstream image, store off, container set green"
  echo "    wizard:      $WIZ  (password: $STATE/master.pw)"
  echo "    nextcloud:   http://127.0.0.1:${APACHE_PORT}  (loopback; admin password: $STATE/nextcloud.pw)"
  echo "    occ:         docker exec --user www-data $NC php /var/www/html/occ <command>"
  echo "    teardown:    $0 down"
  echo "  The probe arms (design slices 2-5) drive this instance through docker exec."
}

cmd_status() {
  echo "── containers ──"
  docker ps -a --filter name=nextcloud-aio- --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || say "docker unreachable"
  echo "── published ports ──"
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    docker port "$c" 2>/dev/null | sed "s/^/  $c: /"
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -x 'nextcloud-aio-.*' || true)
  echo "── secrets (paths only) ──"
  ls -l "$STATE"/*.pw 2>/dev/null || say "no secrets in $STATE"
  echo "── gate ──"
  cmd_gate
}

cmd_down() {
  # Scoped by construction: the mastercontainer's fixed name, the project label it stamps on
  # its siblings (com.docker.compose.project=nextcloud-aio), and the nextcloud_aio* volume
  # prefix. Nothing else on any host matches all three. Running `down` IS the confirmation.
  say "removing $MC"
  docker rm -f "$MC" >/dev/null 2>&1 || say "  (not present)"
  say "removing sibling containers (label-scoped)"
  docker ps -aq --filter label=com.docker.compose.project=nextcloud-aio 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  say "removing nextcloud_aio* volumes"
  docker volume ls -q 2>/dev/null | grep -x 'nextcloud_aio.*' | xargs -r docker volume rm >/dev/null 2>&1 || true
  rm -rf "$STATE"
  echo "✓ test bed down — containers, volumes and $STATE removed"
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  gate)   cmd_gate ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 up|down|gate|status" >&2
    echo "  up      preflight (RAM/ports/ghcr) → run → capture password → configure → start → bounded waits → gate" >&2
    echo "  down    remove every nextcloud-aio* container, volume and the state dir" >&2
    echo "  gate    assert only the wizard port and loopback are claimed (can go red)" >&2
    echo "  status  containers, published ports, secret paths" >&2
    exit 1 ;;
esac
