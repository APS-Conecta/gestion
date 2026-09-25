#!/usr/bin/env bash
# tiles.sh — the S9 tiles stack installer (FRD S9), the host side of territorio's basemap.
#
# WHY THIS EXISTS. The basemap is a self-hosted PMTiles archive (territorio ADR-0019): one
# file, all of Chile, read by staff browsers over HTTP Range requests. Under the compose
# stack the `tiles` service (compose.yaml:183) serves it; under AIO there is no compose —
# the wizard owns the container set — so this installs the SAME stack outside AIO. Nothing
# heavy is re-implemented: the conf, the extract script and the digest pin are this repo's
# own, mounted or called (this file's fence names each).
#
# THE HONEST PUBLIC-LEG POSTURE (the compose world's own, kept): the container publishes
# LOOPBACK ONLY. TILES_PUBLIC_URL — the address staff BROWSERS use — is a per-install answer:
# the map page is HTTPS and a plain-HTTP tiles URL is mixed content the browser blocks no
# matter what the CSP allows. The working answers are HTTPS terminators proxying to this
# loopback port; INSTALLER.md carries the recipes. With no URL converged, phase 16 writes
# its loopback default and territorio shows its honest «No se pudo cargar el fondo».
#
# Usage (usually through the bundle: `aps-conecta tiles …`):
#   tiles.sh install [--url URL]    install the stack (idempotent; extracts the archive if absent)
#   tiles.sh refresh               re-extract the archive from the newest Protomaps build
#   tiles.sh check                 liveness: /healthz + a real Range read into the archive
#   tiles.sh --self-test           the hermetic self-check (PATH shims — no docker, no network)
#
# The install host carries bash, docker and curl (preflight's own sweep). Root for the
# writes under /srv and /usr/local/bin; the check arm needs nothing.
set -uo pipefail

HOST_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(cd "$HOST_DIR/.." && pwd)"

# ── the stack's facts, each pinned where it can be checked ────────────────────────────────
# OUTSIDE /opt/aps-conecta ON PURPOSE: respaldo wires /opt/aps-conecta into borg's scope,
# and a 1.04 GB regenerable archive must not ride every backup — refresh-basemap.sh rebuilds
# it. FHS /srv: data served by a service.
TILES_HOME="${TILES_HOME:-/srv/aps-conecta}"
ARCHIVE="$TILES_HOME/tiles/chile.pmtiles"
NGINX_NAME=aps-conecta-tiles
TILES_PORT="${TILES_PORT:-8084}"   # the compose world's own default (.env.example:66); phase
                                   # 16's loopback default names the same port — bump both
NGINX_REF="nginx:alpine@sha256:62ff2089abf5a9ed33bd232895bef5e22f7bb4b200675cec49a5ebc48e3d4ac8"
# ^ compose.yaml:191's own pin, same form and same bytes (org L5-02: the "byte-copied" pair had
#   drifted — c8497b18 vs 62ff2089 — and nothing reconciled them because image-digests.sh never
#   scanned this file). scripts/image-digests.sh now carries host/tiles.sh in FILES and rewrites
#   both copies on `make images`, so "bump both" is machine-enforced instead of remembered.
# The pmtiles CLI channel: version + the sha256 the release page PUBLISHES (measured at
# design time — v1.31.2's underscore-form asset; the hyphen form 404s, FINDINGS row).
PMTILES_VERSION="${PMTILES_VERSION:-1.31.2}"
PMTILES_SHA256="${PMTILES_SHA256:-3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f}"
PMTILES_URL="${PMTILES_URL:-https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz}"
PMTILES_BIN="${PMTILES_BIN:-/usr/local/bin/pmtiles}"
# The refresh bound (B-015): the extract is a ~1 GB pull and the inner script's curls are
# v0.2.0's file — consumed, never edited — so the bound wraps FROM OUTSIDE.
REFRESH_TIMEOUT="${REFRESH_TIMEOUT:-5400}"
ENV_FILE="$ROOT/.env"

die() { echo "FATAL: $*" >&2; exit 1; }
ok()  { printf '✓ %s\n' "$*"; }
bad() { printf '✗ %s\n' "$1"; printf '  → %s\n' "$2"; FAIL=1; }
info(){ printf '· %s\n' "$*"; }
FAIL=0

