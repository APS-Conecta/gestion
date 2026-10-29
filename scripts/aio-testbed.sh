#!/usr/bin/env bash
# AIO test-bed harness — a disposable All-in-One instance for the installer probe (design slice 1).
#
# WHY THIS EXISTS. Three couplings decide whether every later gate of the installer program can be
# trusted — the docker-exec port, the lock-wins probe, divergence-as-gate — and this org's
# documented defect class is the silent green: BUGS.md B-001…B-007 came from the first bring-up
# that was complete on paper and never run; B-014 was a gate that could not go red; 11 of 19
# handoff claims measured wrong at the 2026-09-13 stand-up (FINDINGS.md). So the couplings are
# proven on a REAL AIO stack — the published suite, no S1 dependency — before anything is
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
# Wizard automation is the CLI's: `host/aps-conecta asistente-aio` drives the same request sequence
# upstream's initial-setup Playwright spec drives, minus the browser — one copy (a6), so Clean boot
# exercises the drive a clinic's silent install uses. This harness owns only what makes the probe
# a probe: the mastercontainer's docker run (SKIP_DOMAIN_VALIDATION, a loopback apache on a high
# port, the fork's suite tag), the probe state the seed expects, and the port gate. The
# RFC-2606 .invalid domain installs without DNS; the domain is immutable afterwards, which a
# disposable instance does not care about.
#
# DELIBERATELY STANDALONE: no scripts/env.sh. Every occ below is the upstream canonical console
# form: `--user www-data` (readme.md:822) — root
# occ trips Nextcloud's console config-owner check and dies mid-flow.
#
# Findings from every run belong in /opt/aps-conecta-org/FINDINGS.md as they happen — recorded,
# not fixed opportunistically (house rule).
#
# Usage:
#   scripts/aio-testbed.sh up        preflight → run mastercontainer → aps-conecta asistente-aio (the CLI's wizard drive) → probe state (store off, skeleton cleared, theme seeded) → gate
#   scripts/aio-testbed.sh down      remove the suite's containers, its volumes and the state dir
#   scripts/aio-testbed.sh gate      assert no non-loopback port outside the wizard is claimed
#   scripts/aio-testbed.sh status    what runs, what it publishes, where the passwords are
#
# Env: AIO_TEST_IMAGE (default the fork's suite tag below), AIO_TEST_PORT (8080), AIO_TEST_APACHE_PORT
# (11000), AIO_TEST_DOMAIN (aio-test.invalid). State: /tmp/aio-testbed/ — secrets 0600, values
# never printed, only their paths.
set -uo pipefail

STATE=/tmp/aio-testbed
MC=nextcloud-aio-mastercontainer            # fixed by Containers/mastercontainer/start.sh:164-170
NC=aps-conecta-nextcloud                   # fixed by the fork's php/containers.json (patch 240)
# The fork's suite, never upstream's: the suite renames the siblings (patch 240), so upstream's
# container names would match none of the suite's. Names the newest suite tag built from this
# tree's image inputs: a release's, moved by the commit after each green Release (RELEASING §4),
# or a rehearsal's while the inputs are ahead of it.
IMAGE="${AIO_TEST_IMAGE:-ghcr.io/aps-conecta/all-in-one:v0.0.0-ci.16}"
WIZARD_PORT="${AIO_TEST_PORT:-8080}"
APACHE_PORT="${AIO_TEST_APACHE_PORT:-11000}"
DOMAIN="${AIO_TEST_DOMAIN:-aio-test.invalid}"
WIZ="https://127.0.0.1:${WIZARD_PORT}"

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

