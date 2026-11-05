#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The reset, the Bootstrap with «restablecer» and its confirmation typed at a terminal, first frees the APS name with its
# own credential, then leaves nothing of the install: no nextcloud-aio-* container, no image they ran, no
# nextcloud_aio_* volume, no nextcloud-aio network, no kernel drop-in and no test build's CAs. A container, a volume and
# a file planted beside it under look-alike names survive. A reinstall on the same machine then claims the same name
# again (claim.py keeps its credential, which run.sh frees). It runs last.
set -euo pipefail
credentials=("$NAMES"/*.json)
[[ "${#credentials[@]}" -eq 1 && -e "${credentials[0]}" ]] \
  || { echo "the run kept no one claimed name's credential (40-install claims one): ${credentials[*]}" >&2; exit 1; }
code="$(basename "${credentials[0]}" .json)"
name="$("$MACHINE" 'sudo docker exec nextcloud-aio-mastercontainer cat /mnt/docker-aio-config/data/configuration.json' \
  | jq -r '.domain // empty')"
"$MACHINE" sudo bash -s << 'PLANT'
set -euo pipefail
busybox=busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
docker pull --quiet "$busybox" > /dev/null
docker run --detach --name keep-nextcloud-aio "$busybox" sleep infinity > /dev/null
docker volume create keep_nextcloud_aio > /dev/null
echo '# not the install' > /etc/sysctl.d/90-keep.conf
PLANT
ran="$("$MACHINE" sudo bash -s << 'RAN'
docker ps --all --format '{{.Names}}' | grep '^nextcloud-aio-' | xargs --no-run-if-empty docker inspect --format '{{.Image}}'
RAN
)"
echo "$COMMAND -s restablecer"
# The Bootstrap reads the confirmation from the terminal, as the operator types it there: script(1) gives it one.
reset="$(timeout 10m "$MACHINE" "script --quiet --return --command '$COMMAND -s restablecer' /dev/null" <<< ELIMINAR)"
printf '%s\n' "$reset"
grep -qF "Se liberó el nombre APS $name." <<< "$reset" || { echo "the reset did not free $name first" >&2; exit 1; }
left="$("$MACHINE" "sudo bash -s $(sort -u <<< "$ran" | tr '\n' ' ')" << 'LEFT'
docker ps --all --format 'container {{.Names}}' | grep ' nextcloud-aio-'
docker volume ls --format 'volume {{.Name}}' | grep ' nextcloud_aio_'
docker network ls --format 'network {{.Name}}' | grep -x 'network nextcloud-aio'
for image in "$@"; do docker image inspect --format "image $image {{.RepoTags}}" "$image" 2> /dev/null; done
ls /etc/sysctl.d/90-apsconecta-gestion.conf /etc/ssl/apsconecta-gestion 2> /dev/null
true
LEFT
)"
[ -z "$left" ] || { printf "the reset left the install's:\n%s\n" "$left" >&2; exit 1; }
kept="$("$MACHINE" sudo bash -s << 'KEPT'
docker inspect --format '{{.State.Running}}' keep-nextcloud-aio
docker volume inspect --format '{{.Name}}' keep_nextcloud_aio
cat /etc/sysctl.d/90-keep.conf
KEPT
)"
[ "$kept" = $'true\nkeep_nextcloud_aio\n# not the install' ] \
  || { printf 'the reset took what it did not install; left of it:\n%s\n' "$kept" >&2; exit 1; }
echo "the reset left nothing of the install, and the planted container, volume and file are there"

# The reinstall: the Bootstrap again, as the manual prints it, and «Dirección» with its fresh link claims the name of the
# same DEIS code, which the reset freed.
console="$(mktemp)" # the fresh link stays out of the log and the evidence
aps/acceptance/one-command.sh "$console"
python3 aps/acceptance/claim.py "$console" "$code"
rm -f "$console"
again="$("$MACHINE" 'sudo docker exec nextcloud-aio-mastercontainer cat /mnt/docker-aio-config/data/configuration.json' \
  | jq -r '.domain // empty')"
[ "$again" = "$name" ] || { echo "the reinstall claimed ${again:-no name}, not $name" >&2; exit 1; }
echo "the reset freed $name first, and a reinstall on the same machine claimed it again"
