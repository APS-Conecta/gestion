#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"
suite_url_resolve
nc_container

task_harp_failed=0
python3 - "$SUITE_URL" "$NC_CONTAINER" <<'PYDAEMON' || task_harp_failed=1
import json, subprocess, sys
native = ['docker', 'exec', '--user', 'www-data', sys.argv[2],
          'php', '/var/www/html/occ']
def read(*args, allowed=(0,)):
    result = subprocess.run(native + list(args), capture_output=True, text=True, timeout=180)
    assert result.returncode in allowed, 'AppAPI native command failed'
    return result.stdout
try:
    daemons = json.loads(read('app_api:daemon:list', '--output=json'))
    assert isinstance(daemons, list) and len(daemons) == 1, 'Expected one deploy daemon'
    default = read('config:app:get', 'app_api', 'default_daemon_config').strip()
    daemon = daemons[0]
    assert default and daemon['name'] == default, 'HaRP is not the selected default daemon'
    assert daemon['deploy_id'] == 'docker-install' and daemon['protocol'] == 'http', 'Unexpected deploy transport'
    assert daemon['host'] in ('nextcloud-aio-harp:8780', 'aps-conecta-harp:8780'), 'The daemon does not use the suite HaRP'
    config = daemon['deploy_config']
    assert config['net'] == 'nextcloud-aio', 'The daemon does not use the suite network'
    assert config['nextcloud_url'] == sys.argv[1], 'The daemon does not use the public suite URL'
    assert config['harp']['exapp_direct'] is True and str(config['harp']['docker_socket_port']) == '24000', 'HaRP local deployment is not configured'
    print('PASS: one default HaRP daemon uses the suite network and public URL', flush=True)
    checks = json.loads(read('setupchecks', '--output=json', allowed=(0, 1)))
    check = checks['system']['OCA\\AppAPI\\SetupChecks\\DaemonCheck']
    assert check['severity'] == 'success', 'The native AppAPI daemon reachability check is not successful'
    print('PASS: the native AppAPI check reaches the default HaRP daemon')
except AssertionError as error:
    print('FAIL: ' + str(error), file=sys.stderr)
    sys.exit(1)
except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
    print('FAIL: AppAPI did not return valid native daemon state', file=sys.stderr)
    sys.exit(1)
PYDAEMON
docker exec -i aps-conecta-harp python3 - "$SUITE_URL" "$NC_CONTAINER" <<'PYHARPTLS' || task_harp_failed=1
import asyncio, os, pathlib, sys
try:
    agents = []
    for process in pathlib.Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            args = (process / 'cmdline').read_bytes().split(b'\0')
        except (FileNotFoundError, PermissionError):
            continue
        if len(args) > 1 and args[1] == b'/usr/local/bin/haproxy_agent.py':
            agents.append(process)
    assert len(agents) == 1
    settings = {}
    for item in (agents[0] / 'environ').read_bytes().split(b'\0'):
        key, separator, value = item.partition(b'=')
        if separator and key in (b'SSL_CERT_FILE', b'SSL_CERT_DIR', b'NC_INSTANCE_URL'):
            settings[key.decode()] = value.decode()
    url = sys.argv[1]
    assert settings['NC_INSTANCE_URL'].rstrip('/') == url
    # docker exec must use the running agent's trust before aiohttp creates its contexts.
    for key in ('SSL_CERT_FILE', 'SSL_CERT_DIR'):
        os.environ.pop(key, None)
        if key in settings:
            os.environ[key] = settings[key]
    import aiohttp
    async def check():
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as session:
            async with session.get(url + '/status.php', allow_redirects=False) as response:
                assert response.status == 200
                assert (await response.json())['installed'] is True
    asyncio.run(check())
except Exception:
    print('FAIL: HaRP cannot verify the suite HTTPS certificate and installed status', file=sys.stderr)
    sys.exit(1)
print('PASS: HaRP reaches the installed suite using the running agent trust and strict TLS')
PYHARPTLS
[ "$task_harp_failed" -eq 0 ] || exit 1
echo "PASS: AppAPI has one reachable default HaRP daemon and verified suite HTTPS trust"
