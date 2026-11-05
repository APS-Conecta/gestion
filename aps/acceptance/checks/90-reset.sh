#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The reset, the Bootstrap with «restablecer» and its confirmation typed at a terminal, leaves nothing of the install:
# no nextcloud-aio-* container, no image they ran, no nextcloud_aio_* volume, no nextcloud-aio network, no kernel
# drop-in, no test build's CAs and no backup folder, with the file planted in it. A container, a volume and a file
# planted beside them under look-alike names survive. On a test build it first frees the APS name with its own
# credential, and a reinstall on the same machine then claims the same name again (claim.py keeps its credential,
# which run.sh frees). Any other candidate's names and certificates are production ones, which a run never claims:
# there the check says the name's freeing and the reinstall run on a test build only. It runs last.
set -euo pipefail
name="$("$MACHINE" 'sudo docker exec nextcloud-aio-mastercontainer cat /mnt/docker-aio-config/data/configuration.json' \
  | jq -r '.domain // empty')"
if [ "$TEST_BUILD" = true ]; then
  credentials=("$NAMES"/*.json)
  [[ "${#credentials[@]}" -eq 1 && -e "${credentials[0]}" ]] \
    || { echo "the run kept no one claimed name's credential (40-install claims one): ${credentials[*]}" >&2; exit 1; }
  code="$(basename "${credentials[0]}" .json)"
else
  echo "the name's freeing and the reinstall run on a v0.0.0-ci.N test build only: $TAG's names and certificates" \
    "are production ones"
fi
"$MACHINE" sudo bash -s << 'PLANT'
set -euo pipefail
busybox=busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
docker pull --quiet "$busybox" > /dev/null
docker run --detach --name keep-nextcloud-aio "$busybox" sleep infinity > /dev/null
docker volume create keep_nextcloud_aio > /dev/null
echo '# not the install' > /etc/sysctl.d/90-keep.conf
mkdir -p /var/backups/apsconecta-gestion # AIO's nightly backup, where «Instalar» sends it
echo '# a backup' > /var/backups/apsconecta-gestion/planted
PLANT
ran="$("$MACHINE" sudo bash -s << 'RAN'
docker ps --all --format '{{.Names}}' | grep '^nextcloud-aio-' | xargs --no-run-if-empty docker inspect --format '{{.Image}}'
RAN
)"
echo "$COMMAND -s restablecer"
# The Bootstrap reads the confirmation from the terminal, as the operator types it there: script(1) gives it one.
reset="$(timeout 10m "$MACHINE" "script --quiet --return --command '$COMMAND -s restablecer' /dev/null" <<< ELIMINAR)"
printf '%s\n' "$reset"
if [ "$TEST_BUILD" = true ]; then
  grep -qF "Se liberó el nombre APS $name." <<< "$reset" || { echo "the reset did not free $name first" >&2; exit 1; }
fi
left="$("$MACHINE" "sudo bash -s $(sort -u <<< "$ran" | tr '\n' ' ')" << 'LEFT'
docker ps --all --format 'container {{.Names}}' | grep ' nextcloud-aio-'
docker volume ls --format 'volume {{.Name}}' | grep ' nextcloud_aio_'
docker network ls --format 'network {{.Name}}' | grep -x 'network nextcloud-aio'
for image in "$@"; do docker image inspect --format "image $image {{.RepoTags}}" "$image" 2> /dev/null; done
ls -d /etc/sysctl.d/90-apsconecta-gestion.conf /etc/ssl/apsconecta-gestion /var/backups/apsconecta-gestion 2> /dev/null
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
[ "$TEST_BUILD" = true ] || exit 0

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