port_free() {  # PORT — the rule-10 discipline, preflight's own idiom
  ss -ltn "sport = :$1" 2>/dev/null | tail -n +2 | grep -q . && return 1
  return 0
}

# ── the pmtiles CLI channel ───────────────────────────────────────────────────────────────

install_cli() {
  if command -v pmtiles >/dev/null 2>&1; then
    ok "pmtiles presente ($(command -v pmtiles)) — el canal de descarga no se abre"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)" || die "no pude crear el directorio de trabajo"
  if ! curl -fsSL --max-time 600 -o "$tmp/pmtiles.tar.gz" "$PMTILES_URL"; then
    rm -rf "$tmp"
    bad "no pude descargar el CLI pmtiles ($PMTILES_URL)" \
        "verifique la red; la versión se cambia con PMTILES_VERSION (y su sha256 publicado)"
    return 1
  fi
  # sha256 ANTES de extraer: un canal que falla la verificación no instala NADA.
  if ! echo "$PMTILES_SHA256  $tmp/pmtiles.tar.gz" | sha256sum --check --status; then
    rm -rf "$tmp"
    bad "el sha256 de pmtiles no coincide — el canal cambió" \
        "re-registre el sha256 que el release de go-pmtiles publica (registrado: $PMTILES_SHA256); no se instaló nada"
    return 1
  fi
  if ! ( cd "$tmp" && tar -xzf pmtiles.tar.gz ); then
    rm -rf "$tmp"
    bad "no pude extraer el tarball de pmtiles" "el detalle llega arriba — el canal cambió de forma"
    return 1
  fi
  if [ ! -f "$tmp/pmtiles" ]; then
    rm -rf "$tmp"
    bad "el tarball no trae el binario «pmtiles» en su raíz" "re-ancore el canal contra el release actual"
    return 1
  fi
  # refuse-to-overwrite (env-init's rule): a binary already at the target is the operator's.
  if [ -e "$PMTILES_BIN" ]; then
    rm -rf "$tmp"
    bad "$PMTILES_BIN ya existe y no lo sobreescribo" "quítelo a mano si quiere esta versión"
    return 1
  fi
  if ! install -m 0755 "$tmp/pmtiles" "$PMTILES_BIN"; then
    rm -rf "$tmp"
    bad "no pude instalar pmtiles en $PMTILES_BIN" "se necesitan permisos de root para /usr/local/bin"
    return 1
  fi
  rm -rf "$tmp"
  ok "pmtiles $PMTILES_VERSION instalado en $PMTILES_BIN (sha256 verificado contra el número que publica el release)"
}

# ── the nginx container ───────────────────────────────────────────────────────────────────

ensure_container() {
  if ! port_free "$TILES_PORT"; then
    local holder
    holder="$(ss -ltnp "sport = :$TILES_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)"
    bad "puerto $TILES_PORT ocupado${holder:+ (pid $holder)}" \
        "libérelo o use TILES_PORT — y refleje el puerto en TILES_PUBLIC_URL"
    return 1
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NGINX_NAME"; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NGINX_NAME"; then
      ok "el contenedor $NGINX_NAME ya corre"
    else
      if docker start "$NGINX_NAME" >/dev/null 2>&1; then
        ok "el contenedor $NGINX_NAME estaba detenido — iniciado"
      else
        bad "no pude iniciar $NGINX_NAME" "«docker logs $NGINX_NAME» nombra la causa"
        return 1
      fi
    fi
    info "si cambió la conf o el digest: docker rm -f $NGINX_NAME && aps-conecta tiles install"
    return 0
  fi
  # The compose service's own shape, translated to docker run: the digest pin (channel
  # checksum), the two read-only mounts, LOOPBACK publish, unless-stopped, and the liveness
  # healthcheck byte-carried from compose.yaml:210-214 — 127.0.0.1 and NOT localhost (the
  # image's busybox wget tries ::1 first and gets refused — measured there; the trap is real
  # enough to carry the address literally here).
  if ! docker run -d --name "$NGINX_NAME" \
      --restart unless-stopped \
      --publish "127.0.0.1:$TILES_PORT:80" \
      --volume "$TILES_HOME/tiles:/srv/tiles:ro" \
      --volume "$ROOT/tiles.nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
      --health-cmd 'wget -q --spider http://127.0.0.1/healthz || exit 1' \
      --health-interval 30s --health-timeout 5s --health-retries 5 --health-start-period 10s \
      "$NGINX_REF" >/dev/null 2>&1; then
    bad "docker run de $NGINX_NAME falló" "el detalle llega arriba; el digest se verifica solo (nginx@sha256:…)"
    return 1
  fi
  ok "contenedor $NGINX_NAME creado (digest de compose.yaml, conf montada, 127.0.0.1:$TILES_PORT)"
}

