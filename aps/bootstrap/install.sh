#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Bootstrap. The operator runs it as the one command:
#   curl -fsSL https://github.com/APS-Conecta/gestion/releases/latest/download/apsconecta-install.sh | sudo bash
#
# Order: check the server without changing it; install Docker Engine when it is missing; set the kernel settings
# Redis and Elasticsearch need; pull our mastercontainer by the release's digest, tag it as the channel tag and start
# it as vanilla's documented command does, with the server's address (and, for a test build, the CAs its suite trusts:
# AIO's NEXTCLOUD_TRUSTED_CACERTS_DIR); print the link block it logs (ADR-0027), then exit. The mastercontainer runs
# on its own, so closing SSH never stops the install. A rerun reads «Listo» before it starts anything. Before «Listo» it
# restarts the mastercontainer, stopped or running, and prints its fresh link, and the links before keep working; after
# «Listo» it changes nothing, so a stopped mastercontainer stays stopped, and prints the suite's address. The same
# command with one argument, after a typed confirmation, frees the establishment's APS name, then removes what the
# install created, its nightly backup included, and leaves Docker installed:
#   curl -fsSL https://github.com/APS-Conecta/gestion/releases/latest/download/apsconecta-install.sh | sudo bash -s restablecer
#
# The release pipeline fills RELEASE_TAG, MASTERCONTAINER and a test build's TRUSTED_CACERTS (aps/release/bootstrap.sh);
# the committed copy refuses to run. Everything runs inside main, so a truncated download never runs half a script.
set -euo pipefail

RELEASE_TAG=""
# Our mastercontainer by the release's digest: ghcr.io/aps-conecta/all-in-one@sha256:…
MASTERCONTAINER=""
CHANNEL="${MASTERCONTAINER%@*}:latest"  # the channel tag (aps/RELEASING.md), which the Nightly update moves
# A test build's: the CAs its suite trusts for its own server-side calls, base64: Let's Encrypt's staging roots, which
# its certificates come from. A release's carries none.
TRUSTED_CACERTS=""

# The hardware minimum: the old installer's memory and disk floors, until #300 measures the suite's.
MIN_MEMORY_GIB=6
MIN_DISK_GB=20
# Talk's recording threshold: a server with at least these cores, and this memory rounded as the floor's, records Talk
# calls. The Provisionador reads it here (provisionador/steps/components.py). Until #300 measures it: the memory floor
# and the acceptance VM's 2 cores, plus one recording's 2 cores and 2 GiB browser (nextcloud-talk-recording's
# «Hardware requirements»).
RECORDING_MIN_CPUS=4
RECORDING_MIN_MEMORY_GIB=8
# What AIO publishes on the host (php/containers.json): Apache's 443, Talk's 3478 and the interface's 8080.
PORTS="tcp/443 udp/443 tcp/3478 udp/3478 tcp/8080"
CONTAINER=nextcloud-aio-mastercontainer
VOLUME=nextcloud_aio_mastercontainer:/mnt/docker-aio-config       # its volume, where vanilla's command mounts it
LISTO=/mnt/docker-aio-config/provisionador/listo                  # «Listo», in the mastercontainer's volume
NAME_CREDENTIAL=/mnt/docker-aio-config/provisionador/aps-name.json  # the APS name's, once «Dirección» claimed it
AIO_CONFIGURATION=/mnt/docker-aio-config/data/configuration.json  # AIO's own: its domain, once one is set
PROVISIONADOR=/var/www/docker-aio/aps/provisionador/provisionador.py  # in the mastercontainer's image
DROP_IN=/etc/sysctl.d/90-apsconecta-gestion.conf
ROUTE=/data/coolify/proxy/dynamic/nextcloud-aio.yaml  # the suite's route in Coolify's proxy (provisionador/suite.py)
BACKUPS=/var/backups/apsconecta-gestion  # AIO's nightly backup, as «Instalar» sets it (provisionador/steps/backups.py)
# The first and the last line of the link block the Provisionador logs: LINK_LOG in aps/provisionador/provisionador.py.
LINK_FIRST="Abra este enlace"
LINK_LAST="El enlace sirve hasta «Listo»."
CONFIRMATION=ELIMINAR
ONE_COMMAND="curl -fsSL https://github.com/APS-Conecta/gestion/releases/latest/download/apsconecta-install.sh | sudo bash"
# The host files the checks read, and the folder a test build's CAs go to; the static gate's tests point them at
# fixtures (aps/bootstrap/test_install.py).
MEMINFO="${MEMINFO:-/proc/meminfo}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
FUSE_DEVICE="${FUSE_DEVICE:-/dev/fuse}"
CACERTS="${CACERTS:-/etc/ssl/apsconecta-gestion}"

