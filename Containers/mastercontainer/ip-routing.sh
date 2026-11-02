#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck disable=SC2016  # PHP variables must reach PHP literally.

set -euo pipefail

valid_ip() {
  php -r 'exit(filter_var($argv[1], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false ? 1 : 0);' "$1"
}

apply_route() {
  local public="$1" proxy="$2"
  valid_ip "$public" && valid_ip "$proxy" || return 1
  # The helper shares only the client's network namespace. Never flush another chain.
  iptables -w 5 -t nat -N APS_SUITE_IP 2>/dev/null \
    || iptables -w 5 -t nat -S APS_SUITE_IP >/dev/null
  iptables-restore -w 5 --noflush <<RULES
*nat
:APS_SUITE_IP - [0:0]
-F APS_SUITE_IP
-A APS_SUITE_IP -d $public/32 -p tcp --dport 443 -j DNAT --to-destination $proxy:443
COMMIT
RULES
  iptables -w 5 -t nat -C OUTPUT -j APS_SUITE_IP 2>/dev/null \
    || iptables -w 5 -t nat -I OUTPUT 1 -j APS_SUITE_IP
}

declare -A applied=()

reconcile() {
  local configuration="$1" public image proxy metadata id running started address signature client
  [ -f "$configuration" ] || return 0
  public="$(php -r '
    $configuration = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
    $domain = $configuration["domain"] ?? "";
    if (filter_var($domain, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false) echo $domain;
  ' "$configuration")" || return 1
  [ -n "$public" ] || return 0
  image="$(timeout 15 docker inspect --format '{{.Image}}' nextcloud-aio-mastercontainer)" || return 1
  [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  local format='{{.Id}}|{{.State.Running}}|{{.State.StartedAt}}|{{with index .NetworkSettings.Networks "nextcloud-aio"}}{{.IPAddress}}{{end}}'
  metadata="$(timeout 15 docker inspect --format "$format" aps-conecta-apache 2>/dev/null)" || return 0
  IFS='|' read -r id running started proxy <<< "$metadata"
  [ "$running" = true ] && valid_ip "$proxy" || return 0
  # These suite clients use the public URL for server-side requests. Office already uses internal URLs.
  for client in aps-conecta-nextcloud aps-conecta-talk aps-conecta-harp; do
    metadata="$(timeout 15 docker inspect --format "$format" "$client" 2>/dev/null)" || continue
    IFS='|' read -r id running started address <<< "$metadata"
    if ! [[ "$id" =~ ^[a-f0-9]{64}$ ]] || [ "$running" != true ] || ! valid_ip "$address"; then
      continue
    fi
    signature="$id|$started|$public|$proxy"
    [ "${applied[$client]:-}" != "$signature" ] || continue
    if timeout 40 docker run --rm --pull=never --name "aps-conecta-ip-route-${id:0:12}" \
        --network "container:$id" --cap-drop ALL --cap-add NET_ADMIN \
        --security-opt no-new-privileges --read-only --user 0 \
        --entrypoint timeout "$image" 20 /ip-routing.sh apply "$public" "$proxy"; then
      applied[$client]="$signature"
      printf 'Ruta HTTPS interna lista: %s\n' "$client"
    else
      printf 'No se pudo configurar la ruta HTTPS interna de %s; se reintentará.\n' "$client" >&2
      return 1
    fi
  done
}

case "${1:-}" in
  apply) [ "$#" -eq 3 ]; apply_route "$2" "$3" ;;
  once) [ "$#" -eq 2 ]; reconcile "$2" ;;
  watch)
    configuration="${2:-/mnt/docker-aio-config/data/configuration.json}"
    while :; do
      reconcile "$configuration" || echo 'No se pudo verificar el enrutamiento interno de la suite; se reintentará.' >&2
      sleep 5
    done ;;
  *) echo 'Usage: ip-routing.sh apply PUBLIC_IPV4 PROXY_IPV4 | once CONFIG | watch [CONFIG]' >&2; exit 2 ;;
esac
