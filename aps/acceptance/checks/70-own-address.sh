#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Talk and Office reach the suite's own address on AIO's network (ADR 0028): there the name is a network alias of our
# Caddy, so inside the Talk and Euro-Office containers it resolves to our Caddy, and HTTPS to it reaches the suite while
# the host drops everything its containers send it: these calls meet neither the host's firewall nor a hairpin NAT.
# Each verifies the name's certificate with its own trust, which a test build gives the staging roots: Talk with the
# bundle its start builds from the CAs AIO gives it (NEXTCLOUD_TRUSTED_CACERTS_DIR), and Euro-Office's document server,
# which fetches the name itself as it fetches a document to open, with Node's roots and the file of that folder that
# release.yml names in NODE_EXTRA_CA_CERTS. Any other candidate's names and certificates are production ones, which a
# run never claims: there it says so and passes.
set -euo pipefail
if [ "$TEST_BUILD" != true ]; then
  echo "the own-address check runs on a v0.0.0-ci.N test build only: $TAG's names and certificates are production" \
    "ones"
  exit 0
fi
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
echo "the host drops what its containers send it; inside Talk, https://$1/status.php answers:"
printf 'GET /status.php HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$1" \
  | docker exec -i nextcloud-aio-talk openssl s_client -quiet -verify_return_error -connect "$1:443" -servername "$1" \
      -CAfile /tmp/ca-certificates.crt 2>/dev/null | grep '"installed":true'
echo "and Euro-Office's document server converts https://$1/status.php, which it fetches itself:"
logs=(/var/log/euro-office/documentserver/{docservice,converter}/out.log)
docker exec -i nextcloud-aio-eurooffice python3 - "$1" << 'CONVERT' \
  || { docker exec nextcloud-aio-eurooffice tail -n 15 "${logs[@]}" >&2; exit 1; }
# Its conversion API, as Nextcloud's connector calls it: a request signed with the container's own JWT secret, which
# stays in the container, for a URL the document server then downloads with its own trust.
import base64, hashlib, hmac, json, os, sys, time, urllib.request
def part(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
conversion = {"async": False, "url": f"https://{sys.argv[1]}/status.php", "filetype": "txt", "codePage": 65001,
              "outputtype": "docx", "title": "status.txt", "key": f"own-address-{time.time_ns()}"}
signed = part(b'{"alg":"HS256","typ":"JWT"}') + "." + part(json.dumps({"payload": conversion}).encode())
token = signed + "." + part(hmac.new(os.environ["JWT_SECRET"].encode(), signed.encode(), hashlib.sha256).digest())
request = urllib.request.Request("http://127.0.0.1/converter", json.dumps(conversion).encode(), {
    "Content-Type": "application/json", "Accept": "application/json", os.environ["JWT_HEADER"]: f"Bearer {token}"})
with urllib.request.urlopen(request, timeout=120) as response:
    answer = json.load(response)
if not answer.get("endConvert"):
    sys.exit(f"the document server answered {answer}: error -4 is a download it could not make")
print(f"converted to {answer.get('fileType')}")
CONVERT
DROP
echo "Talk and Euro-Office reach https://$name on AIO's network, clear of the host"
