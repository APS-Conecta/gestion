#!/usr/bin/env bash
# tiles.sh — the basemap's host side (FRD S9): the pmtiles CLI, the archive, and the check that the
# suite serves it.
#
# WHY THIS EXISTS. The basemap is a self-hosted PMTiles archive (territorio ADR-0019): one file, all
# of Chile, read by staff browsers over HTTP Range requests. The suite serves it itself, same origin,
# at /tiles/ — the AIO fork's patch 239: apache's Caddy reads the directory below through a
# read-only bind the mastercontainer makes from APS_TILES_DIR, which «aps-conecta» passes on every
# start. So nothing here runs a server or sets a URL (phase 16 derives territorio's tile_url from
# the address the suite is reached at); this file builds the archive where that bind looks, and
# checks the route the way a browser reads it.
#
# Usage (usually through the bundle: «aps-conecta mapa», step 4, or `aps-conecta tiles …`):
#   tiles.sh install      the CLI and the archive (idempotent; extracts the archive if absent)
#   tiles.sh refresh      re-extract the archive from the newest Protomaps build (the monthly timer)
#   tiles.sh check        the archive, the suite's bind of its directory, a real Range read through it
#   tiles.sh --self-test  the hermetic self-check (PATH shims — no docker, no network)
#
# The install host carries bash, curl and python3 (refresh-basemap.sh's tile math); the check reads
# the suite through docker. Root for the writes under /srv and /usr/local/bin.
set -uo pipefail

HOST_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(cd "$HOST_DIR/.." && pwd)"

# ── the basemap's facts, each pinned where it can be checked ──────────────────────────────────
# OUTSIDE /opt/aps-conecta ON PURPOSE: respaldo wires /opt/aps-conecta into borg's scope,
# and a 1.04 GB regenerable archive must not ride every backup — refresh-basemap.sh rebuilds
# it. FHS /srv: data served by a service. «aps-conecta» binds the same directory into the suite.
TILES_HOME="${TILES_HOME:-/srv/aps-conecta}"
ARCHIVE="$TILES_HOME/tiles/chile.pmtiles"
# The route, read from inside the suite's network: the nextcloud container's curl to apache's
# internal listener — the leg phase 14 and the push server (patch 238) already use. It needs no DNS
# and no CA, so one probe answers for an install by IP and by domain alike.
# PIN (the NGINX_REF discipline, org L5-02): this string is the AIO fork's, not gestion's — the
# listener is Caddy's internal :23973 site block (Containers/apache/Caddyfile), the route is the
# fork's patch 239, the container name the fork's rename patch 240, and the fork's own
# scripts/brand-gate.sh:888-918 pins the family. A fork-side change to the name or the port breaks
# this probe FIRST — read the fork's brand-gate before "fixing" it here.
SUITE_TILES_URL="http://aps-conecta-apache.nextcloud-aio:23973/tiles/chile.pmtiles"
# The pmtiles CLI channel: version + the sha256 the release page PUBLISHES (measured at
# design time — v1.31.2's underscore-form asset; the hyphen form 404s, FINDINGS row).
PMTILES_VERSION="${PMTILES_VERSION:-1.31.2}"
PMTILES_SHA256="${PMTILES_SHA256:-3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f}"
PMTILES_URL="${PMTILES_URL:-https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz}"
PMTILES_BIN="${PMTILES_BIN:-/usr/local/bin/pmtiles}"
# The refresh bound (B-015): the extract is a ~1 GB pull and the inner script's curls are
# v0.2.0's file — consumed, never edited — so the bound wraps FROM OUTSIDE.
REFRESH_TIMEOUT="${REFRESH_TIMEOUT:-5400}"

die() { echo "FATAL: $*" >&2; exit 1; }
ok()  { printf '✓ %s\n' "$*"; }
bad() { printf '✗ %s\n' "$1"; printf '  → %s\n' "$2"; FAIL=1; }
info(){ printf '· %s\n' "$*"; }
FAIL=0

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