# ── the TILES_PUBLIC_URL convergence (slice 16's routed bullet) ───────────────────────────

converge_url() {  # [URL] — the .env key phase 16 reads (16-app-policy.sh:35). The .env is
  # the ONLY carrier the seed reads (env.sh's loader overwrites exported vars — slice 16's
  # locked finding), so the convergence is a WRITE. The executor's env_converge is NOT
  # extended: its surgical rule is line-scoped to SITE/SEED_FIXTURES/FIXTURE_USER_PASSWORD,
  # this writer is line-scoped to TILES_PUBLIC_URL — disjoint keys, order-independent
  # BY CONSTRUCTION (env_converge's surgical rule is slice 16's lock; the provisionador-side
  # both-orders run rides slice 16's own self-test at implement time). env-init's discipline:
  # refuse-if-different naming both values (the URL is not a secret — printing it is
  # correct), create-if-absent 0600-before-content via umask.
  local url="${1:-${TILES_PUBLIC_URL:-}}"
  if [ -z "$url" ]; then
    info "sin TILES_PUBLIC_URL: fase 16 escribirá su valor local por defecto — territorio mostrará su aviso honesto hasta que converja una URL pública (INSTALADOR: un terminador HTTPS hacia 127.0.0.1:$TILES_PORT)"
    return 0
  fi
  local cur
  cur="$(grep -m1 '^TILES_PUBLIC_URL=' "$ENV_FILE" 2>/dev/null | sed 's/^TILES_PUBLIC_URL=//; s/^"//; s/"$//' || true)"
  if [ -z "$cur" ]; then
    if [ -f "$ENV_FILE" ]; then
      printf 'TILES_PUBLIC_URL=%s\n' "$url" >> "$ENV_FILE" \
        || { bad "no pude escribir TILES_PUBLIC_URL en $ENV_FILE" "permisos del checkout"; return 1; }
      ok "TILES_PUBLIC_URL agregado a .env (la próxima re-provisión — la semanal — lo converge en territorio)"
    else
      ( umask 077; printf 'TILES_PUBLIC_URL=%s\n' "$url" > "$ENV_FILE" ) \
        || { bad "no pude crear $ENV_FILE" "permisos del checkout"; return 1; }
      ok ".env creado (0600) con TILES_PUBLIC_URL — el provisionador completará SITE y las demás claves"
    fi
  elif [ "$cur" = "$url" ]; then
    ok "TILES_PUBLIC_URL ya converge («$url»)"
  else
    bad "TILES_PUBLIC_URL ya tiene otro valor («$cur»); no piso el nuevo («$url»)" \
        "corríjalo a mano en .env — este comando no sobreescribe una decisión tomada (la regla de env-init)"
    return 1
  fi
}

# ── the arms ──────────────────────────────────────────────────────────────────────────────

cmd_refresh() {  # the monthly arm (the systemd unit's whole job); works standalone too
  # DEST pointed at the installer's home; the bound wraps from outside (B-015 — the inner
  # curls are v0.2.0's file, consumed never edited). A failed run leaves the serving
  # archive untouched (the script's own atomic swap — its header says so).
  mkdir -p "$(dirname "$ARCHIVE")" || die "no pude crear $(dirname "$ARCHIVE")"
  DEST="$ARCHIVE" timeout "$REFRESH_TIMEOUT" bash "$ROOT/scripts/refresh-basemap.sh"
}