die() { printf '\nError: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
now() { date -u +%Y-%m-%dT%H:%M:%S.%NZ; }

# A field of the server's os-release, which is shell assignments by design.
# shellcheck source=/dev/null
os() { (. "$OS_RELEASE" && printf '%s' "${!1:-}"); }

# The address other machines on the network reach this server by: the source of its default route.
server_address() {
  ip -4 route get 192.0.2.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'  # TEST-NET-1: a route lookup only
}

check_host() {
  local gaps=() arch memory_gib disk_dir=/var/lib disk_gb listening spec protocol
  arch="$(uname -m)"
  [ "$arch" = x86_64 ] || gaps+=("la arquitectura del procesador es $arch; se requiere x86_64")
  memory_gib=$(( ($(awk '/^MemTotal:/ {print $2}' "$MEMINFO") + 524288) / 1048576 ))
  [ "$memory_gib" -ge "$MIN_MEMORY_GIB" ] \
    || gaps+=("tiene $memory_gib GiB de memoria; se requieren al menos $MIN_MEMORY_GIB GiB")
  if command -v docker >/dev/null 2>&1; then
    if ! disk_dir="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"; then
      gaps+=("Docker está instalado, pero no responde")
      disk_dir=/var/lib
    fi
    case "$disk_dir" in /var/snap/*) gaps+=("Docker instalado mediante Snap no es compatible") ;; esac
  else
    case "$(os ID)" in
      ubuntu | debian) ;;
      *) gaps+=("Docker no está instalado y el instalador solo lo instala en Ubuntu o Debian (este servidor tiene $(os PRETTY_NAME))") ;;
    esac
  fi
  disk_gb="$(df --output=avail -B 1 "$disk_dir" | awk 'NR == 2 {print int($1 / 1e9)}')" || disk_gb=0
  [ "${disk_gb:-0}" -ge "$MIN_DISK_GB" ] \
    || gaps+=("tiene ${disk_gb:-0} GB libres en $disk_dir; se requieren al menos $MIN_DISK_GB GB")
  if listening="$(ss -H -l -n -t -u | awk '{sub(/.*:/, "", $5); print $1 "/" $5}')"; then
    for spec in $PORTS; do
      protocol="${spec%/*}"
      if grep -qx "$spec" <<<"$listening"; then gaps+=("el puerto ${spec#*/} (${protocol^^}) está en uso"); fi
    done
  else
    gaps+=("no se pudo revisar si los puertos 443, 3478 y 8080 están libres")
  fi
  [ -c "$FUSE_DEVICE" ] || gaps+=("falta el dispositivo /dev/fuse para los respaldos")
  [ -n "$(server_address)" ] \
    || gaps+=("no tiene una ruta de red predeterminada, de la que el instalador toma la dirección del servidor")
  [ "${#gaps[@]}" -eq 0 ] && return 0
  printf '\nEste servidor no cumple los requisitos de APS Conecta Gestión. No se modificó nada.\n' >&2
  printf '  - %s\n' "${gaps[@]}" >&2
  exit 1
}

# Docker's packages, with the script upstream documents, get.docker.com, when they cannot be installed.
install_docker() {
  say "Instalando Docker Engine desde los paquetes de Docker..."
  docker_packages && return 0
  rm -f /etc/apt/sources.list.d/docker.sources
  say "Los paquetes de Docker no se pudieron instalar. Instalando Docker con su script, get.docker.com..."
  curl -fsSL --retry 3 https://get.docker.com | sh >/dev/null \
    || die "no se pudo instalar Docker. Revise la conexión a internet del servidor y vuelva a ejecutar el instalador."
}

# Docker's apt repository, as Docker's guides for Ubuntu and Debian set it up.
docker_packages() {
  local id suite
  id="$(os ID)"
  suite="$(os UBUNTU_CODENAME)"
  export DEBIAN_FRONTEND=noninteractive
  install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL --retry 3 -o /etc/apt/keyrings/docker.asc "https://download.docker.com/linux/$id/gpg" \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nSigned-By: %s\n' \
      "$id" "${suite:-$(os VERSION_CODENAME)}" /etc/apt/keyrings/docker.asc \
      | tee /etc/apt/sources.list.d/docker.sources >/dev/null \
    && apt-get -qq -o DPkg::Lock::Timeout=300 update >/dev/null \
    && apt-get -qq -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io >/dev/null
}

# Redis needs vm.overcommit_memory = 1, and Elasticsearch a vm.max_map_count of at least 262144: one drop-in, which
# the reset removes. A higher map count already set is kept.
tune_kernel() {
  local maps
  maps="$(sysctl -n vm.max_map_count)"
  [ "$maps" -ge 262144 ] || maps=262144
  printf 'vm.overcommit_memory = 1\nvm.max_map_count = %s\n' "$maps" | tee "$DROP_IN" >/dev/null
  sysctl -p "$DROP_IN" >/dev/null || die "no se pudieron aplicar los ajustes del kernel de $DROP_IN."
}