# ── the suite's own route, read in ONE exec ────────────────────────────────────────────────
suite_read() {  # sets SR_CODE/SR_SIZE/SR_MAGIC — one docker exec, two curls inside one sh -c
  # (Q4): the ranged read's verdict (code + the exact bytes asked) and the 7-byte magic, one
  # round trip instead of two. Sizes and the fixed ASCII magic, never the archive's bytes
  # themselves, cross the shell (B-036: a real header carries NULs a command substitution drops).
  SR_CODE=""; SR_SIZE=""; SR_MAGIC=""
  read -r SR_CODE SR_SIZE SR_MAGIC < <(docker exec aps-conecta-nextcloud sh -c \
    "curl -sS -m 30 -r 0-1023 -o /dev/null -w '%{http_code} %{size_download} ' '$SUITE_TILES_URL'; \
     curl -sS -m 30 -r 0-6 '$SUITE_TILES_URL'" 2>/dev/null || true)
  return 0  # `read` returns 1 at EOF (no trailing newline from the producers) — the rc is not a verdict
}

build_archive() {  # the extract, bounded (B-015) and pointed at the installer's home; the inner
  # curls are v0.2.0's file, consumed never edited. The directory is world-readable whatever
  # root's umask: apache reads it as uid 33 through the bind.
  install -d -m 0755 "$(dirname "$ARCHIVE")" || die "no pude crear $(dirname "$ARCHIVE")"
  DEST="$ARCHIVE" timeout "$REFRESH_TIMEOUT" bash "$ROOT/scripts/refresh-basemap.sh"
}

serving_read() {  # the deleted serving arm's shape (org L5-01), re-pointed at the suite's own
  # route: the monthly timer is the one SCHEDULED witness of the serving path (review I3) — an
  # archive a browser cannot read is a fresh map nobody serves. Apache not running is the
  # dev-box posture, said and never fatal: the build must not depend on the suite (R47), and the
  # unit's own contract is freshness. A running apache that answers anything but 206-with-magic
  # IS fatal — the serving path is broken while the clinic believes it is fresh.
  if ! docker ps --format '{{.Names}}' >/dev/null 2>&1; then
    info "docker no responde — el mapa quedó instalado; la ruta /tiles/ se revisa con docker en marcha"
    return 0
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aps-conecta-apache; then
    info "la suite no está en marcha — el mapa quedó instalado; la ruta /tiles/ se revisa con la suite iniciada"
    return 0
  fi
  suite_read
  if [ "${SR_CODE:-}" = 206 ] && [ "${SR_SIZE:-}" = 1024 ] && [ "$SR_MAGIC" = PMTiles ]; then
    ok "la suite sirve el mapa recién refrescado por rangos (HTTP 206, 1024 bytes exactos)"
    return 0
  fi
  bad "la suite no sirve el mapa recién refrescado (código ${SR_CODE:-sin respuesta} en /tiles/chile.pmtiles)" \
      "el mapa quedó instalado; revise la montura de la carpeta: sudo bash host/tiles.sh check"
  return 1
}

# ── the arms ──────────────────────────────────────────────────────────────────────────────

