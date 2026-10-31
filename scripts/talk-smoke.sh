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
def read(command):
    result = subprocess.run(native + [command, '--output=json'], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, 'Talk configuration could not be read'
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
except AssertionError as error:
    print('FAIL: ' + str(error), file=sys.stderr)
    sys.exit(1)
except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
    print('FAIL: Talk did not return valid native configuration', file=sys.stderr)
    sys.exit(1)
print('PASS: Talk signaling, TURN and STUN use the suite URL and server address')
PY