cmd_install() {  # [--url URL] — idempotent; any failed stage re-runs the same command
  local url=""
  if [ "${1:-}" = "--url" ]; then
    [ -n "${2:-}" ] || die "--url necesita la URL pública del fondo (ej.: https://tiles.su-dominio.cl/chile.pmtiles)"
    url="$2"
  fi
  # 1. the CLI channel (a present binary short-circuits it — no download)
  install_cli || FAIL=1
  # 2. the container (port check first — a busy port names its holder)
  ensure_container || FAIL=1
  # 3. the URL convergence (instant — lands even if the operator Ctrl-C's the extract)
  converge_url "$url" || FAIL=1
  # 4. the timer wiring: PRINTED, never executed (the run-command generator's own
  #    doctrine — the operator pastes; INSTALLER.md owns the full walkthrough)
  echo
  info "el refresco mensual vive del temporizador systemd — cablee así (INSTALADOR.md documenta cada pieza):"
  printf '  sudo cp %s/aps-conecta-tiles.service %s/aps-conecta-tiles.timer /etc/systemd/system/\n' "$HOST_DIR" "$HOST_DIR"
  printf '  sudo systemctl daemon-reload && sudo systemctl enable --now aps-conecta-tiles.timer\n'
  # 5. the archive — the long pole LAST, so everything above already landed. The extract
  #    is ~1 GB by HTTP ranges; a Ctrl-C leaves a consistent state (container + CLI + .env)
  #    and the re-run skips straight back here.
  if [ -f "$ARCHIVE" ]; then
    ok "el fondo ya está ($(du -h "$ARCHIVE" 2>/dev/null | cut -f1) — el temporizador lo refresca mensualmente)"
  else
    info "el fondo de mapa (~1 GB por rangos HTTP) no está — construyéndolo; tomará unos minutos"
    cmd_refresh || bad "la extracción del fondo falló (el detalle llega arriba — un fallo no toca nada servido)" \
      "re-ejecute «aps-conecta tiles refresh» cuando quiera reintentarlo"
  fi
  # 6. liveness — the exit is the aggregate (preflight's shape): the check's own rc OR
  # any earlier arm's red (cmd_check's FAIL is local — this is where the two halves meet)
  echo
  local crc
  cmd_check; crc=$?
  [ "$FAIL" -gt 0 ] && return 1
  return "$crc"
}

cmd_check() {  # the FRD S9 acceptance arm: tiles endpoint liveness, measured the way a
  # browser reads PMTiles — /healthz for the server, a REAL Range request for the archive.
  # local FAIL: this function's verdict is its OWN — a stale global FAIL (the install arms'
  # reds, or a self-test arm that deliberately planted one) must not make a green check
  # print ✗ (the de-risk's catch: the aggregate inherited an earlier arm's red).
  local FAIL=0
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NGINX_NAME"; then
    ok "el contenedor $NGINX_NAME corre"
  else
    bad "el contenedor $NGINX_NAME no corre" "«aps-conecta tiles install» levanta el nginx"
  fi
  local body
  body="$(curl -fsS -m 10 "http://127.0.0.1:$TILES_PORT/healthz" 2>/dev/null)" \
    && [ "$body" = "ok" ] \
    && ok "healthz responde («ok»)" \
    || bad "healthz no responde en 127.0.0.1:$TILES_PORT" "«aps-conecta tiles install» levanta el nginx; el puerto se cambia con TILES_PORT"
  # A REAL Range read: HTTP 206 + EXACTLY the 1024 bytes asked. A server that ignores Range
  # answers 200 with the whole file — and PMTiles reads would quietly download a gigabyte
  # per screenful; 206-with-exact-bytes is the shape the reader needs, so that is the gate.
  local out code n
  out="$(curl -sS -m 30 -r 0-1023 -o - -w '%{http_code}' "http://127.0.0.1:$TILES_PORT/chile.pmtiles" 2>/dev/null || true)"
  n="${#out}"
  if [ "$n" -lt 3 ]; then code=""; else code="${out: -3}"; fi
  if [ "$code" = "206" ] && [ "$n" -eq 1027 ]; then
    ok "el fondo responde por rangos (HTTP 206, 1024 bytes exactos — la lectura del navegador)"
  elif [ "$code" = "404" ]; then
    bad "el fondo aún no está (HTTP 404 en /chile.pmtiles)" "«aps-conecta tiles refresh» lo construye — el nginx ya sirve"
  else
    bad "el fondo no responde por rangos (código ${code:-sin respuesta})" "«aps-conecta tiles install» publica el puerto; «refresh» construye el fondo"
  fi
  # INFO arms, never gates: the timer's wiring state and the public-URL posture.
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled aps-conecta-tiles.timer >/dev/null 2>&1; then
      info "el temporizador mensual está cableado"
    else
      info "el temporizador mensual AÚN NO está cableado — los comandos están en la salida de «install»"
    fi
  fi
  if grep -q '^TILES_PUBLIC_URL=' "$ENV_FILE" 2>/dev/null; then
    info "TILES_PUBLIC_URL converge en .env — la re-provisión semanal lo escribe en territorio"
  else
    info "sin TILES_PUBLIC_URL — territorio usará su valor local por defecto (el aviso honesto)"
  fi
  if [ "$FAIL" -gt 0 ]; then
    echo "FONDO DE MAPA: ✗ — corrija lo marcado arriba"
    return 1
  fi
  echo "FONDO DE MAPA: ✓ — el servidor y el fondo responden"
}