# A test build's CAs, in one file of AIO's NEXTCLOUD_TRUSTED_CACERTS_DIR: AIO gives that folder to the Nextcloud and
# Talk containers, which trust every certificate of each file in it, and release.yml gives it to a test build's
# Euro-Office, whose NODE_EXTRA_CA_CERTS names this one file.
trust_cacerts() {
  mkdir -p "$CACERTS"
  base64 -d <<<"$TRUSTED_CACERTS" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    > "$CACERTS/ca.crt"
}

start_mastercontainer() {
  local trusted=()
  say "Descargando el contenedor maestro de APS Conecta Gestión $RELEASE_TAG..."
  docker pull --quiet "$MASTERCONTAINER" >/dev/null \
    || die "no se pudo descargar el contenedor maestro. Revise la conexión a internet del servidor y vuelva a" \
           "ejecutar el instalador."
  docker tag "$MASTERCONTAINER" "$CHANNEL"
  if [ -n "$TRUSTED_CACERTS" ]; then
    trust_cacerts
    trusted=(--env "NEXTCLOUD_TRUSTED_CACERTS_DIR=$CACERTS")
  fi
  docker run --init --sig-proxy=false --name "$CONTAINER" --restart always --detach --publish 8080:8080 \
    --env "APS_INTERFACE_ADDRESS=$1" "${trusted[@]}" --volume "$VOLUME" \
    --volume /var/run/docker.sock:/var/run/docker.sock:ro "$CHANNEL" >/dev/null \
    || { docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
         die "no se pudo iniciar el contenedor maestro. Vuelva a ejecutar el instalador."; }
}

# Prints the link block the mastercontainer logged since $1, once its last line is there.
relay_link() {
  local log waited=0
  until log="$(docker logs --since "$1" "$CONTAINER" 2>&1)" && [[ "$log" == *"$LINK_LAST"* ]]; do
    [ "$waited" -lt 600 ] \
      || die "el contenedor maestro no mostró el enlace de instalación en 10 minutos. Vuelva a ejecutar el instalador."
    sleep 5
    waited=$((waited + 5))
  done
  say ""
  sed -n "/^$LINK_FIRST/,/^$LINK_LAST/p" <<<"$log"
}

# Prints the file $2 of the mastercontainer's volume without starting the mastercontainer: docker exec reads it in a
# running one ($1 is true), and docker cp in a stopped one.
volume_file() {
  if [ "$1" = true ]; then docker exec "$CONTAINER" cat "$2"; else docker cp "$CONTAINER:$2" - | tar -xOf -; fi
}

# The suite's address: AIO's domain once one is set, otherwise AIO's page on the interface port. $1 is whether the
# mastercontainer runs; AIO writes its configuration with JSON_PRETTY_PRINT, one key on each line.
suite_address() {
  local domain
  domain="$(volume_file "$1" "$AIO_CONFIGURATION" 2>/dev/null | sed -n 's/^ *"domain": "\([^"]*\)".*/\1/p')" \
    || domain=""
  if [ -n "$domain" ]; then say "https://$domain"; else say "https://$(server_address):8080"; fi
}

# $1 is whether the mastercontainer runs. «Listo» is read before any start: after it nothing changes, and before it one
# docker restart, which also starts a stopped mastercontainer, makes it log a fresh link block.
rerun() {
  local since
  if volume_file "$1" "$LISTO" >/dev/null 2>&1; then
    say "APS Conecta Gestión ya está instalada en este servidor: $(suite_address "$1")"
    return 0
  fi
  say "La instalación sigue en curso: el contenedor maestro se reinicia y muestra un enlace nuevo." \
      "Los enlaces anteriores siguen sirviendo."
  since="$(now)"
  docker restart "$CONTAINER" >/dev/null
  relay_link "$since"
}

install_suite() {
  local state address since
  state="$(docker inspect --format '{{.Config.Image}} {{.State.Running}}' "$CONTAINER" 2>/dev/null)" || state=""
  case "${state% *}" in
    "") ;;
    "$CHANNEL") rerun "${state##* }"; return 0 ;;
    *) die "este servidor ya tiene un contenedor maestro de AIO que no es de APS Conecta Gestión (${state% *})." \
           "No se modificó nada." ;;
  esac
  check_host
  address="$(server_address)"
  command -v docker >/dev/null 2>&1 || install_docker
  tune_kernel
  since="$(now)"
  start_mastercontainer "$address"
  relay_link "$since"
}