cmd_refresh() {  # the monthly arm (the systemd unit's whole job); works standalone too. The
  # build, then the read-back: one SCHEDULED witness of the serving path (review I3). A failed
  # build leaves the serving archive untouched (the script's own atomic swap — its header says so).
  [ $# -eq 0 ] || die "argumento desconocido: $* — uso: tiles.sh refresh (sin argumentos; lo ejecuta el temporizador mensual)"
  build_archive || return 1
  serving_read
}

cmd_install() {  # idempotent; any failed stage re-runs the same command
  [ $# -eq 0 ] || die "argumento desconocido: $* — uso: tiles.sh install (sin argumentos; la URL del mapa la deriva la fase 16 del aprovisionamiento)"
  # the pre-L5 world ran its own nginx on 8084 (aps-conecta-tiles); L5 S3 deleted the creator, so
  # an upgraded clinic keeps a container nothing names anymore — serving the old archive beside
  # the new one, invisible to every tool (review I4). Removed here, idempotently.
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx aps-conecta-tiles; then
    if docker rm -f aps-conecta-tiles >/dev/null 2>&1; then
      ok "contenedor obsoleto aps-conecta-tiles eliminado — la suite sirve /tiles/ ahora"
    else
      bad "no pude eliminar el contenedor obsoleto aps-conecta-tiles" "sudo docker rm -f aps-conecta-tiles"
      return 1
    fi
  fi
  install_cli || return 1
  if [ -f "$ARCHIVE" ]; then
    ok "el mapa ya está ($(du -h "$ARCHIVE" 2>/dev/null | cut -f1)) — el temporizador mensual lo refresca"
    return 0
  fi
  info "el mapa de Chile (~1 GB por rangos HTTP) no está — construyéndolo; tomará unos minutos"
  if ! build_archive; then
    bad "la construcción del mapa falló (el detalle está arriba; un fallo no toca el mapa servido)" \
      "vuelva a ejecutar «sudo aps-conecta mapa»"
    return 1
  fi
  # the claim is earned, not asserted (review I3): at step 4 the suite does not exist yet, and the
  # honest line says what WILL happen; on a live clinic the line is proven through the suite's
  # own route before it prints. Docker down is the builder's own posture, never a red here.
  if ! docker ps --format '{{.Names}}' >/dev/null 2>&1 \
     || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aps-conecta-apache; then
    ok "mapa listo en $ARCHIVE — la suite lo servirá en /tiles/chile.pmtiles al iniciarse"
  else
    suite_read
    if [ "${SR_CODE:-}" = 206 ] && [ "${SR_SIZE:-}" = 1024 ] && [ "$SR_MAGIC" = PMTiles ]; then
      ok "mapa listo en $ARCHIVE — verificado: la suite lo sirve en /tiles/chile.pmtiles"
    else
      bad "el mapa está en $ARCHIVE pero la suite aún no lo sirve (código ${SR_CODE:-sin respuesta} en /tiles/chile.pmtiles)" \
          "la suite debe montar la carpeta del mapa (APS_TILES_DIR); revise: sudo bash host/tiles.sh check"
      return 1
    fi
  fi
  info "el refresco mensual lo activa: sudo aps-conecta temporizadores"
}

cmd_check() {  # the FRD S9 acceptance arm, measured the way a browser reads PMTiles: the archive
  # here, the suite's bind of its directory, and a REAL Range read through the suite's own route.
  # local FAIL: this function's verdict is its OWN — a stale global FAIL (the install arms'
  # reds, or a self-test arm that deliberately planted one) must not make a green check
  # print ✗ (the de-risk's catch: the aggregate inherited an earlier arm's red).
  [ $# -eq 0 ] || die "argumento desconocido: $* — uso: tiles.sh check (sin argumentos)"
  local FAIL=0 served="" mounts
  if [ -f "$ARCHIVE" ]; then
    ok "el mapa está en $ARCHIVE ($(du -h "$ARCHIVE" 2>/dev/null | cut -f1))"
  else
    bad "el mapa aún no está ($ARCHIVE)" "lo construye: sudo aps-conecta mapa"
  fi
  if ! docker ps --format '{{.Names}}' >/dev/null 2>&1; then
    bad "docker no responde" "sudo systemctl start docker — luego re-ejecute la revisión"
  elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aps-conecta-apache; then
    info "la suite no está en marcha: la ruta /tiles/ se revisa con la suite iniciada"
  else
    # the bind (AIO review I1): a mastercontainer started without APS_TILES_DIR gives apache no
    # directory, and /tiles/ is a 404 that no other check names
    mounts="$(docker inspect -f '{{range .Mounts}} {{.Source}}:{{.Destination}}{{end}} ' aps-conecta-apache 2>/dev/null)"
    case "$mounts" in
      *" $(dirname "$ARCHIVE"):/aps-tiles "*) ok "la suite monta $(dirname "$ARCHIVE") en solo lectura" ;;
      *) bad "la suite no monta la carpeta del mapa ($(dirname "$ARCHIVE"))" \
           "se inició sin APS_TILES_DIR: docs/INSTALLER.md §9 indica cómo volver a crear el contenedor maestro" ;;
    esac
    # A REAL Range read (HTTP 206 + EXACTLY the 1024 bytes asked + the archive's magic), fused
    # into one exec (Q4). A server that ignores Range answers 200 with the whole file — and
    # PMTiles reads would quietly download a gigabyte per screenful; 206-with-exact-bytes is
    # the shape the reader needs, so that is the gate.
    suite_read
    if [ "${SR_CODE:-}" = 206 ] && [ "${SR_SIZE:-}" = 1024 ] && [ "$SR_MAGIC" = PMTiles ]; then
      ok "la suite sirve el mapa por rangos (HTTP 206, 1024 bytes exactos — la lectura del navegador)"
      served=" y la suite lo sirve"
    elif [ "${SR_CODE:-}" = 404 ]; then
      bad "la suite responde 404 en /tiles/chile.pmtiles" "el mapa no está en la carpeta que monta la suite: sudo aps-conecta mapa"
    else
      bad "la suite no sirve el mapa por rangos (código ${SR_CODE:-sin respuesta})" "revise: docker logs aps-conecta-apache"
    fi
  fi
  # INFO arm, never a gate: the timer's wiring state.
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled aps-conecta-tiles.timer >/dev/null 2>&1; then
      info "el temporizador mensual está cableado"
    else
      info "el temporizador mensual AÚN NO está activo — lo activa: sudo aps-conecta temporizadores"
    fi
  fi
  if [ "$FAIL" -gt 0 ]; then
    echo "MAPA: ✗ — corrija lo marcado arriba"
    return 1
  fi
  echo "MAPA: ✓ — el mapa está${served}"
}

# ── self-test — PATH shims, planted fixtures, no docker, no network, no host state ──────────
# Every arm proves a real arm of the CLI against a fake world; every plant is reverted
# (the flip-then-revert rule, slice 15's lesson). PMTILES_BIN/ROOT/TILES_HOME knobs redirect
# every write the arms could touch — /usr/local/bin and the real checkout are never in play.

selftest() {
  local n=0 tshim tmp out rc ROOT_BAK="$ROOT" \
        BIN_BAK="$PMTILES_BIN" SHA_BAK="$PMTILES_SHA256" URL_BAK="$PMTILES_URL" HOME_BAK="$TILES_HOME"
  tmp="$(mktemp -d)"; tshim="$tmp/bin"; mkdir -p "$tshim"

  check() {  # NAME COND
    n=$((n + 1))
    if eval "$2"; then :; else echo "  FAIL: $1" >&2; FAILED=$((FAILED + 1)); fi
  }
  FAILED=0

  # A CURATED PATH, not a prepended one: on the dev box a REAL pmtiles lives in
  # /usr/local/bin — a prepended shim dir leaves it visible and the absent-CLI arms
  # short-circuit against the real binary (the de-risk's own catch). The three dirs hold
  # every tool the arms need (stat/grep/sha256sum/tar/install live in /usr/bin:/bin; the
  # pmtiles stub for the present-CLI arm lands in $tshim where PATH sees it first).
  export PATH="$tshim:/usr/sbin:/usr/bin:/bin"
  # the fixture world: a fake ROOT (a stub refresh script), a fake home, a fake bin dir — every
  # knob the arms read is redirected before anything runs
  ROOT="$tmp/repo"; TILES_HOME="$tmp/srv"; PMTILES_BIN="$tmp/bin-installed/pmtiles"
  # ARCHIVE is load-time-derived (from TILES_HOME) — re-derive it HERE or the arms below touch
  # the REAL /srv (the de-risk's own catch: the first run mkdir'd /srv/aps-conecta on the dev
  # box; every knob the arms read must be redirected, DERIVED ones included)
  ARCHIVE="$TILES_HOME/tiles/chile.pmtiles"
  mkdir -p "$ROOT/scripts" "$(dirname "$PMTILES_BIN")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tshim/systemctl"; chmod +x "$tshim/systemctl"

  mk_docker() {  # SCENARIO — the suite as the arms see it: green, nobind (started without
    # APS_TILES_DIR), elsewhere (another directory bound), missing (the bind, no archive: 404), down
    # (no apache), orphan (the pre-L5 nginx container beside the suite), orphanrm (the rm refused),
    # daemon (docker itself dead). Every call is logged, so an arm can assert that nothing but
    # reads ran — and that the teardown's rm ran only in the orphan scenarios.
    local names="aps-conecta-apache" orph="" dead="" rmfail="" \
          mounts=" /x:/usr/local/apache2/htdocs $TILES_HOME/tiles:/aps-tiles " code="206 1024" magic="PMTiles"
    case "$1" in
      nobind)  mounts=" /x:/usr/local/apache2/htdocs "; code="404 0"; magic="" ;;
      elsewhere) mounts=" /srv/otro/tiles:/aps-tiles " ;;
      missing) code="404 0"; magic="" ;;
      down)    names="" ;;
      orphan)  orph="aps-conecta-tiles" ;;
      orphanrm) orph="aps-conecta-tiles"; rmfail="exit 1; " ;;
      daemon)  dead="exit 7; "; names="" ;;
    esac
    cat > "$tshim/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/docker.log"