# ── self-test — PATH shims, planted fixtures, no docker, no network, no host state ──────────
# Every arm proves a real arm of the CLI against a fake world; every plant is reverted
# (the flip-then-revert rule, slice 15's lesson). PMTILES_BIN/ROOT/TILES_HOME knobs redirect
# every write the arms could touch — /usr/local/bin and the real checkout are never in play.

selftest() {
  local n=0 tshim tmp ROOT_BAK="$ROOT" PORT_BAK="$TILES_PORT" \
        BIN_BAK="$PMTILES_BIN" SHA_BAK="$PMTILES_SHA256" URL_BAK="$PMTILES_URL" HOME_BAK="$TILES_HOME"
  tmp="$(mktemp -d)"; tshim="$tmp/bin"; mkdir -p "$tshim"

  check() {  # NAME COND
    n=$((n + 1))
    if eval "$2"; then :; else echo "  FAIL: $1" >&2; FAILED=$((FAILED + 1)); fi
  }
  FAILED=0

  # A CURATED PATH, not a prepended one: on the dev box a REAL pmtiles lives in
  # /usr/local/bin — a prepended shim dir leaves it visible and the absent-CLI arms
  # short-circuit against the real binary (the de-risk's own catch). The four dirs are
  # every tool the arms need (ss/stat/grep/sha256sum/tar live in /usr/bin:/bin; the
  # pmtiles stub for the present-CLI arm lands in $tshim where PATH sees it first).
  export PATH="$tshim:/usr/sbin:/usr/bin:/bin"
  # the fixture world: a fake ROOT (the .env, the conf, a stub refresh script), a fake home,
  # a fake bin dir — every knob the arms read is redirected before anything runs
  ROOT="$tmp/repo"; TILES_HOME="$tmp/srv"; PMTILES_BIN="$tmp/bin-installed/pmtiles"
  # ARCHIVE and ENV_FILE are load-time-derived (from TILES_HOME and ROOT) — re-derive
  # them HERE or the arms below touch the REAL /srv and the REAL checkout's .env (the
  # de-risk's own catch: the first run mkdir'd /srv/aps-conecta on the dev box; every knob
  # the arms read must be redirected, DERIVED ones included)
  ARCHIVE="$TILES_HOME/tiles/chile.pmtiles"
  ENV_FILE="$ROOT/.env"
  mkdir -p "$ROOT" "$TILES_HOME/tiles" "$(dirname "$PMTILES_BIN")"
  # org L5-02: the pin-pair check reads compose.yaml from the fixture ROOT — stage the REAL
  # one (small, committed) so the self-test asserts the pair as shipped, not a stub.
  cp "$ROOT_BAK/compose.yaml" "$ROOT/compose.yaml"
  printf '# server block fixture — the conf is a mount, its bytes are compose.yaml world\n' > "$ROOT/tiles.nginx.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tshim/ss";   chmod +x "$tshim/ss"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tshim/systemctl"; chmod +x "$tshim/systemctl"

  mk_docker() {  # [ps-names] [ps-a-names] — the #143 argv-logging stub, state via args
    cat > "$tshim/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/docker.log"
case "\$1 \$2" in
  "ps -a") printf '%s' "${2-}"; exit 0 ;;
  "ps --format") printf '%s' "${1-}"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$tshim/docker"
    : > "$tmp/docker.log"
  }

  mk_curl() {  # SCENARIO — one fake world per arm (the per-arm shim lesson). The shim
    # answers by its OWN argv shape — the URL, the -r flag, the -o flag — NEVER by a
    # template-time variable: the first draft keyed the case on ${1:-}, which expanded
    # to the SCENARIO name at template time and the shim then matched nothing (the
    # de-risk's own catch: every arm silently fell through to the * arm).
    local healthz="exit 0" range="exit 0"
    case "$1" in
      green)   healthz="printf 'ok\n'"; range="head -c 1024 /dev/zero | tr '\0' 'x'; printf '206'" ;;
      missing) healthz="printf 'ok\n'"; range="printf '404'" ;;
      dead)    healthz="exit 7"; range="exit 7" ;;
      download) ;;   # the fixed -o arm below; healthz/range stay inert
    esac
    cat > "$tshim/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/curl.log"