cmd_gate() {
  # gate.sh posture applied to the probe: non-zero exit = STOP. Scoped by name — only
  # the suite's containers are ours to judge, so a production host's own 80/443 listeners
  # are not false alarms. MUST be able to go red (B-014): the negative test plants a labelled
  # fake — docker run -d --name aps-conecta-gate-negative \
  #   --label com.docker.compose.project=nextcloud-aio -p 80:80 nginx — and this command must
  # fail until it is removed.
  local fail=0 seen=0 c line bind pub_pat turn_pat
  pub_pat="*:${WIZARD_PORT}"
  turn_pat="*:${TALK_PORT:-3478}"   # Talk's TURN, published by design when the probe runs Talk (#42)
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    seen=1
    while IFS= read -r line; do
      case "$line" in *" -> "*) ;; *) continue ;; esac   # unpublished ports are not claims
      bind="${line##* -> }"
      case "$bind" in
        127.0.0.1:*|localhost:*|\[::1\]:*) ;;            # loopback: never fights production
        $pub_pat) ;;                                     # the wizard port, by design
        $turn_pat) ;;                                     # Talk's TURN when Talk is on, by design
        *) echo "FAIL: $c publishes $bind — the probe must not claim non-loopback ports"; fail=1 ;;
      esac
    done < <(docker port "$c" 2>/dev/null)
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -xE 'nextcloud-aio-mastercontainer|aps-conecta-.*' || true)
  [ "$seen" = 1 ] || { echo "gate: no suite container running — nothing to check"; return 0; }
  if [ "$fail" = 0 ]; then echo "GATE: PASS — only :${WIZARD_PORT}, Talk's TURN and loopback claimed"; return 0; fi
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
  # 0600 BEFORE content for everything written under $STATE — passwords and the
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
  # NEXTCLOUD_STARTUP_APPS= (empty, explicit — slice 5's ratified forced amendment, and still the
  # probe's own statement now that #67 emptied the default too: the manifest is the only app
  # list, and the env makes the probe's posture independent of the fallback it no longer
  # relies on): empty skips the entrypoint's whole startup loop (its `[ -n "$STARTUP_APPS" ]`
  # gate), so the probe's custom_apps holds only what the seed and the entrypoint's
  # notify_push/eurooffice legs put there — the divergence gate's probe-green criterion
  # depends on it, and zero store legs is the acquisition-gate posture anyway. The
  # mastercontainer's charset validator on this env is `[ -n ]`-gated (start.sh:291-298):
  # empty BYPASSES it, never trips it.
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

  # the wizard drive is the CLI's (one copy, a6): passphrase into $STATE (0600), login, the
  # containers page (it creates the nextcloud-aio network), domain + skip, timezone, options,
  # start with progress, the bounded waits, the Nextcloud admin password into $STATE
  local repo_root
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  # --talk (#145): the probe runs Talk ON — the fork's signed release is the only Talk the
  # suite installs now (ADR-0020), and only an instance with Talk on proves the channel end
  # to end: the fetch leg resolves the release, phase 12 lands it, and the release assert
  # pins the lock. Talk-off is the IP job's world (the store-rules step keeps its absence arm).
  # --respaldo (#54): the daily backup, the step a clinic also walks (INSTALLER §4) — without
  # it there is no backup scope and the #46 actualizar arms red at their own precondition
  # («el respaldo de la instancia no está configurado»), the latent red the v0.0.0-ci.12
  # rehearsal surfaced: this drive, not the install's, is the one that configures the suite
  # (a started wizard is never configured twice).
  mkdir -p "$STATE/respaldos"
  AIO_URL="$WIZ" AIO_STATE="$STATE" bash "$repo_root/host/aps-conecta" asistente-aio \
    --dominio "$DOMAIN" --sin-validar-dominio --talk --respaldo "$STATE/respaldos" \
    || die "the CLI's wizard drive (host/aps-conecta asistente-aio) failed — its ✗ lines above name the step"

  # Probe state, set ONCE outside any seed (B-018's rule is about a PHASE re-writing the key
  # every run; this is the harness preparing the instance). The suite ships the same posture
  # baked as ENV via patch 020: with the store on, `occ upgrade` re-downloads every enabled app
  # and no VENDOR pin can hold, so seed-idempotent could never converge.
  say "probe state: app store off (the suite bakes this as ENV via patch 020)"
  docker exec --user www-data "$NC" php /var/www/html/occ config:system:set appstoreenabled --value 0 --type integer >/dev/null 2>&1 \
    || die "occ config:system:set appstoreenabled failed"
  local got theme
  got="$(docker exec --user www-data "$NC" php /var/www/html/occ config:system:get appstoreenabled 2>/dev/null)"
  [ "$got" = "0" ] || die "appstoreenabled reads '$got' after setting 0 — the probe baseline cannot be trusted"

  # Probe state, second key: the skeleton. NC_skeletondirectory="" is the suite's own posture
  # (phase 15) — AIO's entrypoint only sets the key when NEXTCLOUD_SKELETON_DIRECTORY is
  # forwarded, and containers.json does not forward it, so the admin AIO created during install
  # already carries the vendor's stock files (Nextcloud Manual.pdf, the flyer, ...): exactly
  # what smoke's check 12 exists to catch. Set the key for every FUTURE account, then drop the
  # already-copied files from the throwaway admin home and rescan so the filecache stays honest.
  docker exec --user www-data "$NC" php /var/www/html/occ config:system:set skeletondirectory --value="" >/dev/null 2>&1 \
    || die "occ config:system:set skeletondirectory failed"
  docker exec --user www-data "$NC" sh -c 'rm -rf /mnt/ncdata/admin/files/*' >/dev/null 2>&1 || true
  docker exec --user www-data "$NC" php /var/www/html/occ files:scan admin >/dev/null 2>&1 || true

  # The theme the seed brands with. The suite's image carries themes/apsconecta from the tag
  # tree (the one thing it carries, #42; originally patch 030),
  # S3), from the suite tag it was published with — which may lag this checkout — so the repo's
  # tree is copied over it: the probe brands with the theme under test. phase 15's
  # theming_image_set and smoke's checks 7/11 read /var/www/html/themes/apsconecta in-container;
  # without this the phase dies mid-seed on the probe. docker cp, not the seam: this is bring-up,
  # and the harness is deliberately seam-free. The source path resolves through $0 so the harness
  # stays cwd-independent; re-`up` after a theme edit re-copies fresh (up requires the clean slate
  # `down` gives).
  theme="$repo_root/themes/apsconecta"
  [ -d "$theme/core" ] || die "no themes/apsconecta/core under $repo_root — the probe brands with the suite's theme"
  docker cp "$theme" "$NC":/var/www/html/themes/ >/dev/null \
    || die "could not copy $theme into $NC — phase 15 and smoke's checks 7/11 need it in-container"
  say "theme seeded: ${theme#"$repo_root"/} -> $NC (over the image's own: the checkout's theme is under test)"

  cmd_gate || die "GATE FAILED — the probe claimed a port it must not claim; inspect with '$0 status'"

  echo
  echo "✓ probe instance up: $IMAGE, store off, container set green"
  echo "    wizard:      $WIZ  (password: $STATE/master.pw)"
  echo "    nextcloud:   http://127.0.0.1:${APACHE_PORT}  (loopback; admin password: $STATE/nextcloud.pw)"
  echo "    occ:         docker exec --user www-data $NC php /var/www/html/occ <command>"
  echo "    teardown:    $0 down"
  echo "  The probe arms (design slices 2-5) drive this instance through docker exec."
}

cmd_status() {
  echo "── containers ──"
  docker ps -a --filter name=^aps-conecta- --filter name=^nextcloud-aio-mastercontainer$ --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || say "docker unreachable"
  echo "── published ports ──"
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    docker port "$c" 2>/dev/null | sed "s/^/  $c: /"
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -xE 'nextcloud-aio-mastercontainer|aps-conecta-.*' || true)
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
    echo "  up      preflight (RAM/ports/ghcr) → run → aps-conecta asistente-aio (the wizard drive) → probe state → gate" >&2
    echo "  down    remove the suite's containers, its volumes and the state dir" >&2
    echo "  gate    assert only the wizard port and loopback are claimed (can go red)" >&2
    echo "  status  containers, published ports, secret paths" >&2
    exit 1 ;;
esac
