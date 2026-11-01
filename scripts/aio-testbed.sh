#!/usr/bin/env bash
# Disposable testbed using the installer's by-IP HTTPS path.
# Run with Docker access and the suite ports available.
# AIO_TEST_IMAGE selects the suite tag; APS_HOME moves state and private credentials to its aio/.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -uo pipefail

STATE="${AIO_STATE:-${APS_HOME:+$APS_HOME/aio}}"
STATE="${STATE:-/tmp/aio-testbed}"
MC=nextcloud-aio-mastercontainer            # fixed by Containers/mastercontainer/start.sh:164-170
NC=aps-conecta-nextcloud                   # fixed by the fork's php/containers.json (patch 240)
# The fork's suite, never upstream's: the suite renames the siblings (patch 240), so upstream's
# container names would match none of the suite's. Names the newest suite tag built from this
# tree's image inputs: a release's, moved by the commit after each green Release (RELEASING §4),
# or a rehearsal's while the inputs are ahead of it.
IMAGE="${AIO_TEST_IMAGE:-ghcr.io/aps-conecta/all-in-one:v0.6.0-ci.2032}"
WIZ="https://127.0.0.1:8080"

die() { echo "FATAL: $*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing prerequisite on this host: $1"; }

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
  local c line bind names ports
  names="$(docker ps --format '{{.Names}}')" || return 1
  while IFS= read -r c; do
    case "$c" in nextcloud-aio-mastercontainer|aps-conecta-*) ;; *) continue ;; esac
    ports="$(docker port "$c")" || return 1
    while IFS= read -r line; do
      case "$line" in *" -> "*) ;; *) continue ;; esac
      bind="${line##* -> }"
      case "${line%% -> *} $bind" in
        '8080/tcp '*:8080|'443/tcp '*:443|'443/udp '*:443|'3478/tcp '*:3478|'3478/udp '*:3478) ;;
        *) echo "FAIL: $c publishes $line outside the suite port set" >&2; return 1 ;;
      esac
    done <<<"$ports"
  done <<<"$names"
  echo 'GATE: PASS — suite ports only'
}

cmd_up() {
  need docker; need curl; need awk; need ss; need sed; need ip
  [ -S /var/run/docker.sock ] || die "no /var/run/docker.sock — the mastercontainer requires it (read-only mount)"
  docker inspect "$MC" >/dev/null 2>&1 && die "$MC already exists — run '$0 down' first, or '$0 status' to look"
  mkdir -p "$STATE"; chmod 700 "$STATE"
  # 0600 BEFORE content for everything written under $STATE — passwords and the
  # session cookie alike; the explicit chmods below are assertions, not protection.
  umask 077
  check_ram
  # ghcr reachability, bounded: any HTTP answer — 401 included — proves DNS+TCP+TLS; 000 means
  # the image pulls would hang with no one watching.
  local code
  # curl prints 000 itself when no response arrives; `|| true` only swallows the exit status —
  # `|| echo 000` here would APPEND to it (code="000000") and the die below would never fire.
  code="$(curl -so /dev/null -w '%{http_code}' --max-time 10 https://ghcr.io/v2/ 2>/dev/null || true)"
  [ "$code" != "000" ] || die "https://ghcr.io/v2/ unreachable (bounded 10s) — fix the VM's network before pulling"

  local repo_root domain tag
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  domain="$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  [ -n "$domain" ] || die 'no local IPv4 address found'
  tag="${IMAGE#ghcr.io/aps-conecta/all-in-one:}"
  [[ "$IMAGE" == ghcr.io/aps-conecta/all-in-one:* ]] || die 'AIO_TEST_IMAGE must select a suite image'
  export APS_SUITE_TAG="$tag" AIO_STATE="$STATE"
  bash "$repo_root/host/aps-conecta" preflight --dominio "$domain" || die 'installer preflight failed'
  mkdir -p "$STATE/respaldos"
  # --preparar owns certificate generation and the installed run command.
  bash "$repo_root/host/aps-conecta" asistente-aio --dominio "$domain" \
    --respaldo "$STATE/respaldos" --preparar || die 'installer preparation failed'
  bash "$repo_root/host/aps-conecta" asistente-aio --dominio "$domain" \
    --respaldo "$STATE/respaldos" || die 'installer startup failed'

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
  # (phase 15) — AIO's entrypoint only sets the key when NEXTCLOUD_SKELETON_DIRECTORY is
  # forwarded, and containers.json does not forward it, so the admin AIO created during install
  # already carries the vendor's stock files (Nextcloud Manual.pdf, the flyer, ...): exactly
  # what smoke's check 12 exists to catch. Set the key for every FUTURE account, then drop the
  # already-copied files from the throwaway admin home and rescan so the filecache stays honest.
  docker exec --user www-data "$NC" php /var/www/html/occ config:system:set skeletondirectory --value="" >/dev/null 2>&1 \
    || die "occ config:system:set skeletondirectory failed"
  docker exec --user www-data "$NC" sh -c 'rm -rf /mnt/ncdata/admin/files/*' >/dev/null 2>&1 || true
  docker exec --user www-data "$NC" php /var/www/html/occ files:scan admin >/dev/null 2>&1 || true

  cmd_gate || die "GATE FAILED — the probe claimed a port it must not claim; inspect with '$0 status'"

  echo
  echo "✓ probe instance up: $IMAGE, store off, container set green"
  echo "    Asistente:   $WIZ"
  [ ! -f "$STATE/master.pw" ] || echo "    Contraseña del asistente: $STATE/master.pw"
  echo "    Nextcloud:   https://$domain/  (CA de la suite)"
  [ ! -f "$STATE/nextcloud.pw" ] || echo "    Contraseña del administrador: $STATE/nextcloud.pw"
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
    echo "  gate    assert only the suite ports are claimed (can go red)" >&2
    echo "  status  containers, published ports, secret paths" >&2
    exit 1 ;;
esac