case "\$*" in
  *healthz*) $healthz ;;
  *"-r 0-1023"*) $range ;;
  *"-o "*)
    last=""; dest=""
    for a in "\$@"; do [ "\$last" = "-o" ] && dest="\$a"; last="\$a"; done
    cp "$tmp/fixture.tar.gz" "\$dest" ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$tshim/curl"
    : > "$tmp/curl.log"
  }

  # the fixture tarball: a REAL tar.gz with a runnable pmtiles stub at its root — the
  # extraction step is exercised for real, only the bytes are small
  # the fixture tarball mirrors the REAL channel's shape: the binary named `pmtiles` at the
  # archive root (go-pmtiles_1.31.2 ships LICENSE/README.md/pmtiles — measured). The first
  # draft named it fixture-pmtiles and every download arm reded on the root check.
  mkdir -p "$tmp/fx"
  printf '#!/bin/sh\necho "pmtiles stub"\n' > "$tmp/fx/pmtiles"; chmod +x "$tmp/fx/pmtiles"
  printf 'README stub\n' > "$tmp/fx/README.md"
  ( cd "$tmp/fx" && tar -czf "$tmp/fixture.tar.gz" pmtiles README.md )
  FX_SHA="$(sha256sum "$tmp/fixture.tar.gz" | cut -d' ' -f1)"

  # ── the container arm: the exact docker run argv ──
  mk_docker "" ""; mk_curl green
  : > "$tmp/docker.log"
  ensure_container
  check "container: the run argv carries the digest pin, the loopback publish, both mounts, unless-stopped and the compose healthcheck" \
    'grep -q -- "--restart unless-stopped" "$tmp/docker.log" \
     && grep -q -- "--publish 127.0.0.1:$TILES_PORT:80" "$tmp/docker.log" \
     && grep -qF -- "$NGINX_REF" "$tmp/docker.log" \
     && grep -qF -- "--volume $TILES_HOME/tiles:/srv/tiles:ro" "$tmp/docker.log" \
     && grep -qF -- "--volume $ROOT/tiles.nginx.conf:/etc/nginx/conf.d/default.conf:ro" "$tmp/docker.log" \
     && grep -qF -- "--health-cmd wget -q --spider http://127.0.0.1/healthz || exit 1" "$tmp/docker.log"'

  # org L5-02: the pair itself. The argv assert above proves the wiring ($NGINX_REF reaches
  # docker run); this proves the two files still agree — the drift image-digests.sh now owns,
  # asserted here so a local selftest catches it without the registry round-trip.
  check "pin pair: tiles.sh and compose.yaml carry the same nginx ref" \
    "grep -qF -- \"$NGINX_REF\" \"$ROOT/compose.yaml\""

  # idempotence: a running container means NO second run (the argv log proves it — the ps
  # probes log too, so the assert is "no run/start line", never "an empty log")
  mk_docker "$NGINX_NAME" "$NGINX_NAME"; : > "$tmp/docker.log"
  local out; out="$(ensure_container)"
  check "container: a running container is the no-op — no docker run fired" \
    '! grep -q "^run " "$tmp/docker.log" && ! grep -q "^start " "$tmp/docker.log" \
     && case "$out" in *"ya corre"*) ;; *) false;; esac'
  # stopped-but-present → docker start
  mk_docker "" "$NGINX_NAME"; : > "$tmp/docker.log"
  out="$(ensure_container)"
  check "container: a stopped container is started, never re-created" \
    'grep -q "^start $NGINX_NAME$" "$tmp/docker.log" && ! grep -q "^run " "$tmp/docker.log"'

  # the port busy by a stranger reds naming the fix (the preflight discipline)
  printf '#!/usr/bin/env bash\n[ "$2" = "sport = :%s" ] && { echo "State Recv-Q"; echo "LISTEN 0 0 *:%s"; exit 0; }\nexit 0\n' "$TILES_PORT" "$TILES_PORT" > "$tshim/ss"
  chmod +x "$tshim/ss"
  out="$(ensure_container 2>&1)"; local rc=$?
  check "container: a busy port reds with the fix hint, no docker run" \
    '[ "$rc" -ne 0 ] && case "$out" in *"puerto $TILES_PORT ocupado"*) ;; *) false;; esac'
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tshim/ss"; chmod +x "$tshim/ss"

  # ── the CLI channel ──
  PMTILES_URL="$tmp/fixture.tar.gz"; PMTILES_SHA256="$FX_SHA"   # the knobs point at the fixture world
  mk_curl download
  install_cli >/dev/null
  check "cli: the absent CLI is downloaded, sha-verified, extracted and installed 0755" \
    '[ -x "$PMTILES_BIN" ] && "$PMTILES_BIN" | grep -q "pmtiles stub"'
  # the wrong sha installs NOTHING (never-install-unverified) — plant, prove, revert
  PMTILES_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  rm -f "$PMTILES_BIN"
  install_cli >/dev/null 2>&1; rc=$?
  check "cli: a sha mismatch reds and installs nothing" \
    '[ "$rc" -ne 0 ] && [ ! -e "$PMTILES_BIN" ]'
  PMTILES_SHA256="$FX_SHA"   # revert (flip-then-revert)
  # a present CLI short-circuits the channel — zero curl calls
  printf '#!/usr/bin/env bash\necho "pmtiles present stub"\n' > "$tshim/pmtiles"; chmod +x "$tshim/pmtiles"
  : > "$tmp/curl.log"
  out="$(install_cli)"
  check "cli: a present pmtiles on PATH opens no download channel" \
    '[ ! -s "$tmp/curl.log" ] && case "$out" in *"canal de descarga no se abre"*) ;; *) false;; esac'

  # ── the .env convergence — every arm against the REAL function ──
  rm -f "$ENV_FILE"
  converge_url "https://tiles.example.cl/chile.pmtiles" >/dev/null
  check "env: absent .env is created 0600 with the URL line" \
    '[ "$(stat -c %a "$ENV_FILE")" = "600" ] && grep -q "^TILES_PUBLIC_URL=https://tiles.example.cl/chile.pmtiles$" "$ENV_FILE"'
  # append: an existing .env with other keys gains the line, others byte-identical
  rm -f "$ENV_FILE"; printf 'SITE=113314\nSEED_FIXTURES=1\n' > "$ENV_FILE"; chmod 600 "$ENV_FILE"
  converge_url "https://tiles.example.cl/chile.pmtiles" >/dev/null
  check "env: the key is appended to an existing .env, the other lines byte-identical" \
    'head -2 "$ENV_FILE" | grep -qx "SITE=113314" && tail -1 "$ENV_FILE" | grep -q "^TILES_PUBLIC_URL="'
  # same value → the untouched no-op (mtime-stable, the env_converge shape)
  local mt; mt="$(stat -c %Y "$ENV_FILE")"
  converge_url "https://tiles.example.cl/chile.pmtiles" >/dev/null
  check "env: the same value is the byte- and mtime-stable no-op" \
    '[ "$(stat -c %Y "$ENV_FILE")" = "$mt" ] && [ "$(grep -c TILES_PUBLIC_URL "$ENV_FILE")" = 1 ]'
  # different value → refuse, file untouched — plant, prove, revert
  mt="$(stat -c %Y "$ENV_FILE")"
  out="$(converge_url "https://otro.example.cl/chile.pmtiles" 2>&1)"; rc=$?
  check "env: a different value is refused naming both values, the file untouched" \
    '[ "$rc" -ne 0 ] && [ "$(stat -c %Y "$ENV_FILE")" = "$mt" ] \
     && printf "%s" "$out" | grep -q "otro.example.cl" \
     && printf "%s" "$out" | grep -q "tiles.example.cl"'
  # absent URL → the honest INFO, never a write
  rm -f "$ENV_FILE"
  out="$(converge_url "" 2>&1)"
  check "env: no URL given answers the honest default posture and writes nothing" \
    '[ ! -e "$ENV_FILE" ] && case "$out" in *"sin TILES_PUBLIC_URL"*) ;; *) false;; esac'

  # ── the refresh arm: DEST + the bound ride the call ──
  mkdir -p "$ROOT/scripts"
  cat > "$ROOT/scripts/refresh-basemap.sh" <<EOF
