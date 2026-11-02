#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
image="${1:?usage: ip-routing-docker.sh BUILT_CONTROLLER_IMAGE}"
root="$(cd "$(dirname "$0")/.." && pwd)"
network="aps-ip-267-test-$$"
server="$network-server"
client="$network-client"
work="$(mktemp -d)"
server_pid=''
# shellcheck disable=SC2317  # Called by the EXIT trap.
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  docker rm -f "$server" "$client" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 1 -subj /CN=IP-network-fixture -addext subjectAltName=IP:198.18.0.1 >/dev/null 2>&1
docker network create "$network" >/dev/null
docker run -d --name "$server" --network "$network" --cap-drop ALL --read-only --entrypoint sleep "$image" 120 >/dev/null
docker run -d --name "$client" --network "$network" --cap-drop ALL --read-only --mount "type=bind,src=$work/cert.pem,dst=/test-ca.pem,readonly" --entrypoint sleep "$image" 120 >/dev/null
pid="$(docker inspect --format '{{.State.Pid}}' "$server")"
proxy="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$server")"
nsenter -t "$pid" -n python3 "$root/tests/ip-routing-server.py" "$work/cert.pem" "$work/key.pem" &
server_pid=$!
docker run --rm --network "container:$client" --cap-drop ALL --cap-add NET_ADMIN --read-only --security-opt no-new-privileges --entrypoint iptables "$image" -A OUTPUT -d 198.18.0.1 -p tcp --dport 443 -j DROP
if docker exec "$client" curl --noproxy '*' --silent --show-error --cacert /test-ca.pem --max-time 2 https://198.18.0.1/ >/dev/null 2>&1; then
  echo 'FAIL: fixture must reproduce the blocked path'; exit 1
fi
printf 'PASS: blocked public-IP path reproduced in disposable Docker client\n'
for _ in 1 2; do
  docker run --rm --network "container:$client" --cap-drop ALL --cap-add NET_ADMIN --read-only --security-opt no-new-privileges --entrypoint timeout "$image" 20 /ip-routing.sh apply 198.18.0.1 "$proxy"
done
body="$(docker exec "$client" curl --noproxy '*' --silent --show-error --fail --cacert /test-ca.pem --max-time 5 https://198.18.0.1/standalone-signaling/api/v1/welcome)"
[[ "$body" == *Welcome* ]]
[ "$(docker inspect --format '{{json .HostConfig.CapAdd}}' "$client")" = null ]
printf 'PASS: real helper restores verified HTTPS; application container retains no added capabilities\n'
