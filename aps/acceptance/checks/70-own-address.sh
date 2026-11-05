#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Talk and Office reach the suite's own address on AIO's network (ADR 0028): there the name is a network alias of our
# Caddy, so inside the Talk and Euro-Office containers it resolves to our Caddy, and HTTPS to it reaches the suite while
# the host drops everything its containers send it: these calls meet neither the host's firewall nor a hairpin NAT.
# Talk verifies the name's certificate with the bundle its start builds from the CAs AIO gives it, a test build's
# staging roots (NEXTCLOUD_TRUSTED_CACERTS_DIR); vanilla AIO gives Euro-Office none, so its probe gets the roots.
set -euo pipefail
name="$("$MACHINE" 'sudo docker exec nextcloud-aio-mastercontainer cat /mnt/docker-aio-config/data/configuration.json' \
  | jq -r '.domain // empty')"
[ -n "$name" ] || { echo "the suite has no name: «Dirección» claimed none" >&2; exit 1; }
caddy="$("$MACHINE" "sudo docker inspect --format '{{(index .NetworkSettings.Networks \"nextcloud-aio\").IPAddress}}' \
  nextcloud-aio-caddy")"
for container in nextcloud-aio-talk nextcloud-aio-eurooffice; do
  resolved="$("$MACHINE" "sudo docker exec $container getent hosts $name" | awk '{print $1; exit}')"
  [ "$resolved" = "$caddy" ] \
    || { echo "inside $container, $name resolves to ${resolved:-nothing}, not to our Caddy's $caddy" >&2; exit 1; }
  echo "inside $container, $name resolves to our Caddy's address on nextcloud-aio, $caddy"
done
"$MACHINE" "sudo docker exec -i nextcloud-aio-eurooffice sh -c 'cat > /tmp/letsencrypt-staging-roots.pem'" \
  < aps/acceptance/letsencrypt-staging-roots.pem
# shellcheck disable=SC2016 # expands on the machine
"$MACHINE" sudo bash -s "$name" "$ADDRESS" << 'DROP'
set -euo pipefail
rule=(PREROUTING -i br-+ -m addrtype --dst-type LOCAL -j DROP)
iptables -t raw -I "${rule[@]}"
trap 'iptables -t raw -D "${rule[@]}"' EXIT
if docker exec nextcloud-aio-eurooffice nc -z -w 5 "$2" 443; then
  echo "the host still answers its containers at $2" >&2
  exit 1
fi
echo "the host drops what its containers send it; inside Talk and Euro-Office, https://$1/status.php answers:"
printf 'GET /status.php HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$1" \
  | docker exec -i nextcloud-aio-talk openssl s_client -quiet -verify_return_error -connect "$1:443" -servername "$1" \
      -CAfile /tmp/ca-certificates.crt 2>/dev/null | grep '"installed":true'
docker exec nextcloud-aio-eurooffice curl --fail --silent --show-error --max-time 20 \
  --cacert /tmp/letsencrypt-staging-roots.pem "https://$1/status.php"
echo
DROP
echo "Talk and Euro-Office reach https://$name on AIO's network, clear of the host"
