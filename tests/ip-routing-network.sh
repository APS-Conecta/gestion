#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# All interfaces, routing and firewall rules live in disposable network namespaces.
set -euo pipefail
if [ "${1:-}" != --inside ]; then
  exec unshare --mount --net -- bash "$0" --inside "${1:-}"
fi
mode="${2:-}"
root="$(dirname "$0")"
work="$(mktemp -d)"
pids=()
declare -A namespaces=()
# shellcheck disable=SC2317  # Called by the EXIT trap.
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT
mount --make-rprivate /
ip link set lo up
ip addr add 198.18.0.1/32 dev lo
ip link add br-test type bridge
ip addr add 172.30.11.1/24 dev br-test
ip link set br-test up
sysctl -qw net.ipv4.ip_forward=1
for index in 2 3 4; do
  unshare --net sleep 120 &
  pid=$!; pids+=("$pid")
  for _ in $(seq 50); do
    [ "$(readlink /proc/"$pid"/ns/net)" != "$(readlink /proc/self/ns/net)" ] && break
    sleep 0.01
  done
  ip link add "veth$index" type veth peer name eth0 netns "$pid"
  ip link set "veth$index" master br-test
  ip link set "veth$index" up
  nsenter -t "$pid" -n ip link set lo up
  nsenter -t "$pid" -n ip addr add "172.30.11.$index/24" dev eth0
  nsenter -t "$pid" -n ip link set eth0 up
  nsenter -t "$pid" -n ip route add default via 172.30.11.1
  namespaces[$index]="$pid"
done
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 1 -subj /CN=IP-network-fixture -addext subjectAltName=IP:198.18.0.1 >/dev/null 2>&1
nsenter -t "${namespaces[2]}" -n python3 "$root/ip-routing-server.py" "$work/cert.pem" "$work/key.pem" &
pids+=("$!")
iptables -t nat -A OUTPUT -d 198.18.0.1 -p tcp --dport 443 -j DNAT --to-destination 172.30.11.2:443
iptables -t nat -A PREROUTING -d 198.18.0.1 -p tcp --dport 443 -j DNAT --to-destination 172.30.11.2:443
# Model the reported container-to-host-IP drop before Docker's DNAT.
iptables -t raw -A PREROUTING -i br-test -d 198.18.0.1 -p tcp --dport 443 -j DROP
curl_args=(--silent --show-error --noproxy '*' --cacert "$work/cert.pem" --connect-timeout 1 --max-time 2 --output /dev/null --write-out '%{http_code}')
for _ in $(seq 30); do
  curl "${curl_args[@]}" https://198.18.0.1/ >/dev/null 2>&1 && break
  sleep 0.1
done
printf 'Host public HTTPS: %s\n' "$(curl "${curl_args[@]}" https://198.18.0.1/)"
if [ "$mode" = --repair ]; then
  for pid in "${namespaces[3]}" "${namespaces[4]}"; do
    nsenter -t "$pid" -n bash "$root/../Containers/mastercontainer/ip-routing.sh" apply 198.18.0.1 172.30.11.2
    nsenter -t "$pid" -n bash "$root/../Containers/mastercontainer/ip-routing.sh" apply 198.18.0.1 172.30.11.2
    [ "$(nsenter -t "$pid" -n iptables -t nat -S OUTPUT | wc -l)" -eq 2 ]
  done
fi
failed=0
for entry in "${namespaces[3]}:/standalone-signaling/api/v1/welcome" "${namespaces[4]}:/status.php"; do
  pid="${entry%%:*}"; route="${entry#*:}"
  if result="$(nsenter -t "$pid" -n curl "${curl_args[@]}" "https://198.18.0.1$route" 2>/dev/null)"; then
    printf 'PASS: container -> public IP %s, verified TLS, HTTP %s\n' "$route" "$result"
  else
    printf 'FAIL: container -> public IP %s, HTTP %s\n' "$route" "$result"
    failed=1
  fi
done
exit "$failed"
