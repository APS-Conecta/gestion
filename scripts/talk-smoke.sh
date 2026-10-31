#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"
suite_url_resolve
nc_container

python3 - "$NC_CONTAINER" "$SUITE_URL" <<'PY'
import json, subprocess, sys, urllib.parse
native = ['docker', 'exec', '--user', 'www-data', sys.argv[1], 'php', '/var/www/html/occ']
def read(command, allowed=(0,)):
    result = subprocess.run(native + [command, '--output=json'], capture_output=True, text=True, timeout=180)
    assert result.returncode in allowed, 'Talk native command failed'
    return json.loads(result.stdout)
try:
    signaling = read('talk:signaling:list')
    expected = sys.argv[2] + '/standalone-signaling/'
    assert isinstance(signaling, dict) and isinstance(signaling.get('servers'), list), 'Talk signaling not configured'
    assert signaling['servers'] == [{'server':expected, 'verify':True}], 'Talk signaling not configured for the suite URL'
    assert isinstance(signaling.get('secret'), str) and signaling['secret'], 'Talk signaling secret is missing'
    endpoint = urllib.parse.urlsplit(sys.argv[2]).hostname + ':3478'
    turn = read('talk:turn:list')
    assert isinstance(turn, list) and len(turn) == 1, 'Talk TURN not configured'
    assert turn[0]['schemes'] == 'turn' and turn[0]['server'] == endpoint and turn[0]['protocols'] == 'udp,tcp', 'Talk TURN does not use the server address on port 3478'
    assert isinstance(turn[0].get('secret'), str) and turn[0]['secret'], 'Talk TURN secret is missing'
    assert read('talk:stun:list') == [endpoint], 'Talk STUN does not use the server address on port 3478'
    print('PASS: Talk signaling, TURN and STUN use the suite URL and server address', flush=True)
    # Native diagnostics may initialize token keys and record backend capabilities;
    # they do not provision or change TURN, STUN or signaling configuration.
    checks = read('setupchecks', allowed=(0, 1))
    check = checks['talk']['OCA\\Talk\\SetupCheck\\HighPerformanceBackend']
    assert check['severity'] == 'success', 'The native Talk signaling check is not successful'
except AssertionError as error:
    print('FAIL: ' + str(error), file=sys.stderr)
    sys.exit(1)
except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
    print('FAIL: Talk did not return valid native configuration', file=sys.stderr)
    sys.exit(1)
print('PASS: Nextcloud native Talk diagnostics reach a compatible signaling backend')
PY

welcome="$(suite_curl --silent --show-error --fail --write-out '\n%{http_code}' \
  "$SUITE_URL/standalone-signaling/api/v1/welcome" 2>/dev/null)" || {
  echo "FAIL: Talk signaling welcome is not reachable with verified suite HTTPS trust$SUITE_D10" >&2
  exit 1
}
printf '%s' "$welcome" | python3 -c '
import json, sys
try:
    body, status = sys.stdin.read().rsplit("\n", 1)
    assert status == "200"
    welcome = json.loads(body)
    assert welcome["nextcloud-spreed-signaling"] == "Welcome"
    assert isinstance(welcome["version"], str) and welcome["version"]
except (AssertionError, KeyError, TypeError, ValueError):
    print("FAIL: Talk signaling welcome did not return the expected HTTP 200 JSON", file=sys.stderr)
    sys.exit(1)
print("PASS: Talk signaling welcome answers through the public suite route with verified TLS")
'
