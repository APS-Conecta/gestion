#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The reset, the one command with «restablecer» and its confirmation typed at a terminal, leaves nothing of the
# install: no nextcloud-aio-* container, no image they ran, no nextcloud_aio_* volume, no nextcloud-aio network and
# no kernel drop-in. A container, a volume and a file planted beside it under look-alike names survive. It runs last.
set -euo pipefail
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
timeout 10m "$MACHINE" "script --quiet --return --command '$COMMAND -s restablecer' /dev/null" <<< ELIMINAR
left="$("$MACHINE" "sudo bash -s $(sort -u <<< "$ran" | tr '\n' ' ')" << 'LEFT'
docker ps --all --format 'container {{.Names}}' | grep ' nextcloud-aio-'
docker volume ls --format 'volume {{.Name}}' | grep ' nextcloud_aio_'
docker network ls --format 'network {{.Name}}' | grep -x 'network nextcloud-aio'
for image in "$@"; do docker image inspect --format "image $image {{.RepoTags}}" "$image" 2> /dev/null; done
ls /etc/sysctl.d/90-apsconecta-gestion.conf 2> /dev/null
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