# Frees the APS name «Dirección» claimed, with its own credential, before the reset removes anything, so that a reinstall
# claims it again. A short-lived container of the mastercontainer's image $1 reads the credential from the
# mastercontainer's volume, mounted read-only: whatever the mastercontainer's state, as docker exec is refused on a
# restarting or paused one, and after it was removed. The credential goes on stdin, never on a command line, to the
# Provisionador's release-name, in another one. Only a confirmed absence, no volume or no credential in it, means no
# name; any other failure stops the reset.
free_name() {
  local volume="${VOLUME%%:*}" volumes credential
  volumes="$(docker volume ls --format '{{.Name}}')" \
    || die "no se pudo leer la lista de volúmenes de Docker. No se eliminó nada."
  grep -qxF "$volume" <<<"$volumes" || return 0
  credential="$(docker run --rm --volume "$VOLUME:ro" --entrypoint sh "$1" \
                  -c '[ ! -e "$1" ] || { [ -s "$1" ] && cat "$1"; }' sh "$NAME_CREDENTIAL")" \
    || die "no se pudo leer la credencial del nombre APS del establecimiento en el volumen $volume, y sin ella el" \
           "nombre no se puede liberar. No se eliminó nada."
  [ -n "$credential" ] || return 0
  docker run --rm --interactive --entrypoint python3 "$1" -B "$PROVISIONADOR" release-name <<<"$credential" \
    || die "no se pudo liberar el nombre APS del establecimiento con el servicio de nombres de APS Conecta. Vuelva a" \
           "ejecutar el restablecimiento cuando el servidor tenga conexión a internet. No se eliminó nada."
}

# After a typed confirmation, the reset frees the APS name, with the mastercontainer's image or, once it was removed,
# the release's; then it removes what the install created: its containers, the images they ran, its volumes, its
# network, the kernel drop-in, the suite's route in Coolify's dynamic folder, a test build's CAs and AIO's nightly
# backup, which a reinstall's AIO could not open. Docker stays installed.
reset_suite() {
  local answer image ran="" containers images volumes
  if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
    die "Docker está instalado, pero no responde. No se eliminó nada."
  fi
  printf '%s\n' \
    "Esto libera el nombre APS del establecimiento, para que otra instalación del mismo establecimiento lo obtenga, y" \
    "elimina APS Conecta Gestión de este servidor con todos sus datos: los contenedores nextcloud-aio-*, las imágenes" \
    "que ejecutan, los volúmenes nextcloud_aio_*, la red nextcloud-aio, las copias de seguridad de $BACKUPS," \
    "$DROP_IN y $ROUTE. Docker queda instalado." >&2
  printf 'Para confirmar, escriba %s: ' "$CONFIRMATION" >&2
  read -r answer < /dev/tty || die "no se pudo leer la confirmación desde la terminal. No se eliminó nada."
  [ "$answer" = "$CONFIRMATION" ] || die "la confirmación no coincide. No se eliminó nada."
  if command -v docker >/dev/null 2>&1; then
    image="$(docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null)" || image=""
    free_name "${image:-$MASTERCONTAINER}"
    if [ -n "$image" ]; then
      ran="$image"
      docker rm --force "$CONTAINER" >/dev/null  # first, so it starts none of the others again
    fi
    mapfile -t containers < <(docker ps --all --format '{{.Names}}' | grep '^nextcloud-aio-' || true)
    if [ "${#containers[@]}" -gt 0 ]; then
      ran+=$'\n'"$(docker inspect --format '{{.Image}}' "${containers[@]}")"
      docker rm --force "${containers[@]}" >/dev/null
    fi
    mapfile -t images < <(grep . <<<"$ran" | sort -u || true)
    [ "${#images[@]}" -eq 0 ] || docker image rm --force "${images[@]}" >/dev/null
    mapfile -t volumes < <(docker volume ls --format '{{.Name}}' | grep '^nextcloud_aio_' || true)
    [ "${#volumes[@]}" -eq 0 ] || docker volume rm "${volumes[@]}" >/dev/null
    if docker network inspect nextcloud-aio >/dev/null 2>&1; then docker network rm nextcloud-aio >/dev/null; fi
  fi
  rm -f "$DROP_IN"
  rm -f "$ROUTE"
  rm -rf "$CACERTS" "$BACKUPS"
  say "APS Conecta Gestión se eliminó de este servidor. Docker sigue instalado."
}

main() {
  if [ -z "$RELEASE_TAG" ] || [ -z "$MASTERCONTAINER" ]; then
    die "este archivo es la copia del repositorio y no trae la versión ni el contenedor maestro de una publicación." \
        "Use el instalador publicado: $ONE_COMMAND"
  fi
  [ "$(id -u)" -eq 0 ] || die "ejecute el instalador como administrador: $ONE_COMMAND"
  case "$*" in
    "") install_suite ;;
    restablecer) reset_suite ;;
    *) die "el instalador no conoce «$*». Sin argumentos instala APS Conecta Gestión; con «restablecer», la elimina" \
           "de este servidor." ;;
  esac
}

main "$@"