case "\$*" in
  "ps --format"*) ${dead}printf '%s\n' "$names" ;;
  "ps -a --format"*) ${dead}printf '%s\n' "$orph" ;;
  inspect*) printf '%s\n' "$mounts" ;;
  "rm -f aps-conecta-tiles") ${rmfail}: ;;
  *"exec aps-conecta-nextcloud sh -c"*) printf '%s' "$code $magic" ;;
esac
exit 0
EOF
    chmod +x "$tshim/docker"; : > "$tmp/docker.log"
  }

  mk_curl() {  # the download channel: the fixed -o arm copies the fixture tarball
    cat > "$tshim/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/curl.log"
last=""; dest=""
for a in "\$@"; do [ "\$last" = "-o" ] && dest="\$a"; last="\$a"; done
[ -n "\$dest" ] && cp "$tmp/fixture.tar.gz" "\$dest"
exit 0
EOF
    chmod +x "$tshim/curl"; : > "$tmp/curl.log"
  }

  # the fixture tarball mirrors the REAL channel's shape: the binary named `pmtiles` at the
  # archive root (go-pmtiles_1.31.2 ships LICENSE/README.md/pmtiles — measured). The first
  # draft named it fixture-pmtiles and every download arm reded on the root check.
  mkdir -p "$tmp/fx"
  printf '#!/bin/sh\necho "pmtiles stub"\n' > "$tmp/fx/pmtiles"; chmod +x "$tmp/fx/pmtiles"
  printf 'README stub\n' > "$tmp/fx/README.md"
  ( cd "$tmp/fx" && tar -czf "$tmp/fixture.tar.gz" pmtiles README.md )
  FX_SHA="$(sha256sum "$tmp/fixture.tar.gz" | cut -d' ' -f1)"

  # ── the CLI channel ──
  PMTILES_URL="$tmp/fixture.tar.gz"; PMTILES_SHA256="$FX_SHA"   # the knobs point at the fixture world
  mk_curl
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

  # ── the refresh arm: DEST + the bound ride the call; the directory apache reads is world-readable ──
  cat > "$ROOT/scripts/refresh-basemap.sh" <<EOF
