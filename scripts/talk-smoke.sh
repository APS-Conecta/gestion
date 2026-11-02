#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"
suite_url_resolve
nc_container
require_store_app_integrity spreed || exit 1

talk_native_failed=0
python3 - "$NC_CONTAINER" "$SUITE_URL" <<'PY' || talk_native_failed=1
import json, re, subprocess, sys, urllib.parse
native = ['docker', 'exec', '--user', 'www-data', sys.argv[1], 'php', '/var/www/html/occ']
def read(command, allowed=(0,)):
    try:
        result = subprocess.run(native + [command, '--output=json'], capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        raise AssertionError(f'Nextcloud {command} timed out after 180 seconds; verify container-to-suite HTTPS connectivity') from None
    assert result.returncode in allowed, f'Nextcloud {command} failed'
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
    severity = check.get('severity')
    description = check.get('description')
    # The supported stable backend lacks this unreleased optimization (ADR-0024).
    # Match the complete native result; other feature warnings still fail closed.
    optional_templates = (
        ('Warning: Running version: ', '; Server does not support all features of this Talk version, missing features: '),
        ('Advertencia: Versión en ejecución: ', '; El servidor no soporta todas las características de esta versión de Talk, características que faltan: '),
    )
    optional_warning = severity == 'warning' and isinstance(description, str) and any(
        re.fullmatch(re.escape(prefix) + r'[0-9][0-9A-Za-z.+_~-]*' + re.escape(separator) + 'changed-users', description)
        for prefix, separator in optional_templates)
    if optional_warning:
        cache = checks['system']['OCA\\Settings\\SetupChecks\\MemcacheConfigured']
        assert cache['severity'] == 'success', 'The native memory cache check is not successful'
        backend = subprocess.run(native + ['config:system:get', 'memcache.distributed'],
            capture_output=True, text=True, timeout=30)
        assert backend.returncode == 0 and backend.stdout.strip() == r'\OC\Memcache\Redis', 'Talk does not have the suite distributed cache'
        print('WARN: supported signaling backend lacks the optional changed-users optimization', flush=True)
        print('PASS: native Talk compatibility has only the documented optional warning and verified Redis cache', flush=True)
    elif severity != 'success':
        safe_severity = severity if severity in ('error', 'warning', 'info') else 'unknown'
        changed_users = 'yes' if isinstance(description, str) and 'changed-users' in description else 'no'
        raise AssertionError('The native Talk signaling check is not successful '
            f'(severity={safe_severity}; changed-users mentioned={changed_users})')
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
[ "$talk_native_failed" -eq 0 ]