#!/usr/bin/env bash
printf 'DEST=%s\n' "\$DEST" >> "$tmp/refresh.log"
exit 0
EOF
  chmod +x "$ROOT/scripts/refresh-basemap.sh"
  REFRESH_TIMEOUT=7
  : > "$tmp/refresh.log"
  cmd_refresh >/dev/null 2>&1
  check "refresh: the call carries DEST pointed at the installer home (bounded by timeout)" \
    'grep -q "DEST=$TILES_HOME/tiles/chile.pmtiles" "$tmp/refresh.log"'

  # ── the check arm: liveness both ways ──
  mk_docker "$NGINX_NAME" ""; mk_curl green
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: healthz + the 206 Range read + the container → the PASS line, exit 0" \
    '[ "$rc" -eq 0 ] && case "$out" in *"206, 1024 bytes exactos"*"FONDO DE MAPA: ✓"*) ;; *) false;; esac'
  mk_docker "$NGINX_NAME" ""; mk_curl missing
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: a missing archive (404) reds naming the refresh fix, the server still reported" \
    '[ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "HTTP 404" \
     && printf "%s" "$out" | grep -q "tiles refresh" \
     && printf "%s" "$out" | grep -q "healthz responde"'
  mk_docker "$NGINX_NAME" ""; mk_curl dead
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: a dead endpoint reds with the port and the install fix hint" \
    '[ "$rc" -ne 0 ] && case "$out" in *"healthz no responde"*"tiles install"*) ;; *) false;; esac'

  # ── the extract-at-install arm: absent archive → the refresh fires; present → skipped ──
  mk_docker "" ""; mk_curl green
  : > "$tmp/refresh.log"
  printf '%s' "fake" > "$TILES_HOME/tiles/chile.pmtiles"
  local ilog; ilog="$(cmd_install 2>&1)"
  check "install: a present archive skips the extract (the refresh log stays empty)" \
    '[ ! -s "$tmp/refresh.log" ] && case "$ilog" in *"el fondo ya está"*) ;; *) false;; esac'
  rm -f "$TILES_HOME/tiles/chile.pmtiles"
  ilog="$(cmd_install 2>&1)"
  check "install: an absent archive triggers the bounded refresh" \
    '[ -s "$tmp/refresh.log" ] && case "$ilog" in *"no está — construyéndolo"*) ;; *) false;; esac'

  ROOT="$ROOT_BAK"; TILES_HOME="$HOME_BAK"; ARCHIVE="$TILES_HOME/tiles/chile.pmtiles"
  ENV_FILE="$ROOT/.env"
  PMTILES_BIN="$BIN_BAK"; PMTILES_SHA256="$SHA_BAK"; PMTILES_URL="$URL_BAK"
  rm -rf "$tmp"
  echo
  echo "self-test: $n checks OK"
  [ "$FAILED" -eq 0 ] || { echo "self-test: $FAILED FAILED" >&2; exit 1; }
  return 0
}

# ── dispatch ──────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
  install)     shift; cmd_install "$@" ;;
  refresh)     cmd_refresh ;;
  check)       cmd_check ;;
  --self-test) selftest ;;
  *) sed -n '2,25p' "$0"; echo; echo "uso: tiles.sh {install [--url URL]|refresh|check|--self-test}" ;;
esac