#!/usr/bin/env bash
printf 'DEST=%s\n' "\$DEST" >> "$tmp/refresh.log"
exit "\$(cat "$tmp/refresh.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$ROOT/scripts/refresh-basemap.sh"
  REFRESH_TIMEOUT=7
  mk_docker down
  : > "$tmp/refresh.log"; : > "$tmp/docker.log"
  ( umask 077; cmd_refresh >/dev/null 2>&1 )
  check "refresh: the call carries DEST at the installer home, and the directory is 0755 under root's strictest umask" \
    'grep -q "DEST=$TILES_HOME/tiles/chile.pmtiles" "$tmp/refresh.log" && [ "$(stat -c %a "$TILES_HOME/tiles")" = 755 ]'
  out="$(cmd_refresh 2>&1)"; rc=$?
  check "refresh: with no suite running the serving tail is said and never fatal, and the route is never probed" \
    '[ "$rc" -eq 0 ] && case "$out" in *"· la suite no está en marcha"*"el mapa quedó instalado"*) ;; *) false;; esac && ! grep -q "^exec " "$tmp/docker.log"'
  echo 0 > "$tmp/refresh.rc"
  mk_docker green
  out="$(cmd_refresh 2>&1)"; rc=$?
  check "refresh: after a green build the serving tail proves the suite's route — 206, 1024 bytes, in ONE exec" \
    '[ "$rc" -eq 0 ] && case "$out" in *"✓ la suite sirve el mapa recién refrescado por rangos (HTTP 206, 1024 bytes exactos)"*) ;; *) false;; esac && [ "$(grep -c "^exec aps-conecta-nextcloud sh -c" "$tmp/docker.log")" -eq 1 ]'
  mk_docker missing
  out="$(cmd_refresh 2>&1)"; rc=$?
  check "refresh: a running suite that answers 404 reds the tail — the scheduled witness of the serving path" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ la suite no sirve el mapa recién refrescado"*"sudo bash host/tiles.sh check"*) ;; *) false;; esac'
  rm -f "$tmp/refresh.rc"

  # ── the install arm: absent archive → the refresh fires; present → skipped; a failed build names its fix ──
  printf '%s' "fake" > "$ARCHIVE"; : > "$tmp/refresh.log"; mk_docker down
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: a present archive skips the extract (the refresh log stays empty)" \
    '[ "$rc" -eq 0 ] && [ ! -s "$tmp/refresh.log" ] && case "$out" in *"el mapa ya está"*) ;; *) false;; esac'
  rm -f "$ARCHIVE"
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: an absent archive triggers the bounded refresh, and the archive is where the suite looks" \
    '[ "$rc" -eq 0 ] && [ -s "$tmp/refresh.log" ] && case "$out" in *"construyéndolo"*"/tiles/chile.pmtiles"*) ;; *) false;; esac'
  check "install: with no suite running the claim says what WILL happen — never a serving it cannot prove" \
    'case "$out" in *"mapa listo"*"— la suite lo servirá en /tiles/chile.pmtiles al iniciarse"*) ;; *) false;; esac && case "$out" in *"verificado"*) false;; *) true;; esac'
  echo 1 > "$tmp/refresh.rc"
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: a failed build reds, naming the command that retries it" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ la construcción del mapa falló"*"sudo aps-conecta mapa"*) ;; *) false;; esac'
  rm -f "$tmp/refresh.rc"
  mk_docker green; rm -f "$ARCHIVE"; : > "$tmp/refresh.log"
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: on a running suite the claim is EARNED — the ranged read proven before the line prints" \
    '[ "$rc" -eq 0 ] && case "$out" in *"mapa listo"*"— verificado: la suite lo sirve en /tiles/chile.pmtiles"*) ;; *) false;; esac'
  mk_docker missing; rm -f "$ARCHIVE"
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: a running suite that cannot serve the fresh map reds the claim — never a green lie" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ el mapa está en"*"pero la suite aún no lo sirve"*"tiles.sh check"*) ;; *) false;; esac'
  mk_docker orphan; printf '%s' "fake" > "$ARCHIVE"; : > "$tmp/docker.log"
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: the pre-L5 aps-conecta-tiles container is removed on sight, with its ok line" \
    '[ "$rc" -eq 0 ] && grep -qx "rm -f aps-conecta-tiles" "$tmp/docker.log" && case "$out" in *"✓ contenedor obsoleto aps-conecta-tiles eliminado — la suite sirve /tiles/ ahora"*) ;; *) false;; esac'
  mk_docker orphanrm; : > "$tmp/docker.log"
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: a teardown that cannot remove the orphan reds and stops — the bundle's rc-only gate must see it" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ no pude eliminar el contenedor obsoleto aps-conecta-tiles"*"sudo docker rm -f aps-conecta-tiles"*) ;; *) false;; esac'
  mk_docker down; : > "$tmp/docker.log"
  out="$(cmd_install 2>&1)"; rc=$?
  check "install: with no orphan present nothing is removed — the log carries only reads" \
    '[ "$rc" -eq 0 ] && ! grep -qE "^(rm|run|start|restart|stop) " "$tmp/docker.log"'
  out="$(cmd_install --url https://tiles.example/chile.pmtiles 2>&1)"; rc=$?
  check "install: the old --url invocation is refused, naming the new world — never eaten silently" \
    '[ "$rc" -ne 0 ] && case "$out" in *"FATAL: argumento desconocido: --url"*"sin argumentos"*) ;; *) false;; esac'

  # ── the check arm: the archive, the bind, the ranged read — and nothing but reads ──
  printf '%s' "fake" > "$ARCHIVE"
  mk_docker green
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: archive + bind + a 206 of exactly 1024 bytes with the magic → the PASS line, exit 0" \
    '[ "$rc" -eq 0 ] && case "$out" in *"monta $TILES_HOME/tiles"*"206, 1024 bytes exactos"*"MAPA: ✓ — el mapa está y la suite lo sirve"*) ;; *) false;; esac'
  check "check: the read goes through the suite in ONE exec — both ranges, one round trip, and nothing but reads run" \
    'grep -q "^exec aps-conecta-nextcloud sh -c .*0-1023.*0-6.*aps-conecta-apache.nextcloud-aio:23973/tiles/chile.pmtiles" "$tmp/docker.log" && [ "$(grep -c "^exec " "$tmp/docker.log")" -eq 1 ] && ! grep -qE "^(run|start|restart|rm|stop) " "$tmp/docker.log"'
  mk_docker nobind
  out="$(cmd_check 2>&1)"; rc=$?
  mk_docker elsewhere
  local out2 rc2; out2="$(cmd_check 2>&1)"; rc2=$?
  check "check: a suite started without APS_TILES_DIR, or with another directory, reds by name, with its fix" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ la suite no monta la carpeta del mapa"*"APS_TILES_DIR"*"INSTALLER.md §9"*) ;; *) false;; esac && [ "$rc2" -ne 0 ] && case "$out2" in *"✗ la suite no monta la carpeta del mapa"*) ;; *) false;; esac'
  mk_docker missing
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: a 404 through the bind reds, naming the build" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ la suite responde 404"*"sudo aps-conecta mapa"*) ;; *) false;; esac'
  mk_docker down; rm -f "$ARCHIVE"
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: no archive reds naming the build; a suite not running is said, never probed" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ el mapa aún no está"*"sudo aps-conecta mapa"*"la suite no está en marcha"*) ;; *) false;; esac && ! grep -q "^exec " "$tmp/docker.log"'
  printf '%s' "fake" > "$ARCHIVE"
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: an archive with the suite down passes without claiming the suite serves it" \
    '[ "$rc" -eq 0 ] && case "$out" in *"MAPA: ✓ — el mapa está"*"lo sirve"*) false;; *"MAPA: ✓ — el mapa está"*) ;; *) false;; esac'
  mk_docker daemon
  out="$(cmd_check 2>&1)"; rc=$?
  check "check: a dead docker daemon reds by name, distinct from a stopped suite (Q5)" \
    '[ "$rc" -ne 0 ] && case "$out" in *"✗ docker no responde"*"sudo systemctl start docker"*) ;; *) false;; esac && ! grep -q "^exec " "$tmp/docker.log"'

  ROOT="$ROOT_BAK"; TILES_HOME="$HOME_BAK"; ARCHIVE="$TILES_HOME/tiles/chile.pmtiles"
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
  refresh)     shift; cmd_refresh "$@" ;;
  check)       shift; cmd_check "$@" ;;
  --self-test) selftest ;;
  *) sed -n '2,20p' "$0"; echo; echo "uso: tiles.sh {install|refresh|check|--self-test}" ;;
esac
