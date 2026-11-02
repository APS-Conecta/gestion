#!/usr/bin/env bash
# The suite's quality gate, run locally and by .github/workflows/ci.yml.
# Static checks that need no running stack, then the hermetic self-tests of every mover that
# carries one — including the bootstrap's and the package signer's — then the smoke checks when a
# stack is up. Exits non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
user_secret_argv_cases() {
  python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='aps user secret ') as directory:
    root = pathlib.Path(directory)
    for name in ('scripts', 'provisioning', 'bin'):
        (root / name).mkdir()
    for name in ('scripts/env.sh', 'provisioning/lib.sh'):
        shutil.copyfile(name, root / name)
    capture = root / 'calls.jsonl'
    docker = root / 'bin/docker'
    docker.write_text('#!' + sys.executable + '\n' + '''
import json, os, sys
with open(os.environ['CASE_CAPTURE'], 'a') as output:
    output.write(json.dumps({'argv': sys.argv[1:], 'password': os.environ.get('OC_PASS')}) + '\\n')
sys.exit(1 if 'user:info' in sys.argv else 0)
''')
    docker.chmod(0o755)
    password = "synthetic password ' \" $ ;"
    env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'],
               CASE_CAPTURE=str(capture), CASE_PASSWORD=password)
    env.pop('OC_PASS', None)
    setup = 'set -e\nsource scripts/env.sh\nsource provisioning/lib.sh\n'
    result = subprocess.run(['bash', '-c', setup + 'ensure_user fixture.staff \'Fixture User\' "$CASE_PASSWORD"\n'],
                            cwd=root, env=env, capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stderr
    calls = [json.loads(line) for line in capture.read_text().splitlines()]
    assert all(password not in word for call in calls for word in call['argv']), 'A staff password entered Docker arguments'
    creations = [call for call in calls if 'user:add' in call['argv']]
    assert len(creations) == 1 and creations[0]['password'] == password, 'The named environment did not deliver the exact password'
    assert 'OC_PASS' in creations[0]['argv'] and '--password-from-env' in creations[0]['argv']
    assert "synthetic password" not in result.stdout + result.stderr
PY
}
check user_secret_argv_cases

clinic_seed_has_no_personal_fixtures() {
  python3 - <<'PY'
import pathlib, re
phases = pathlib.Path('provisioning/phases')
assert not (phases / '60-fixtures.sh').exists(), 'Clinic installs still include the development content phase'
for path in phases.glob('*.sh'):
    code = '\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith('#'))
    assert 'ensure_sample_file' not in code, f'{path}: development content in personal Files'
    assert not re.search(r'\$(?:\{(?:uid|user)\}|(?:uid|user))/files', code), f'{path}: personal Files write'
for name in ('provisioning/seed.sh', 'scripts/seed-idempotent.sh', 'scripts/provisionador.py'):
    assert 'SEED_FIXTURES' not in pathlib.Path(name).read_text(), f'{name}: obsolete fixture partition'
PY
}
check clinic_seed_has_no_personal_fixtures

service_secret_argv_cases() {
  python3 - <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='aps service secret ') as directory:
    root = pathlib.Path(directory)
    capture = root / 'call.json'
    client = root / 'redis-cli'
    client.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['CASE_CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:], 'password': os.environ.get('REDISCLI_AUTH')}))
print('PONG')
sys.exit(int(os.environ.get('CASE_FAIL', '0')))
''')
    client.chmod(0o755)
    password = "synthetic password ' \" $ ;"
    env = dict(os.environ, PATH=directory + ':' + os.environ['PATH'], CASE_CAPTURE=str(capture),
               REDIS_HOST_PASSWORD=password, AIO_LOG_LEVEL='debug')
    for failure in ('0', '1'):
        result = subprocess.run(['bash', 'Containers/redis/healthcheck.sh'],
                                env=dict(env, CASE_FAIL=failure), capture_output=True, text=True, timeout=5)
        call = json.loads(capture.read_text())
        assert all(password not in word for word in call['argv']), 'Redis health password entered process arguments'
        assert call['password'] == password, 'Redis did not receive its authentication environment'
        assert (result.returncode == 0) == (failure == '0')
        assert "synthetic password" not in result.stdout + result.stderr
    client = root / 'curl'
    client.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['CASE_CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:], 'stdin': sys.stdin.read()}))
print(json.dumps({'status': os.environ['CASE_HEALTH']}))
sys.exit(int(os.environ.get('CASE_FAIL', '0')))
''')
    client.chmod(0o755)
    for status, failure in [('green', '0'), ('yellow', '0'), ('red', '0'), ('green', '1')]:
        result = subprocess.run(['bash', 'Containers/fulltextsearch/healthcheck.sh'],
                                env=dict(env, ELASTIC_PASSWORD=password, CASE_HEALTH=status, CASE_FAIL=failure),
                                input='', capture_output=True, text=True, timeout=5)
        call = json.loads(capture.read_text())
        assert all(password not in word for word in call['argv']), 'Search health password entered process arguments'
        assert '--config' in call['argv'] and '-' in call['argv']
        import base64
        encoded = call['stdin'].split('Authorization: Basic ', 1)[1].strip().strip('"')
        assert base64.b64decode(encoded).decode() == 'elastic:' + password
        assert encoded not in result.stdout + result.stderr, 'Search health printed reusable authentication'
        assert (result.returncode == 0) == (failure == '0' and status != 'red')
        assert "synthetic password" not in result.stdout + result.stderr
    server = root / 'redis-server'
    server.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['CASE_CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:], 'stdin': sys.stdin.read()}))
''')
    server.chmod(0o755)
    sysctl = root / 'sysctl'
    sysctl.write_text('#!/bin/sh\nprintf 1\n')
    sysctl.chmod(0o755)
    for value in (password, ''):
        result = subprocess.run(['bash', 'Containers/redis/start.sh'], env=dict(env, REDIS_HOST_PASSWORD=value),
                                input='', capture_output=True, text=True, timeout=5)
        assert result.returncode == 0
        call = json.loads(capture.read_text())
        assert all(password not in word for word in call['argv']), 'Redis startup password entered process arguments'
        assert call['argv'][0] == '-'
        import hashlib
        expected = 'user default on resetpass #' + hashlib.sha256(password.encode()).hexdigest() + ' ~* &* +@all'
        assert call['stdin'].strip() == (expected if value else '')
        assert "synthetic password" not in result.stdout + result.stderr
PY
}
check service_secret_argv_cases

postgres_secret_argv_cases() {
  python3 - <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='aps database secret ') as directory:
    root = pathlib.Path(directory)
    capture = root / 'call.json'
    client = root / 'psql'
    client.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['CASE_CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:], 'stdin': sys.stdin.read(), 'password': os.environ.get('POSTGRES_PASSWORD'),
    'client_password': os.environ.get('PGPASSWORD')}))
sys.exit(int(os.environ['CASE_FAIL']))
''')
    client.chmod(0o755)
    password = "synthetic database password ' \" $ ;"
    env = dict(os.environ, PATH=directory + ':' + os.environ['PATH'], CASE_CAPTURE=str(capture),
               DUMP_DIR=directory, POSTGRES_PASSWORD=password, POSTGRES_USER='nextcloud',
               POSTGRES_DB='nextcloud_database', AIO_LOG_LEVEL='debug')
    marker = root / 'initialization.failed'
    for failure in ('0', '1'):
        result = subprocess.run(['bash', 'Containers/postgresql/init-user-db.sh'], env=dict(env, CASE_FAIL=failure),
                                capture_output=True, text=True, timeout=5)
        call = json.loads(capture.read_text())
        assert all(password not in word for word in call['argv']), 'PostgreSQL role password entered process arguments'
        assert call['password'] == password and '\\getenv pg_new_password POSTGRES_PASSWORD' in call['stdin']
        assert password not in call['stdin']
        assert 'synthetic database password' not in result.stdout + result.stderr
        assert (result.returncode == 0) == (failure == '0') and marker.exists() == (failure == '1')
    assert 'pg_new_password=' not in pathlib.Path('Containers/postgresql/start.sh').read_text()
    nc = root / 'nc'
    nc.write_text('#!/bin/sh\nexit 1\n')
    nc.chmod(0o755)
    health = pathlib.Path('Containers/postgresql/healthcheck.sh').read_text().replace(
        '"/mnt/data/backup-is-running"', '"$CASE_BACKUP_MARKER"')
    for failure in ('0', '1'):
        result = subprocess.run(['bash', '-c', health],
                                env=dict(env, CASE_FAIL=failure, CASE_BACKUP_MARKER=str(root / 'backup')),
                                input='', capture_output=True, text=True, timeout=5)
        call = json.loads(capture.read_text())
        assert call['client_password'] == password
        assert all(password not in word for word in call['argv'])
        assert (result.returncode == 0) == (failure == '0')
        assert 'synthetic database password' not in result.stdout + result.stderr, 'Database health check printed its password'
    prefix = pathlib.Path('Containers/postgresql/start.sh').read_text().split("# Don't start database", 1)[0]
    prefix += '\npython3 -c \'import os; assert os.environ["PGPASSWORD"] == os.environ["CASE_PASSWORD"]\'\n'
    result = subprocess.run(['bash', '-x', '-c', prefix], env=dict(env, CASE_PASSWORD=password),
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0
    assert 'synthetic database password' not in result.stdout + result.stderr, 'Database startup printed its password'
PY
}
check postgres_secret_argv_cases

nextcloud_install_secret_cases() {
  python3 - <<'PY'
import json, os, pathlib, re, subprocess, tempfile
entrypoint = pathlib.Path('Containers/nextcloud/entrypoint.sh').read_text()
helper = re.search(r'(?ms)^install_nextcloud\(\) \(\n.*?^\)\n', entrypoint)
start = entrypoint.index('            INSTALL_OPTIONS=(')
end = entrypoint.index('            # APS (R28):', start)
script = (helper.group() if helper else '') + '\n' + entrypoint[start:end]
script = script.replace('/var/www/html', '"$CASE_ROOT"').replace('/occ-install.php', '"$CASE_ADAPTER"')
with tempfile.TemporaryDirectory(prefix='aps install secret ') as directory:
    root = pathlib.Path(directory)
    (root / 'config').mkdir()
    (root / 'data').mkdir()
    capture = root / 'call.json'
    (root / 'occ').write_text('''<?php
file_put_contents(getenv('CASE_CAPTURE'), json_encode([
    'argv' => $argv, 'argc' => $argc, 'server_argv' => $_SERVER['argv'], 'server_argc' => $_SERVER['argc'],
    'os_argv' => explode("\\0", file_get_contents('/proc/self/cmdline'))], JSON_THROW_ON_ERROR));
exit((int)getenv('CASE_FAIL'));
''')
    admin = "synthetic admin password ' \" $ ;\nnext line"
    database = "synthetic database password ' \" $ ;\nnext line"
    env = dict(os.environ, CASE_ROOT=directory, CASE_CAPTURE=str(capture),
               CASE_ADAPTER=str(pathlib.Path('Containers/nextcloud/occ-install.php').resolve()),
               ADMIN_USER='fixture.admin', ADMIN_PASSWORD=admin, DATABASE_TYPE='pgsql',
               POSTGRES_DB='fixture_database', POSTGRES_USER='fixture_user', POSTGRES_PASSWORD=database,
               POSTGRES_HOST='database.invalid', POSTGRES_PORT='', NEXTCLOUD_DATA_DIR=str(root / 'data'))
    for failure in ('0', '1'):
        result = subprocess.run(['bash', '-x', '-c', script], env=dict(env, CASE_FAIL=failure),
                                capture_output=True, text=True, timeout=5)
        call = json.loads(capture.read_text())
        assert all(value not in word for value in (admin, database) for word in call['os_argv']), 'Nextcloud installation passwords entered process arguments'
        args = call['argv']
        def option(name):
            joined = next((word[len(name)+1:] for word in args if word.startswith(name+'=')), None)
            return joined if joined is not None else args[args.index(name)+1]
        assert args[1] == 'maintenance:install' and option('--admin-pass') == admin and option('--database-pass') == database
        assert option('--admin-user') == 'fixture.admin' and option('--data-dir') == str(root / 'data')
        assert option('--database-port') == '5432' and call['server_argv'] == args
        assert call['argc'] == call['server_argc'] == len(args)
        assert (result.returncode == 0) == (failure == '0')
        assert (root / 'data/install.failed').exists() == (failure == '1')
        assert all(marker not in result.stdout + result.stderr for marker in ('synthetic admin password', 'synthetic database password'))
PY
}
check nextcloud_install_secret_cases

nextcloud_database_secret_cases() {
  python3 - <<'PY'
import json, os, pathlib, re, subprocess, sys, tempfile
source = pathlib.Path('Containers/nextcloud/start.sh').read_text()
helper = re.search(r'(?ms)^repair_database_connection\(\) \(\n.*?^\)\n', source)
start = source.index('# Fix false database connection')
end = source.index('# Trust additional Cacerts', start)
script = (helper.group() if helper else '') + '\n' + source[start:end]
script = script.replace('"/var/www/html/', '"$CASE_ROOT/').replace('/var/www/html/', '"$CASE_ROOT"/')
with tempfile.TemporaryDirectory(prefix='aps database repair ') as directory:
    root = pathlib.Path(directory)
    (root / 'config').mkdir()
    (root / 'config/config.php').write_text("<?php $CONFIG = ['dbuser'=>'legacy', 'dbpassword'=>'old', 'dbname'=>'nextcloud_database'];\n")
    calls, imported = root / 'calls.jsonl', root / 'import.json'
    shim = root / 'su-exec'
    shim.write_text('#!' + sys.executable + '\n' + '''
import json, os, sys
with open(os.environ['CASE_CALLS'], 'a') as output:
    output.write(json.dumps({'argv': sys.argv[1:], 'password': os.environ.get('PGPASSWORD')}) + '\\n')
os.execvp(sys.argv[2], sys.argv[2:])
''')
    shim.chmod(0o755)
    for name in ('psql', 'sleep'):
        path = root / name
        path.write_text('#!/bin/sh\nexit 0\n')
        path.chmod(0o755)
    (root / 'occ').write_text('''<?php
file_put_contents(getenv('CASE_IMPORT'), json_encode([
    'data' => json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR),
    'user' => getenv('NC_dbuser'), 'password' => getenv('NC_dbpassword'), 'database' => getenv('NC_dbname')], JSON_THROW_ON_ERROR));
''')
    for password in ('fixturecredential196', "synthetic repair password ' \" $ ;\nnext line"):
        calls.unlink(missing_ok=True)
        env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], CASE_ROOT=directory,
                   CASE_CALLS=str(calls), CASE_IMPORT=str(imported), POSTGRES_USER='oc_nextcloud',
                   POSTGRES_DB='nextcloud_database', POSTGRES_HOST='database.invalid', POSTGRES_PORT='5432',
                   POSTGRES_PASSWORD=password, AIO_LOG_LEVEL='debug')
        result = subprocess.run(['bash', '-x', '-c', script], env=env, capture_output=True, text=True, timeout=5)
        records = [json.loads(line) for line in calls.read_text().splitlines()]
        assert all(password not in word for call in records for word in call['argv']), 'Database repair password entered process arguments'
        assert result.returncode == 0
        psql = [call for call in records if 'psql' in call['argv']]
        assert len(psql) == 1 and psql[0]['password'] == password
        data = json.loads(imported.read_text())
        assert data['data'] == {'system': {'dbuser': 'oc_nextcloud', 'dbpassword': password, 'dbname': 'nextcloud_database'}}
        assert (data['user'], data['password'], data['database']) == ('oc_nextcloud', password, 'nextcloud_database')
        assert all(marker not in result.stdout + result.stderr for marker in ('fixturecredential196', 'synthetic repair password'))
PY
}
check nextcloud_database_secret_cases

backup_secret_argv_cases() {
  python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
source = pathlib.Path('Containers/borgbackup/backupscript.sh').read_text()
start = source.index('    # Reset the AIO password to the currently used one')
end = source.index('    # Reset the datadir', start)
script = source.split('# Functions', 1)[0] + '\n' + source[start:end]
script = script.replace('/nextcloud_aio_volumes/nextcloud_aio_mastercontainer/data/configuration.json', '"$CASE_CONFIG"')
with tempfile.TemporaryDirectory(prefix='aps backup secret ') as directory:
    root = pathlib.Path(directory)
    config, calls = root / 'config.json', root / 'calls.jsonl'
    config.write_text(json.dumps({'password': 'old', 'retained': 'keep'}))
    wrapper = root / 'jq'
    wrapper.write_text('#!' + sys.executable + '\n' + '''
import json, os, sys
with open(os.environ['CASE_CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
os.execv(os.environ['REAL_JQ'], [os.environ['REAL_JQ'], *sys.argv[1:]])
''')
    wrapper.chmod(0o755)
    password = "synthetic backup password ' \" \\ $ ;\nnext line"
    env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], REAL_JQ=shutil.which('jq'),
               CASE_CONFIG=str(config), CASE_CALLS=str(calls), AIO_PASSWORD=json.dumps(password), AIO_LOG_LEVEL='debug')
    result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True, timeout=5)
    assert result.returncode == 0
    records = [json.loads(line) for line in calls.read_text().splitlines()]
    assert all('synthetic backup password' not in word for call in records for word in call), 'Backup password entered process arguments'
    assert json.loads(config.read_text()) == {'password': password, 'retained': 'keep'}
    assert 'synthetic backup password' not in result.stdout + result.stderr
    startup = pathlib.Path('Containers/borgbackup/start.sh').read_text().split('export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK', 1)[0]
    startup += '\npython3 -c \'import os; assert os.environ["BORG_PASSPHRASE"] == os.environ["CASE_EXPECTED"]\'\n'
    for restored in ('', password + ' restored'):
        result = subprocess.run(['bash', '-c', startup],
                                env=dict(env, BORG_PASSWORD=password, BACKUP_RESTORE_PASSWORD=restored, CASE_EXPECTED=restored or password),
                                capture_output=True, text=True, timeout=5)
        assert result.returncode == 0
        assert 'synthetic backup password' not in result.stdout + result.stderr
PY
}
check backup_secret_argv_cases

talk_turn_secret_cases() {
  python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
source = pathlib.Path('Containers/talk/start.sh').read_text()
start = source.index('# Configure Janus to use the local TURN server')
end = source.index('# Janus and eTURNAL share', start)
script = source[start:end] + '\nprintf "%s\\n" "$JANUS_TURN_PWD"\n'
with tempfile.TemporaryDirectory(prefix='aps turn secret ') as directory:
    root = pathlib.Path(directory)
    capture = root / 'calls.jsonl'
    for program in ('openssl', 'erl'):
        path = root / program
        path.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
program = pathlib.Path(sys.argv[0]).name
with open(os.environ['CASE_CALLS'], 'a') as output:
    output.write(json.dumps({'program': program, 'argv': sys.argv[1:],
                            'secret': os.environ.get('TURN_SECRET'), 'user': os.environ.get('JANUS_TURN_USER')}) + '\\n')
if program == 'openssl': os.execv(os.environ['REAL_OPENSSL'], [os.environ['REAL_OPENSSL'], *sys.argv[1:]])
if os.environ.get('CASE_FAIL') == '1': sys.exit(1)
print('fixture-derived-turn-password')
''')
        path.chmod(0o755)
    secret = "synthetic TURN secret ' \" \\ $ ;\nnext line"
    env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], CASE_CALLS=str(capture),
               REAL_OPENSSL=shutil.which('openssl'), TURN_SECRET=secret)
    for failure in ('0', '1'):
        capture.unlink(missing_ok=True)
        result = subprocess.run(['bash', '-x', '-c', script], env=dict(env, CASE_FAIL=failure),
                                capture_output=True, text=True, timeout=5)
        calls = [json.loads(line) for line in capture.read_text().splitlines()]
        assert all(secret not in word for call in calls for word in call['argv']), 'TURN shared secret entered process arguments'
        clients = [call for call in calls if call['program'] == 'erl']
        assert len(clients) == 1 and clients[0]['secret'] == secret
        assert clients[0]['user'] and 'os:getenv("TURN_SECRET")' in clients[0]['argv'][-1]
        assert (result.returncode == 0) == (failure == '0')
        assert ('fixture-derived-turn-password' in result.stdout) == (failure == '0')
        assert 'synthetic TURN secret' not in result.stdout + result.stderr
        assert 'fixture-derived-turn-password' not in result.stderr
PY
}
check talk_turn_secret_cases

imaginary_secret_argv_cases() {
  python3 - <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='aps imaginary secret ') as directory:
    root = pathlib.Path(directory)
    capture = root / 'call.json'
    client = root / 'imaginary'
    client.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['CASE_CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:], 'secret': os.environ.get('IMAGINARY_SECRET')}))
sys.exit(int(os.environ.get('CASE_FAIL', '0')))
''')
    client.chmod(0o755)
    secret = "synthetic Imaginary secret ' \" \\ $ ;\nnext line"
    env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], CASE_CAPTURE=str(capture),
               IMAGINARY_SECRET=secret, AIO_LOG_LEVEL='debug')
    for failure in ('0', '1'):
        result = subprocess.run(['bash', 'Containers/imaginary/start.sh', '-concurrency', '2'],
                                env=dict(env, CASE_FAIL=failure), capture_output=True, text=True, timeout=5)
        call = json.loads(capture.read_text())
        assert all(secret not in word for word in call['argv']), 'Imaginary API key entered process arguments'
        assert call['secret'] == secret, 'Imaginary did not receive the exact environment key'
        assert call['argv'] == ['-return-size', '-max-allowed-resolution', '222.2', '-concurrency', '2']
        assert (result.returncode == 0) == (failure == '0')
        assert 'synthetic Imaginary secret' not in result.stdout + result.stderr
PY
}
check imaginary_secret_argv_cases

cleanboot_secret_argv_cases() {
  python3 - <<'PY'
import base64, json, os, pathlib, re, shutil, subprocess, sys, tempfile, textwrap
source = pathlib.Path('.github/workflows/cleanboot.yml').read_text()
anchor = 'grep -q "occ group:delete deriva-prueba" "$RUNNER_TEMP/estado.out"\n'
fragment = source.split(anchor, 1)[1].split('          occ group:delete deriva-prueba', 1)[0]
with tempfile.TemporaryDirectory(prefix='aps cleanboot secret ') as directory:
    root = pathlib.Path(directory)
    capture = root / 'call.json'
    client = root / 'curl'
    client.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['CASE_CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:], 'stdin': sys.stdin.read()}))
print('deriva-prueba')
sys.exit(int(os.environ.get('CASE_FAIL', '0')))
''')
    client.chmod(0o755)
    password = "synthetic notification password ' \" \\ $ ;\nnext line"
    env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], CASE_CAPTURE=str(capture),
               NEXTCLOUD_ADMIN_USER='fixture.admin', NEXTCLOUD_ADMIN_PASSWORD=password,
               SUITE_CA='/public/ca.crt', SUITE_IP='192.0.2.1')
    for failure in ('0', '1'):
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-x', '-c', textwrap.dedent(fragment)],
                                env=dict(env, CASE_FAIL=failure), input='', capture_output=True, text=True, timeout=5)
        call = json.loads(capture.read_text())
        assert all(password not in word for word in call['argv']), 'Cleanboot administrator password entered process arguments'
        assert '--config' in call['argv'] and '--cacert' in call['argv'] and env['SUITE_CA'] in call['argv']
        encoded = call['stdin'].split('Authorization: Basic ', 1)[1].strip().strip('"')
        assert base64.b64decode(encoded).decode() == 'fixture.admin:' + password
        assert (result.returncode == 0) == (failure == '0')
        assert 'synthetic notification password' not in result.stdout + result.stderr
        assert encoded not in result.stdout + result.stderr
    client = root / 'sed'
    client.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
pathlib.Path(os.environ['CASE_CAPTURE']).write_text(json.dumps({'argv': sys.argv[1:]}))
os.execv(os.environ['REAL_SED'], [os.environ['REAL_SED'], *sys.argv[1:]])
''')
    client.chmod(0o755)
    (root / '.env.example').write_text('RETAINED=yes\nFIXTURE_USER_PASSWORD=change-me\n')
    blocks = re.findall(r'^          pkg=/opt/aps-conecta/instalador\n.*?^          chmod 600 "\$pkg/.env"$', source, re.M | re.S)
    assert len(blocks) == 2
    for block in blocks:
        script = textwrap.dedent(block).replace('pkg=/opt/aps-conecta/instalador', 'pkg="$CASE_PACKAGE"')
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                                env=dict(env, CASE_PACKAGE=directory, REAL_SED=shutil.which('sed')),
                                input='', capture_output=True, text=True, timeout=5)
        assert result.returncode == 0
        settings = dict(line.split('=', 1) for line in (root / '.env').read_text().splitlines())
        password = settings['FIXTURE_USER_PASSWORD']
        assert re.fullmatch('[0-9a-f]{64}', password) and settings['RETAINED'] == 'yes'
        assert all(password not in word for word in json.loads(capture.read_text())['argv']), 'Cleanboot fixture password entered process arguments'
        assert password not in result.stdout + result.stderr
        assert (root / '.env').stat().st_mode & 0o777 == 0o600
PY
}
check cleanboot_secret_argv_cases

aia_private_temp_cases() {
  python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile, uuid
with tempfile.TemporaryDirectory(prefix='aps ca test ') as directory:
    root = pathlib.Path(directory)
    host_tmp = root / 'host tmp'
    host_tmp.mkdir()
    for failure in ('none', 'transfer', 'permissions', 'import', 'invalid_temp'):
        capture, cleanup = root / 'copy.json', root / 'cleanup.txt'
        capture.unlink(missing_ok=True)
        cleanup.unlink(missing_ok=True)
        name = 'aps-196-' + uuid.uuid4().hex
        env = dict(os.environ, CASE_CAPTURE=str(capture), CASE_CLEANUP=str(cleanup),
                   CASE_CA_NAME=name, CASE_CA_FAILURE=failure, TMPDIR=str(host_tmp))
        setup = 'set -e\nsource scripts/env.sh\nsource provisioning/lib.sh\n'
        result = subprocess.run(['bash', '-c', setup + r'''
docker() {
  local source='' destination transport
  if [ "$1" = cp ]; then
    source="$2"; destination="$3"; transport=copy
  elif [[ "$*" == *'cat > "$1"'* ]]; then
    source=/proc/self/fd/0; destination="${@: -1}"; transport=stdin
  fi
  if [ -n "$source" ]; then
    python3 -c '
import json, os, pathlib, sys
source = pathlib.Path(sys.argv[1]).resolve()
pathlib.Path(os.environ["CASE_CAPTURE"]).write_text(json.dumps({
    "source": str(source), "destination": sys.argv[2],
    "directory_mode": source.parent.stat().st_mode & 0o777,
    "file_mode": source.stat().st_mode & 0o777, "transport": sys.argv[3]}))
' "$source" "$destination" "$transport"
    [ "$CASE_CA_FAILURE" != transfer ]; return
  fi
  case "$*" in
    *s_client*) printf 'http://example.test/%s.crt\n\nLEAF\n' "$CASE_CA_NAME" ;;
    *'mktemp -d'*)
      if [ "$CASE_CA_FAILURE" = invalid_temp ]; then echo /tmp/unowned; else echo /tmp/aps-ca.ABCDEF1234; fi ;;
    *'openssl verify'*) echo PEM ;;
    *'chown -R'*) [ "$CASE_CA_FAILURE" != permissions ]; return ;;
    *'rm -rf'*) printf '%s\n' "$*" >> "$CASE_CLEANUP" ;;
  esac
  return 0
}
occ() {
  case "$1" in
    security:certificates) echo '[]' ;;
    security:certificates:import) [ "$CASE_CA_FAILURE" != import ] ;;
  esac
}
ensure_aia_intermediate example.test
'''], env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
        assert not list(host_tmp.iterdir()), 'Host certificate temporary files were not removed'
        if failure == 'invalid_temp':
            assert not capture.exists() and not cleanup.exists(), 'An unowned container path was used'
            continue
        call = json.loads(capture.read_text())
        assert call['transport'] == 'stdin', 'Certificate transfer bypasses the running temporary mount'
        assert call['directory_mode'] == 0o700, 'AIA certificate uses a shared temporary directory'
        assert call['file_mode'] == 0o600, 'AIA certificate temporary file is not private'
        source = pathlib.Path(call['source'])
        assert source.name == name + '.pem' and not source.parent.exists()
        assert call['destination'] == '/tmp/aps-ca.ABCDEF1234/' + source.name
        assert '/tmp/aps-ca.ABCDEF1234' in cleanup.read_text()
        assert ('imported ' in result.stdout) == (failure == 'none')
PY
}
check aia_private_temp_cases

provisioning_has_no_shared_temp_paths() {
  python3 - <<'PY'
import pathlib, re
for path in pathlib.Path('provisioning').rglob('*.sh'):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith('#') or '/tmp/' not in line:
            continue
        private_template = re.search(r'mktemp -d /tmp/[a-z-]+\.X{10}', line)
        validated_result = '=~ ^/tmp/' in line
        assert private_template or validated_result, f'{path}:{number}: shared temporary path'
PY
}
check provisioning_has_no_shared_temp_paths

secret_command_arguments_absent() {
  python3 - <<'PY'
import pathlib, re
for root in ('Containers', 'provisioning'):
    for path in pathlib.Path(root).rglob('*.sh'):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith('#'):
                continue
            secret = re.search(r'--value[^\n]*\$\{?[A-Z_]*(?:SECRET|PASSWORD|TOKEN|RECORDING_SERVERS_STRING|SUBSCRIPTION_KEY)', line)
            assert not secret, f'{path}:{number}: secret passed to an occ value argument'
            assert not re.search(r'\bredis-cli\b[^\n]*\s-a(?:\s|=)', line), f'{path}:{number}: Redis password argument'
PY
}
check secret_command_arguments_absent

trusted_proxy_network_cases() {
  python3 - <<'PY'
import os, pathlib, subprocess, tempfile
helper = pathlib.Path('Containers/network-prefix.sh').resolve()
def check(value, expected=None, env=None):
    result = subprocess.run(['bash', str(helper), *value], capture_output=True, text=True, env=env, timeout=5)
    assert (result.returncode == 0) == (expected is not None), (value, result.stderr)
    assert result.stdout == (expected + '\n' if expected is not None else ''), (value, result.stdout)
for value, expected in [
    ('192.168.48.3/20', '192.168.48.0/20'), ('172.19.7.25/16', '172.19.0.0/16'),
    ('10.77.3.9/23', '10.77.2.0/23'), ('192.168.48.3/24', '192.168.48.0/24'),
    ('192.168.48.3/31', '192.168.48.2/31'), ('192.168.48.3/32', '192.168.48.3/32'),
    ('192.168.48.3/0', '0.0.0.0/0'), ('192.168.48.3/1', '128.0.0.0/1')]:
    check([value], expected)
for value in ['', '192.168.48.3', '192.168.48.3/33', '192.168.48.3/-1',
              '256.168.48.3/20', '192.168.048.3/20', '192.168.48.3/020', '::1/128',
              '192.168.48.3/20\n10.0.0.1/8', 'x/20']:
    check([value])
with tempfile.TemporaryDirectory(prefix='proxy-network-') as tmp:
    root = pathlib.Path(tmp)
    for name, body in [('dig', 'printf "%s\\n" "$CASE_DNS"\n'), ('ip', 'printf "%s\\n" "$CASE_ADDR"\n')]:
        path = root / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)
    env = dict(os.environ, PATH=tmp + os.pathsep + os.environ['PATH'], CASE_DNS='192.168.48.3',
               CASE_ADDR='2: eth0 inet 192.168.48.3/20 brd 192.168.63.255 scope global eth0\n3: eth1 inet 10.9.0.2/24 scope global eth1')
    check(['--host', 'aps-conecta-nextcloud'], '192.168.48.0/20', env)
    for dns, addresses in [('', env['CASE_ADDR']), ('192.168.32.3', env['CASE_ADDR']),
                           ('192.168.48.3', ''), ('192.168.48.3\n10.9.0.2', env['CASE_ADDR'])]:
        check(['--host', 'aps-conecta-nextcloud'], env=dict(env, CASE_DNS=dns, CASE_ADDR=addresses))
print('actual container prefixes and ambiguous discovery checked')
PY
}
check trusted_proxy_network_cases

antivirus_limit_cases() {
  python3 - <<'PY'
import pathlib, subprocess
helper = pathlib.Path('Containers/antivirus-limit.sh').resolve()
for value, expected in [
    ('1M', '1048576'), ('1G', '1073741824'), ('2000M', '2097152000'),
    ('2G', '2147483645'), ('2147483645', '2147483645'),
    ('2147483646', '2147483645'), ('0001m', '1048576'), ('64K', '65536'),
    ('999999999999999999999G', '2147483645')]:
    result = subprocess.run(['bash', str(helper), value], capture_output=True, text=True, timeout=3)
    assert result.returncode == 0 and result.stdout == expected + '\n', (value, result.stdout, result.stderr)
for value in ['', '0', '000G', '-1', '1.5G', '1T', '1G\n2G', '1 M', '1M;true']:
    result = subprocess.run(['bash', str(helper), value], capture_output=True, text=True, timeout=3)
    assert result.returncode != 0 and not result.stdout and result.stderr, (value, result.stdout, result.stderr)
print('one bounded antivirus content budget accepts units and refuses invalid input')
PY
}
check antivirus_limit_cases

testbed_install_command_cases() {
  local tmp py out
  tmp="$(mktemp -d)"; py="$(command -v python3)"
  mkdir -p "$tmp"/{scripts,host,php,bin}
  cp host/aps-conecta "$tmp/host/"
  cp scripts/{images.py,apps.py} "$tmp/scripts/"
  cp php/containers.json "$tmp/php/"
  cp apps.json VERSION "$tmp/"
  sed '/^case "${1:-}" in/,$d; s|\[ -S /var/run/docker.sock \]|true|' scripts/aio-testbed.sh > "$tmp/scripts/bed.sh"
  cat >> "$tmp/scripts/bed.sh" <<'SH'
STATE="$CASE_ROOT/state"
check_ram() { :; }
cmd_up
SH
  cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  version) echo 1.44 ;;
  info) printf '%s\n' "$CASE_ROOT" ;;
  inspect) exit 1 ;;
  run) printf 'run\n' >> "$CASE_ROOT/events"; printf '%s\0' "$@" > "$CASE_ROOT/run" ;;
  exec) case "$*" in *'config:system:get appstoreenabled') echo 0;; esac ;;
esac
SH
  cat > "$tmp/bin/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *addr*) echo '2: eth0 inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0' ;;
  *) echo '1.1.1.1 via 203.0.113.1 dev eth0 src 203.0.113.10' ;;
esac
SH
  cat > "$tmp/bin/python3" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'--paso certificado-suite'*) printf 'certificate\n' >> "$CASE_ROOT/events" ;;
  *) exec "$CASE_PYTHON" "$@" ;;
esac
SH
  printf '#!/bin/sh\ncase "$*" in *ghcr.io*) printf 401;; esac\n' > "$tmp/bin/curl"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/ss"
  cp "$tmp/bin/ss" "$tmp/bin/sleep"
  printf '#!/bin/sh\necho "character special file"\n' > "$tmp/bin/stat"
  printf '#!/bin/sh\nprintf "Avail\\n142\\n"\n' > "$tmp/bin/df"
  printf '#!/bin/sh\necho 1\n' > "$tmp/bin/seq"
  chmod +x "$tmp/bin/"*
  out="$(PATH="$tmp/bin:$PATH" APS_HOME="$tmp/home" bash scripts/aio-testbed.sh status 2>&1)" || true
  [[ "$out" == *"no secrets in $tmp/home/aio"* ]] \
    || { echo "testbed status ignores APS_HOME: $out" >&2; rm -rf "$tmp"; return 1; }
  out="$(PATH="$tmp/bin:$PATH" CASE_ROOT="$tmp" CASE_PYTHON="$py" APS_HOME="$tmp/home" \
    AIO_POLL=0 AIO_TEST_IMAGE=ghcr.io/aps-conecta/all-in-one:v9.9.9 \
    bash "$tmp/scripts/bed.sh" 2>&1)" || true
  APS_HOME="$tmp/home" APS_SUITE_TAG=v9.9.9 bash "$tmp/host/aps-conecta" run-command 203.0.113.10 > "$tmp/expected"
  "$py" - "$tmp" .github/workflows/cleanboot.yml <<'PY'
import pathlib, shlex, sys
root = pathlib.Path(sys.argv[1])
actual = (root / 'run').read_bytes().decode().rstrip('\0').split('\0')
actual = [arg for arg in actual if arg != '-d']
expected = shlex.split((root / 'expected').read_text().replace('\\\n', ''))[1:]
assert actual == expected, f'testbed run differs from installer: {actual!r} != {expected!r}'
assert (root / 'events').read_text().splitlines() == ['certificate', 'run'], 'certificate must precede installer run'
workflow = pathlib.Path(sys.argv[2]).read_text()
lifecycle = workflow.split('\n  cleanboot:', 1)[1].split('\n  cleanboot-ip:', 1)[0]
bootstrap = lifecycle.index('- name: Build the rehearsal package, then install through the real bootstrap')
startup = lifecycle.index('- name: Bring up the disposable AIO instance through the installer')
assert bootstrap < startup, 'bootstrap must establish the package before suite containers exist'
assert '/opt/aps-conecta/instalador/scripts/aio-testbed.sh up' in lifecycle[startup:], 'startup must use the verified package'

PY
  local rc=$?
  if [ "$rc" = 0 ]; then
    printf '#!/bin/sh\nexit 0\n' > "$tmp/host/aps-conecta"
    sed '/^case "${1:-}" in/,$d; s|\[ -S /var/run/docker.sock \]|true|' scripts/aio-testbed.sh > "$tmp/scripts/bed.sh"
    cat >> "$tmp/scripts/bed.sh" <<'SH'
STATE="$CASE_ROOT/banner-state"
check_ram() { :; }
cmd_up > "$CASE_ROOT/without-passwords"
printf 'fixture\n' > "$STATE/master.pw"
printf 'fixture\n' > "$STATE/nextcloud.pw"
cmd_up > "$CASE_ROOT/with-passwords"
SH
    out="$(PATH="$tmp/bin:$PATH" CASE_ROOT="$tmp" AIO_TEST_IMAGE=ghcr.io/aps-conecta/all-in-one:v9.9.9 \
      bash "$tmp/scripts/bed.sh" 2>&1)" || true
    "$py" - "$tmp" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
without = (root / 'without-passwords').read_text().split('✓ probe instance up:', 1)[1]
with_passwords = (root / 'with-passwords').read_text().split('✓ probe instance up:', 1)[1]
for name in ('master.pw', 'nextcloud.pw'):
    path = str(root / 'banner-state' / name)
    assert path not in without, f'testbed advertises nonexistent credential file: {name}'
    assert path in with_passwords, f'testbed omits existing credential file: {name}'
PY
    rc=$?
  fi
  [ "$rc" = 0 ] || printf '%s\n' "$out" >&2
  rm -rf "$tmp"
  return "$rc"
}
check testbed_install_command_cases

# #204: check token defaults and checkout persistence, then let ShellCheck parse
# each run block for SC2251 (a negation that silently skips errexit).
workflow_safety_cases() {
  python3 - "${1:-.github/workflows}" <<'PY'
import json, os, pathlib, re, subprocess, sys, tempfile, textwrap


def policy(text, name):
    errors = []
    lines = text.splitlines()
    def block_after(start, parent_indent):
        block = []
        for following in lines[start + 1:]:
            if following.strip() and not following.lstrip().startswith('#') and len(following) - len(following.lstrip()) <= parent_indent:
                break
            block.append(following)
        return block

    permissions = {}
    top = next((i for i, line in enumerate(lines) if line.startswith('permissions:')), None)
    if top is not None and re.fullmatch(r'permissions:\s*(?:#.*)?', lines[top]):
        for entry in block_after(top, 0):
            if not entry.strip() or entry.lstrip().startswith('#'):
                continue
            match = re.fullmatch(r"  ([\w-]+):\s*(read|write|none|'(?:read|write|none)'|\"(?:read|write|none)\")(?:\s+#.*)?\s*", entry)
            if not match:
                errors.append("unparsed workflow permission entry: " + entry.strip())
            else:
                permissions[match[1]] = match[2].strip("\"'")
    # A reusable publisher must advertise its caller's package-write ceiling.
    allowed_write = {"packages"} if name == "images.yml" else set()
    if permissions.get("contents") != "read" or any(
        value == "write" and key not in allowed_write for key, value in permissions.items()
    ):
        errors.append("workflow defaults must be read-only (Images keeps its package publishing ceiling)")
    for index, line in enumerate(lines):
        if re.match(r'^\s+(?:- )?uses: actions/checkout@', line):
            indent = len(line) - len(line.lstrip()) + (2 if line.lstrip().startswith('- ') else 0)
            step = block_after(index, indent - 1)
            with_offset = next((i for i, item in enumerate(step)
                                if re.fullmatch(' ' * indent + r'with:\s*(?:#.*)?', item)), None)
            credentials = []
            if with_offset is not None:
                for item in step[with_offset + 1:]:
                    if item.strip() and not item.lstrip().startswith('#') and len(item) - len(item.lstrip()) <= indent:
                        break
                    if re.fullmatch(' ' * (indent + 2) + r'persist-credentials: (?:false|"false"|\'false\')(?:\s+#.*)?', item):
                        credentials.append(item)
            if len(credentials) != 1:
                errors.append(f"line {index + 1}: checkout must set with.persist-credentials: false")
        run = re.match(r'^(\s+)(?:- )?run:\s*(.*)$', line)
        if not run:
            continue
        value = run[2]
        if value.startswith('|'):
            body = []
            indent = len(run[1]) + (2 if line.lstrip().startswith('- ') else 0)
            for following in lines[index + 1:]:
                if following.strip() and len(following) - len(following.lstrip()) <= indent:
                    break
                body.append(following)
            script = textwrap.dedent('\n'.join(body))
        elif value.startswith('>'):
            errors.append(f"line {index + 1}: use a literal run block so shell assertions can be checked")
            continue
        elif value.startswith("'") and value.endswith("'"):
            script = value[1:-1].replace("''", "'")
        elif value.startswith('"'):
            script = json.loads(value)
        else:
            script = value
        script = re.sub(r'\$\{\{.*?\}\}', 'workflow_value', script, flags=re.S)
        result = subprocess.run(['shellcheck', '--norc', '-s', 'bash', '-i', 'SC2251', '-'],
                                input='set -e\n' + script, text=True, capture_output=True)
        if result.returncode:
            errors.append(f"line {index + 1}: unsafe or unparseable shell assertion\n{result.stdout}{result.stderr}")
    return errors


fixture = '''permissions:
  contents: read
jobs:
  check:
    steps:
      - uses: actions/checkout@fixed
        with:
          persist-credentials: false
      - run: |
          echo checked
'''
assert not policy(fixture, 'fixture.yml')
for bad in [fixture.replace('permissions:\n  contents: read\n', ''),
            fixture.replace('contents: read', 'contents: write'),
            fixture.replace('contents: read', 'contents: read\n  issues: write'),
            fixture.replace('contents: read', 'contents: read\n  issues: \"write\"'),
            fixture.replace('with:\n          persist-credentials: false', 'env:\n          persist-credentials: false'),
            fixture.replace('persist-credentials: false', 'persist-credentials: true'),
            fixture.replace('          persist-credentials: false\n', ''),
            fixture.replace('echo checked', '! grep pattern file\n          echo checked')]:
    assert policy(bad, 'fixture.yml'), 'an unsafe workflow fixture passed'
assert not policy(fixture.replace('echo checked', '! grep pattern file'), 'fixture.yml')
assert not policy(fixture.replace('echo checked', 'if grep pattern file; then exit 1; fi'), 'fixture.yml')
assert not policy(fixture.replace('contents: read', 'contents: read\n  packages: write'), 'images.yml')
workflow = pathlib.Path(sys.argv[1]) / 'cleanboot.yml'
if workflow.exists():
    step = workflow.read_text().split('      - name: The silent install printed only Spanish lines\n', 1)[1].split('\n      - name:', 1)[0]
    script = textwrap.dedent(step.split('        run: |\n', 1)[1])
    fingerprint = 'D5:00:01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:10:11:12:13:14:15:16:17:18:19:1A:1B:1C:1D:1E'
    output = f'INSTALACIÓN: ✓\nCertificado del servidor (huella SHA-256 {fingerprint})\n'
    with tempfile.TemporaryDirectory(prefix='install-language-') as tmp:
        for extra, expected in [('', 0), ('warning: unexpected output\n', 1), ('Referencia interna D5\n', 1)]:
            pathlib.Path(tmp, 'install.out').write_text(output + extra)
            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], env=dict(os.environ, RUNNER_TEMP=tmp), capture_output=True, text=True)
            assert result.returncode == expected, f'language gate rejected a valid fingerprint or accepted unexpected output: {extra!r}'
failures = []
paths = sorted(pathlib.Path(sys.argv[1]).glob('*.yml'))
assert paths, 'no workflows were checked'
for path in paths:
    failures.extend(f'{path}: {error}' for error in policy(path.read_text(), path.name))
if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('workflow permission, checkout and shell-assertion checks passed')
PY
}
check workflow_safety_cases

# Run the actual wrapper with external tools replaced: no package installation or network.
validator_failure_cases() {
  python3 - <<'PY'
import os, pathlib, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix='validator-cases-') as tmp:
    root = pathlib.Path(tmp)
    tools = root / 'bin'
    tools.mkdir()
    tree = root / 'tree'
    (tree / 'Containers/example').mkdir(parents=True)
    (tree / 'Containers/example/Dockerfile').write_text('FROM scratch\n')
    def tool(name, body):
        path = tools / name
        path.write_text('#!/usr/bin/env bash\n' + body)
        path.chmod(0o755)
    tool('python3', '''[ "$1" = -m ] && [ "$2" = venv ] || exit 90
mkdir -p "$3/bin"
for cmd in pip codespell json; do printf '#!/bin/sh\\nexit 0\\n' > "$3/bin/$cmd"; chmod +x "$3/bin/$cmd"; done
''')
    tool('wget', '''while [ "$#" -gt 0 ]; do if [ "$1" = -O ]; then cp "$FAKE_HADOLINT" "$2"; exit; fi; shift; done
exit 91
''')
    tool('curl', '''while [ "$#" -gt 0 ]; do if [ "$1" = --output ] || [ "$1" = -o ]; then cp "$FAKE_HADOLINT" "$2"; exit; fi; shift; done
exit 91
''')
    # This test isolates wrapper failure propagation. ci_tool_cases separately
    # rejects corrupted bytes with the real checksum tool.
    tool('sha256sum', 'cat >/dev/null\nexit 0\n')
    fake = root / 'hadolint'
    fake.write_text('#!/usr/bin/env bash\n[ -z "$LINT_OUTPUT" ] || echo "$LINT_OUTPUT"\nexit "$LINT_EXIT"\n')
    fake.chmod(0o755)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], FAKE_HADOLINT=str(fake))
    for status, output, success in [(0, '', True), (126, '', False), (1, 'finding', False), (0, 'finding', False)]:
        result = subprocess.run(['bash', 'scripts/validate.sh', str(tree)],
                                env=dict(env, LINT_EXIT=str(status), LINT_OUTPUT=output),
                                text=True, capture_output=True, timeout=15)
        assert (result.returncode == 0) == success, f'linter status {status}, output {output!r}: {result.stdout}{result.stderr}'
print('validator propagates failed tools and findings')
PY
}
check validator_failure_cases

ci_tool_cases() {
  python3 - <<'PY'
import io, os, pathlib, re, shutil, subprocess, tarfile, tempfile
with tempfile.TemporaryDirectory(prefix='ci-tool-cases-') as tmp:
    root = pathlib.Path(tmp)
    tools = root / 'bin'
    tools.mkdir()
    payload = b'#!/bin/sh\nprintf "fixture tool\\n"\n'
    binary = root / 'fixture-binary'
    binary.write_bytes(payload)
    archive = root / 'fixture-archive'
    with tarfile.open(archive, 'w:gz') as tar:
        entry = tarfile.TarInfo('gitleaks')
        entry.size = len(payload)
        tar.addfile(entry, io.BytesIO(payload))
    real_sha = shutil.which('sha256sum')
    curl = tools / 'curl'
    curl.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
url = args[-1]
assert '/releases/download/v' in url and '/latest/' not in url, url
with open(os.environ['DOWNLOAD_LOG'], 'a') as log: log.write(url + '\\n')
if os.environ.get('DOWNLOAD_FAIL') == '1': sys.exit(22)
source = 'fixture-archive' if url.endswith('.tar.gz') else 'fixture-binary'
shutil.copyfile(pathlib.Path(os.environ['TOOL_FIXTURES']) / source, args[args.index('--output') + 1])
''')
    curl.chmod(0o755)
    sha = tools / 'sha256sum'
    sha.write_text('''#!/usr/bin/env python3
import os, pathlib, re, subprocess, sys
text = sys.stdin.read()
assert '--check' in sys.argv
match = re.fullmatch(r'([a-f0-9]{64})  (.+)\\n', text)
assert match and pathlib.Path(match[2]).is_file(), text
pathlib.Path(os.environ['CHECKSUM_LOG']).write_text(text)
if os.environ.get('VERIFIED_FIXTURE') == '1': sys.exit(0)
sys.exit(subprocess.run([os.environ['REAL_SHA'], *sys.argv[1:]], input=text, text=True).returncode)
''')
    sha.chmod(0o755)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
               TOOL_FIXTURES=str(root), REAL_SHA=real_sha, DOWNLOAD_LOG=str(root / 'downloads'),
               CHECKSUM_LOG=str(root / 'checksums'))
    for name in ['hadolint', 'gitleaks']:
        for verified, success in [('1', True), ('0', False)]:
            destination = root / (name + verified)
            result = subprocess.run(['bash', 'scripts/ci-tool.sh', name, str(destination)],
                                    env=dict(env, VERIFIED_FIXTURE=verified), capture_output=True, text=True, timeout=15)
            assert (result.returncode == 0) == success, result.stdout + result.stderr
            assert (root / 'checksums').exists(), 'the downloaded bytes were not checked'
            if success:
                assert os.access(destination, os.X_OK) and destination.read_bytes() == payload
                assert subprocess.check_output([str(destination)], text=True).strip() == 'fixture tool'
            else:
                assert not destination.exists(), 'corrupted bytes reached the destination'
        failed = root / (name + '-failed')
        result = subprocess.run(['bash', 'scripts/ci-tool.sh', name, str(failed)],
                                env=dict(env, DOWNLOAD_FAIL='1'), capture_output=True, text=True, timeout=15)
        assert result.returncode != 0 and not failed.exists(), 'failed download was accepted'
    (root / 'downloads').unlink()
    result = subprocess.run(['bash', 'scripts/ci-tool.sh', 'unknown', str(root / 'unknown')],
                            env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode != 0 and not (root / 'downloads').exists()
print('pinned CI tools refuse failed downloads and corrupted bytes before installation')
PY
}
check ci_tool_cases

brand_grep_error_cases() {
  python3 - <<'PY'
import os, pathlib, shutil, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix='brand-grep-cases-') as tmp:
    root = pathlib.Path(tmp)
    grep = root / 'grep'
    grep.write_text('''#!/usr/bin/env python3
import os, sys
if os.environ['GREP_ERROR_PATTERN'] in sys.argv[1:]:
    print('fixture grep I/O error', file=sys.stderr)
    sys.exit(2)
os.execv(os.environ['REAL_GREP'], [os.environ['REAL_GREP'], *sys.argv[1:]])
''')
    grep.chmod(0o755)
    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], REAL_GREP=shutil.which('grep'))
    for pattern in ['ghcr.io/nextcloud-releases', 'office-collabora|office-onlyoffice',
                    'github.com/nextcloud/all-in-one/releases|github.com/nextcloud-releases',
                    'theme-toggle|theme-icon', r'\[data-theme="dark"\]',
                    'value="Log out"', 'nextcloud-aio-[a-z0-9-]*', 'No se encontró ningún canal|territorio-card|pendiente de empaquetado|aps-conecta provision']:
        result = subprocess.run(['bash', 'scripts/brand-gate.sh', '.'],
                                env=dict(env, GREP_ERROR_PATTERN=pattern), text=True,
                                capture_output=True, timeout=30)
        assert 'fixture grep I/O error' in result.stderr, f'the error injection missed {pattern}'
        assert result.returncode != 0, f'the brand gate accepted unreadable input for {pattern}'
print('brand gate refuses grep errors across negative checks')
PY
}
check brand_grep_error_cases

divergence_parse_error_cases() {
  python3 - <<'PY'
import os, pathlib, shutil, subprocess, tempfile
with tempfile.TemporaryDirectory(prefix='divergence-json-cases-') as tmp:
    root = pathlib.Path(tmp)
    for name in ['scripts/divergence.sh', 'scripts/env.sh', 'scripts/apps.py', 'apps.json',
                 'provisioning/standings.sh', 'provisioning/phases/20-groups.sh']:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(name, target)
    site = root / 'sites/synthetic/site.sh'
    site.parent.mkdir(parents=True)
    site.write_text('''SITE_FOLDERS=()
SITE_TEAMS=()
SITE_ROLES=()
SITE_WELCOME=()
SITE_ROSTER=""
IV_MOUNT=Intranet
SITE_COMUNA_CUT=13101
SITE_COMUNA=Prueba
SITE_DEIS=999999
SITE_TIPO=CESFAM
''')
    tools = root / 'bin'
    tools.mkdir()
    docker = tools / 'docker'
    docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if '/var/www/html/occ' not in args: sys.exit(0)
args = args[args.index('/var/www/html/occ') + 1:]
cmd = args[0]
if cmd == os.environ.get('BAD_INVENTORY'):
    mode = os.environ['BAD_RESPONSE']
    if mode == 'json': print('{')
    elif mode == 'shape': print('42')
    elif mode == 'members': print('{"1":"invalid"}' if cmd == 'groupfolders:list' else '[1]')
    elif mode == 'transport':
        print('{}')
        sys.exit(7)
    sys.exit(0)
if cmd in ['groupfolders:list', 'group:list', 'user:list']:
    shape = os.environ.get('GOOD_INVENTORY', 'empty')
    if shape == 'empty': print('{}')
    elif cmd == 'groupfolders:list':
        folder = {'id': 1, 'mount_point': 'Intranet'}
        print(json.dumps({'1': folder} if shape == 'mapping' else [folder]))
    else: print(json.dumps({'admin': 'Synthetic Admin'} if shape == 'mapping' else ['admin']))
elif args[:2] == ['config:system:get', 'datadirectory']: print('/mnt/fixture')
elif args[:2] == ['config:app:get', 'territorio']:
    print('13101' if args[2] == 'comuna_cut' else 'Prueba')
elif args[:2] == ['config:app:get', 'estadistica']:
    print({'deis_code': '999999', 'establishment_type': 'CESFAM', 'comuna_cut': '13101'}[args[2]])
''')
    docker.chmod(0o755)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], SITE='synthetic')
    def run(*args, **extra):
        return subprocess.run(['bash', 'scripts/divergence.sh', *args], cwd=root,
                              env=dict(env, **extra), text=True, capture_output=True, timeout=15)
    for shape in ['empty', 'mapping', 'list']:
        healthy = run('--gate', GOOD_INVENTORY=shape)
        assert healthy.returncode == 0 and 'nada en la instancia' in healthy.stdout, healthy.stdout + healthy.stderr
    for inventory in ['groupfolders:list', 'group:list', 'user:list']:
        for response in ['json', 'shape', 'members', 'empty', 'transport']:
            result = run('--gate', BAD_INVENTORY=inventory, BAD_RESPONSE=response)
            assert result.returncode != 0, f'{inventory} accepted {response}: {result.stdout}{result.stderr}'
            assert 'no se pudieron revisar' in result.stdout, result.stdout + result.stderr
            assert 'nada en la instancia' not in result.stdout
    report = run(BAD_INVENTORY='groupfolders:list', BAD_RESPONSE='json')
    assert report.returncode == 0 and 'no se pudieron revisar' in report.stdout
print('divergence rejects unreadable inventories in gate mode and reports them without an all-clear')
PY
}
check divergence_parse_error_cases

# #203: inspect the tag-tree contract and execute its ancestry/publication scripts
# against local git fixtures and a recording gh, never against a real Release.
release_contract_cases() {
  python3 - <<'PY'
import json, os, pathlib, re, subprocess, tempfile, textwrap
source = pathlib.Path('.github/workflows/release.yml').read_text()


def jobs(text):
    return dict(re.findall(r'^  ([a-z][a-z0-9_-]*):\n(.*?)(?=^  [a-z][a-z0-9_-]*:|\Z)', text, re.M | re.S))


def steps(job):
    return re.findall(r'^      - (.*?)(?=^      - |\Z)', job, re.M | re.S)


def run_script(step):
    run = re.search(r'^        run: \|\n(.*)', step, re.M | re.S)
    return textwrap.dedent(run[1]) if run else ''


def contract(text):
    errors = []
    definitions = jobs(text)
    gates = definitions.get('gates', '')
    if not re.search(r'^\s+(?:- )?run: bash scripts/test\.sh\s*$', gates, re.M):
        errors.append('release gates do not run the full local gate')
    if 'APS_SELFTEST_SIN_NAVEGADOR' in gates:
        errors.append('release gates waive browser checks')
    if 'git merge-base --is-ancestor' not in gates:
        errors.append('release gates do not prove main ancestry')
    if 'build-ref: ${{ needs.gates.outputs.sha }}' not in definitions.get('images', ''):
        errors.append('images do not build the proven commit')
    if 'RELEASE_SHA: ${{ needs.gates.outputs.sha }}' not in definitions.get('package', ''):
        errors.append('the package does not receive the proven SHA')
    required = {'MINISIGN_SECRET_KEY', 'MINISIGN_KEY_PASSWORD'}
    seen = set()
    for name, job in definitions.items():
        refs = set(re.findall(r'secrets\.(MINISIGN_SECRET_KEY|MINISIGN_KEY_PASSWORD|SPREED_REFRESH_TOKEN)', job))
        if not refs:
            continue
        seen |= refs
        if not re.search(r'^    environment: Release\s*$', job, re.M):
            errors.append(f'{name} reads release secrets outside the Release environment')
        if re.search(r'secrets\.(?:MINISIGN|SPREED)', job.split('    steps:', 1)[0]):
            errors.append(f'{name} exposes release secrets to the entire job')
        for step in steps(job):
            for secret in required:
                if f'secrets.{secret}' not in step:
                    continue
                consumer = 'bash scripts/package-release.sh' in step and name == 'package'
                env_key = secret
                env_match = re.search(r'^          ' + env_key + r': \$\{\{ secrets\.' + secret + r' \}\}\s*$', step, re.M)
                if not consumer or not env_match:
                    errors.append(f'{secret} escapes its consuming step environment')
    if seen != required:
        errors.append('release signing secrets are missing or an obsolete refresh secret is used')
    if 'spreed' in definitions:
        errors.append('the release chain still refreshes the retired Talk fork')
    publisher = next((step for step in steps(definitions.get('package', '')) if 'gh release create ' in step), '')
    if '--latest=false' not in publisher:
        errors.append('rehearsal creation does not explicitly refuse Latest')
    return errors


errors = contract(source)
if errors:
    print('\n'.join(errors))
    raise SystemExit(1)
# Deliberately damage the real contract; every arm must detect its own regression.
for bad in [source.replace('run: bash scripts/test.sh', 'run: echo skipped'),
            source.replace('    environment: Release\n', ''),
            source.replace('--latest=false', '--latest'),
            source.replace('secrets.MINISIGN_KEY_PASSWORD', 'secrets.OTHER_KEY')]:
    assert contract(bad), 'a broken release contract passed'

definitions = jobs(source)
ancestry = next(run_script(step) for step in steps(definitions['gates']) if 'git merge-base --is-ancestor' in step)
publish = next(run_script(step) for step in steps(definitions['package']) if 'gh release create ' in step)
with tempfile.TemporaryDirectory(prefix='release-contract-') as tmp:
    root = pathlib.Path(tmp)
    repo = root / 'source'
    def git(*args):
        return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()
    repo.mkdir()
    git('init', '-q', '--initial-branch=main')
    (repo / 'marker').write_text('main\n')
    git('add', 'marker')
    git('status', '--short')
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'main fixture')
    main = git('rev-parse', 'HEAD')
    origin = root / 'origin.git'
    subprocess.run(['git', 'clone', '-q', '--bare', str(repo), str(origin)], check=True)
    git('remote', 'add', 'origin', str(origin))
    git('switch', '-qc', 'feature')
    (repo / 'marker').write_text('feature\n')
    git('add', 'marker')
    git('status', '--short')
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'feature fixture')
    feature = git('rev-parse', 'HEAD')
    for commit, tag, success in [(main, 'v1.2.3', True), (feature, 'v1.2.3', False),
                                 (feature, 'v0.0.0-ci.2031', True)]:
        git('checkout', '-q', '--detach', commit)
        output = root / 'output'
        output.write_text('')
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', ancestry], cwd=repo,
                                env=dict(os.environ, RELEASE_TAG=tag, GITHUB_OUTPUT=str(output)),
                                text=True, capture_output=True, timeout=15)
        assert (result.returncode == 0) == success, f'ancestry {tag}: {result.stdout}{result.stderr}'
        if success:
            assert f'sha={commit}' in output.read_text(), 'the proven commit was not frozen'
    tools = root / 'bin'
    tools.mkdir()
    gh = tools / 'gh'
    gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
assert sys.argv[1:3] == ['release', 'create'], sys.argv
pathlib.Path(os.environ['RELEASE_CALL']).write_text(json.dumps(sys.argv[1:]))
''')
    gh.chmod(0o755)
    git('tag', 'v1.2.3', main)
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'tag', '-a', 'v0.0.0-ci.2031', feature, '-m', 'annotated rehearsal fixture')
    git('push', '-q', 'origin', 'refs/tags/v1.2.3', 'refs/tags/v0.0.0-ci.2031')
    call = root / 'release-call'
    for tag, rehearsal in [('v1.2.3', False), ('v0.0.0-ci.2031', True)]:
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', publish], cwd=repo,
                                env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                                         RELEASE_TAG=tag, RELEASE_SHA=feature if rehearsal else main, RELEASE_CALL=str(call), GH_TOKEN='fixture'),
                                text=True, capture_output=True, timeout=15)
        assert result.returncode == 0, result.stdout + result.stderr
        args = json.loads(call.read_text())
        assert ('--latest=false' in args) == rehearsal, f'Latest policy for {tag}: {args}'
        assert ('--prerelease' in args) == rehearsal, f'prerelease policy for {tag}: {args}'
    git('push', '-q', '--force', 'origin', f'{feature}:refs/tags/v1.2.3')
    call.unlink()
    moved = subprocess.run(['bash', '-euo', 'pipefail', '-c', publish], cwd=repo,
                           env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                                    RELEASE_TAG='v1.2.3', RELEASE_SHA=main, RELEASE_CALL=str(call), GH_TOKEN='fixture'),
                           text=True, capture_output=True, timeout=15)
    assert moved.returncode != 0 and not call.exists(), 'a moved tag published artifacts from another commit'
print('release gates, immutable source, secret scope, ancestry and effective publication flags passed')
PY
}
check release_contract_cases

# #177: only the suite's office backend may be created, routed or published. These are
# shipped capability surfaces, not a word ban over historical records or negative tests.
office_backends_removed() {
  local status
  [ ! -e Containers/collabora ] && [ ! -e Containers/onlyoffice ] \
    && [ ! -e php/cool-seccomp-profile.json ] || return 1
  if grep -nEi 'collabora|onlyoffice' php/containers.json .github/workflows/images.yml \
      Containers/nextcloud/entrypoint.sh Containers/nextcloud/run-exec-commands.sh \
      Containers/apache/Caddyfile; then
    return 1
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
  fi
  python3 scripts/images.py list | grep -qx aio-eurooffice
}
check office_backends_removed

# #179: removed upstream capabilities have no route, container or boot entry point.
# External-updater opt-out labels and Borg archive retention are separate capabilities.
upstream_surfaces_removed() {
  local status path
  for path in Containers/watchtower Containers/nextcloud/upgrade-latest-major.sh \
      Containers/mastercontainer/desec-ip-updater.sh Containers/mastercontainer/dinit.d/desec-ip-updater \
      php/src/Desec php/src/Controller/DesecController.php \
      php/src/Cron/UpdateDesecIp.php php/src/Cron/UpdateMastercontainer.php \
      php/src/Cron/UpdateNotification.php php/src/Cron/OutdatedNotification.php; do
    [ ! -e "$path" ] || return 1
  done
  if grep -nEi 'watchtower|desec|UpdateNotification\.php|OutdatedNotification\.php|latest-major|INSTALL_LATEST_MAJOR|LATEST_MAJOR_VERSION|api/docker/prune' \
      php/containers.json php/public/index.php php/templates/containers.twig \
      Containers/mastercontainer/start.sh Containers/mastercontainer/cron.sh \
      Containers/mastercontainer/daily-backup.sh Containers/nextcloud/entrypoint.sh; then
    return 1
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
  fi
  if grep -nE 'function (SystemPrune|RunNextcloudUpgradeToLatestMajor|StartWatchtowerContainer|startWatchtower|isNextcloudImageOutdated|IsMastercontainerUpdateAvailable)' \
      php/src/Controller/DockerController.php php/src/Docker/DockerActionManager.php; then
    return 1
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
  fi
  if grep -nE 'docker image prune' Containers/mastercontainer/cron.sh; then
    return 1
  else
    status=$?
    [ "$status" -eq 1 ]
  fi
}
check upstream_surfaces_removed

# Exercise the real backup wrapper at its external-command boundary. Only its fixed
# state-directory prefix is redirected into the fixture; no host Docker or PHP runs.
daily_backup_cases() {
  python3 - "${1:-Containers/mastercontainer/daily-backup.sh}" "${2:-Containers/mastercontainer/cron.sh}" <<'PY'
import os, pathlib, signal, subprocess, sys, tempfile, time

source = pathlib.Path(sys.argv[1]).read_text()
with tempfile.TemporaryDirectory(prefix="daily-backup-") as tmp:
    root = pathlib.Path(tmp)
    state = root / "state"
    (state / "data").mkdir(parents=True)
    (state / "session").mkdir()
    (state / "data/configuration.json").write_text('{"wasStartButtonClicked":true}\n')
    script = root / "daily-backup.sh"
    script.write_text(source.replace("/mnt/docker-aio-config", str(state)))
    bin_dir = root / "bin"
    bin_dir.mkdir()
    shims = {
        "docker": '''#!/bin/bash
case "$1" in
  inspect) echo APACHE_PORT=443 ;;
  ps) printf 'aps-conecta-apache\\naps-conecta-nextcloud\\n' ;;
  network) exit 0 ;;
  *) exit 1 ;;
esac
''',
        "nc": "#!/bin/bash\nexit 0\n",
        "su-exec": '''#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
if [ "$2" = touch ]; then /usr/bin/touch "$3"; fi
''',
    }
    for name, content in shims.items():
        path = bin_dir / name
        path.write_text(content)
        path.chmod(0o700)
    log = root / "calls"
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
               CALL_LOG=str(log), AIO_LOG_LEVEL="warn", DAILY_BACKUP="1",
               CHECK_BACKUP="0", STOP_CONTAINERS="1", START_CONTAINERS="1",
               LOCK_FILE_PRESENT="0", AUTOMATIC_UPDATES="1")
    result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    calls = log.read_text().splitlines()
    jobs = [line.rsplit("/", 1)[-1] for line in calls if " php " in line]
    assert jobs == ["StopContainers.php", "CreateBackup.php", "StartContainers.php", "BackupNotification.php"], jobs
    assert not (state / "data/daily_backup_running").exists(), "backup lock was not cleared"

    # The scheduler must request a restart and preserve the saved notification choice.
    # Stop its own isolated process group after observing one scheduled invocation.
    cron = root / "cron.sh"
    cron.write_text(pathlib.Path(sys.argv[2]).read_text().replace("/mnt/docker-aio-config", str(state)))
    for name, content in {
        "date": "#!/bin/bash\necho 04:00\n",
        "bash": '''#!/bin/bash
printf '%s\\t%s\\t%s\\n' "$*" "${START_CONTAINERS-unset}" "${SEND_SUCCESS_NOTIFICATIONS-unset}" >> "$CRON_CALLS"
''',
    }.items():
        path = bin_dir / name
        path.write_text(content)
        path.chmod(0o700)
    for enabled in (True, False):
        saved = "04:00\n" + ("" if enabled else "successNotificationsAreNotEnabled\n")
        (state / "data/daily_backup_time").write_text(saved)
        cron_calls = root / ("scheduled-" + str(enabled))
        cron_env = dict(env, CRON_CALLS=str(cron_calls))
        cron_env.pop("START_CONTAINERS", None)
        proc = subprocess.Popen(["/bin/bash", str(cron)], env=cron_env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while (not cron_calls.exists() or "\n" not in cron_calls.read_text()) \
                    and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            assert cron_calls.exists(), "scheduled backup never ran"
            expected = "/daily-backup.sh\t1\t" + str(int(enabled))
            assert cron_calls.read_text().splitlines()[0] == expected, cron_calls.read_text()
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=3)
print("daily backup preserves ordinary restart and notification without updating images")
PY
}
check daily_backup_cases

# #182: the public build-matrix output covers the runtime inventory and every
# surviving Dockerfile, with only the documented context/test/cache exceptions.
image_build_coverage() {
  python3 - <<'PY'
import json, pathlib, subprocess

root = pathlib.Path.cwd()
matrix = json.loads(subprocess.check_output(["python3", "scripts/images.py", "build-matrix"], text=True))["include"]
services = json.loads((root / "php/containers.json").read_text())["aio_services_v1"]
expected = {row["image"].rsplit("/", 1)[-1] for row in services} | {"all-in-one"}
assert len(matrix) == len(expected) and {row["image"] for row in matrix} == expected
assert {row["dockerfile"] for row in matrix} == {str(p.relative_to(root)) for p in (root / "Containers").glob("*/Dockerfile")}
assert {row["image"] for row in matrix if row["context"] == "."} == {"all-in-one", "aio-nextcloud", "aio-apache", "aio-clamav"}
assert {row["image"] for row in matrix if row["database_test"]} == {"aio-postgresql"}
assert {row["image"] for row in matrix if not row["cache"]} == {"aio-eurooffice"}
# The existing browser files run sequentially on one runner; no suite-owned
# service or named volume may survive the reset between those files.
cleanup = (root / "php/tests/run.sh").read_text()
import re
container_match = re.search(r'aps-conecta-\{([^}]+)}', cleanup)
volume_match = re.search(r'nextcloud_aio_\{([^}]+)}', cleanup)
assert container_match and volume_match, "browser reset lost its owned resource lists"
reset_containers = {'aps-conecta-' + name for name in container_match[1].split(',')}
reset_volumes = {'nextcloud_aio_' + name for name in volume_match[1].split(',')}
assert {row['container_name'] for row in services} <= reset_containers, "browser reset misses a suite service"
named_volumes = {v['source'] for row in services for v in row.get('volumes', [])
                 if v['source'].startswith('nextcloud_aio_')}
assert named_volumes <= reset_volumes, "browser reset misses a named suite volume"
print("every suite image is built from its Dockerfile with the required exceptions")
PY
}
check image_build_coverage

# The fork's shell namespace, spelled once for every row that walks it (the sweep below, the
# dirname gate at #60's row). Unquoted on purpose: the words re-glob where they are used. The
# comm tripwire a few lines down keeps its own literal copy deliberately — it is the alarm
# that reds when this list and the tree drift apart.
SHELL_NAMESPACE='scripts/*.sh provisioning/*.sh provisioning/phases/*.sh host/*.sh install.sh'
linted=0
for s in $SHELL_NAMESPACE; do
  [ -e "$s" ] || continue
  linted=$((linted + 1)); check bash -n "$s"
done
# A glob that matches nothing stays literal, `[ -e ]` skips it, and the gate reports only the checks
# it did run — so a renamed directory would silently lint nothing and still print all-ok.
#
# SUBSET, not equality — and NAMESPACE-SCOPED (unchanged by the hard fork, its rationale re-homed):
# instalador's tree carries UPSTREAM's shell (Containers/*/start.sh and friends), and that shell is
# upstream's own to keep — their shellcheck.yml owns it on every push and PR, so this sweep stays
# out of it. Inside the fork's namespaces the doctrine is unchanged: the sweep legitimately lints
# files git has never heard of (a developer's scratch script under scripts/, a site.sh copied in by
# hand while rehearsing a silent install — real shell someone is about to source), so demanding the
# two lists MATCH would be green on every machine and red only in CI. What matters is that nothing
# TRACKED escapes the sweep, so subtract and require empty.
check bash -c '
  [ -z "$(comm -23 <(git ls-files "*.sh" | grep -E "^scripts/|^provisioning/|^host/|^install\.sh$" | sort) \
                   <(ls scripts/*.sh provisioning/*.sh provisioning/phases/*.sh host/*.sh install.sh 2>/dev/null | sort))" ]'
# Same three assertions `ensure_vendored_app` already makes (lib.sh:211-222), moved from seed time to
# PR time. At seed time they run on a CLINIC, during the install — the worst place to learn that a
# tarball and its manifest stopped describing each other, because the operator is mid-install and
# the failure reads as the install being broken. Here it needs no stack, no .env, no clock and no
# network, so it runs in any pull request, including a hotfix opened from a clinic.
# NOT a replacement for the seed-time check: that one guards the bytes that actually get unpacked.
# B-012's other half. A phase's STDOUT IS its contract with the seed-idempotency gate. Redirecting
# `occ` is fine and common (the helper logs afterwards, via `&&`); redirecting a HELPER is what
# blinds it. The function list is read out of lib.sh rather than typed here, so it cannot drift.
check bash -c '
  fns=$(grep -oE "^[a-z_]+\(\)" provisioning/lib.sh | tr -d "()" | sort -u | paste -sd"|" -)
  bad=$(grep -rnE "(^|[;&[:space:]])(\$fns)([[:space:]][^|]*)?>[[:space:]]*/dev/null" \
          provisioning/phases/*.sh provisioning/seed.sh 2>/dev/null || true)
  [ -z "$bad" ] || { printf "%s\n" "$bad" >&2; exit 1; }'
# --- gate (#60): dirname-of-self only where the caller's cwd still governs ----------------------
# env.sh's first job is `cd "$(dirname "${BASH_SOURCE[0]}")/.."` — the repo root (env.sh §1).
# A dirname of $0 evaluated on any LATER line resolves against the NEW cwd whenever the
# script was started by a relative path, so it names a directory that is not the script's.
# #30's first draft shipped exactly that twice (the smoke test and the divergence gate) and a
# reviewer caught both; this row is the retro's ask — the gate reds on the class, not the
# spelling. Position is the contract, and it is exact in both directions:
#   - the sourcing line itself expands BEFORE env.sh runs;
#   - lines before the first source still see the caller's cwd — the pre-computed HERE idiom
#     (seed.sh:8) is absolute by the time env.sh moves, and usuarios.sh:36's
#     own cd is pre-source by construction;
#   - everything after the first source line must not self-locate by dirname. $BASH_SOURCE
#     rides the same rule: launched relatively, it is exactly as relative as $0.
# Subjects are discovered by the source line itself, over the lint sweep's namespace, so a
# script that starts sourcing env.sh is covered the day it lands. The fixtures live as real
# bytes under tests/gate-fixtures/ (never executed) — not as heredocs here, whose bytes would
# be this file's own post-source lines and red the gate on itself. And per org L7-2 the row
# proves it can red: the #30 shape must be flagged, while every legal idiom above — and a
# script that never sources env.sh — must stay green.
ENV_SH_SOURCE_RE='^[[:space:]]*(\.|source)[[:space:]][^#]*env\.sh'
ENV_SH_SELFLOC_RE='dirname[[:space:]]+(-[[:alnum:]-]+[[:space:]]+)?("\$0"|\$0|"\$\{BASH_SOURCE\}"|"\$BASH_SOURCE"|"\$\{BASH_SOURCE\[0\]\}"|\$\{BASH_SOURCE\[0\]\})'
env_sh_selfpath_rows() {  # FILE... — every dirname-of-self evaluated after env.sh moved the cwd
  local f first
  for f in "$@"; do
    [ -f "$f" ] || continue          # a glob that matched nothing stays literal (the sweep's rule)
    first="$(grep -nE "$ENV_SH_SOURCE_RE" "$f" | head -1 | cut -d: -f1)"
    [ -n "${first:-}" ] || continue   # never sources env.sh: not this gate's subject
    grep -nE "$ENV_SH_SELFLOC_RE" "$f" | awk -F: -v first="$first" -v f="$f" '
      ($1 + 0) > first { print f ":" $0 }'
  done
}
env_sh_selfpath_gate() {
  local rows n rc=0
  # green on main is the baseline: the shipped tree carries none
  rows="$(env_sh_selfpath_rows $SHELL_NAMESPACE)"
  [ -z "$rows" ] || { printf 'a script sources env.sh and then self-locates by dirname — the cwd is the repo root by then:\n%s\n' "$rows" >&2; return 1; }
  # red on the injected violation (org L7-2): both spellings, and only those two rows
  rows="$(env_sh_selfpath_rows tests/gate-fixtures/violador.sh)"
  n="$(printf '%s\n' "$rows" | grep -c .)"
  [ "$n" = 2 ] || { printf 'the gate flagged %s rows on the #30 fixture, want exactly 2:\n%s\n' "${n:-0}" "$rows" >&2; rc=1; }
  printf '%s\n' "$rows" | grep -q '\.\./VERSION' || { echo 'the gate missed the #30 shape (a dirname of $0 after the source)' >&2; rc=1; }
  printf '%s\n' "$rows" | grep -q 'BASH_SOURCE' || { echo 'the gate missed the BASH_SOURCE spelling' >&2; rc=1; }
  # and green on every legal idiom, and on a script that never sources env.sh
  rows="$(env_sh_selfpath_rows tests/gate-fixtures/legal.sh)"
  [ -z "$rows" ] || { printf 'the gate reds a legal idiom:\n%s\n' "$rows" >&2; rc=1; }
  rows="$(env_sh_selfpath_rows tests/gate-fixtures/ajeno.sh)"
  [ -z "$rows" ] || { printf 'the gate took a non-sourcer as a subject:\n%s\n' "$rows" >&2; rc=1; }
  return "$rc"
}
check env_sh_selfpath_gate


# --- gate: the channel's identity — instalador is the only home the operator is sent to ---------
# The move re-keyed every operator pointer (D13): the bootstrap, the CLI's remedies, the wizard's
# help arms, the units' Documentation lines. The rename (#53) made gestion the suite repo's own
# name, so the entry files must carry it — the forbid-gestion rule of the clone era would now red
# on the canonical URL. Three shapes pin the channel instead:
#   - the two operator entry files' repo URL is exactly the suite repo's canonical URL, so any
#     drift — back to instalador, or on to anything else — reds naming the file;
#   - the signing key has exactly two committed readers, and they agree (the env.sh lesson):
#     installer.pub's key line and install.sh's embedded SIGNIFY_PUBKEY — package-release.sh reds
#     on a disagreement at tag time; this is the PR-time half, before a tag is ever cut;
#   - no runbook pointer survives with the old docs/ prefix: the runbooks live in aps/ (D13),
#     so such a remedy would be a
#     dead pointer in the package an operator actually holds. aps/CHANGELOG.md is dated history
#     and keeps what it said when it said it.
check bash -c '
  want="https://github.com/APS-Conecta/gestion"
  got="$(sed -n "s|^REPO_URL=\"\${REPO_URL:-\(.*\)}\".*|\1|p" install.sh | head -1)"
  [ "$got" = "$want" ] || { echo "install.sh no lleva el URL canónico del repositorio de la suite: $got" >&2; exit 1; }
  got="$(sed -n "s|^INSTALADOR_REPO_URL=\"\${INSTALADOR_REPO_URL:-\(.*\)}\".*|\1|p" host/aps-conecta | head -1)"
  [ "$got" = "$want" ] || { echo "host/aps-conecta no lleva el URL canónico del repositorio de la suite: $got" >&2; exit 1; }'
check bash -c '
  pub="$(sed -n 2p installer.pub)"
  emb="$(sed -n "s/^SIGNIFY_PUBKEY=\"\([^\"]*\)\".*/\1/p" install.sh | head -1)"
  { [ -n "$emb" ] && [ "$pub" = "$emb" ]; } || { echo "installer.pub and install.sh carry different keys" >&2; exit 1; }'
check bash -c '
  hits="$(git grep -nE "docs/(INSTALLER|GUIA-CLINICA)\.md" -- . ":!aps/CHANGELOG.md" 2>/dev/null || true)"
  [ -z "$hits" ] || { printf "runbook pointers still on the old docs/ home:\n%s\n" "$hits" >&2; exit 1; }'

# #143: ensure_aia_intermediate must not read "could not ask" as "not imported" — that re-imports a
# certificate already in the bundle, which is a write on a provisioned instance and reddens
# seed-idempotent intermittently, here and in cleanboot. Behavioural, not a grep for the fix: occ is
# stubbed to fail the way a busy container fails, and the assertion is which branch the guard takes.
# Two cases, and the second exists because the first fix broke a clean install: phases run under
# `set -e`, so "certificate absent" — a legitimate non-zero — must not kill the phase. Only cleanboot
# saw it, because a machine that already holds both certificates never takes the absent branch.
# Sources env.sh first since the docker-exec port: lib.sh's transport now rides nc_exec(), and
# lib.sh's own REQUIRES contract names env.sh. The REAL seam running into the stubbed docker() is
# the stronger gate: a seam that misparsed its own options would turn this red, not just the seed.
check bash -c '
  . scripts/env.sh
  . provisioning/lib.sh
  # Every "the phase must survive this" assertion goes through here, and none of them may
  # be written `( set -e … ) || exit 1`: bash propagates the tested-context of a `||` into
  # the subshell, so errexit is suppressed inside it and the assertion tests nothing.
  # Two of these guards were written that way and were silently inert. Capture the status.
  survives() {
    ( set -e -o pipefail; ensure_aia_intermediate example.test >/dev/null 2>&1 )
    [ $? -eq 0 ] || exit 1
  }
  docker() { [[ "$*" == *s_client* ]] && echo "http://secure.globalsign.com/cacert/ca.crt"; return 0; }
  occ() { return 1; }                     # cannot answer -> skip, never import
  ensure_aia_intermediate example.test 2>&1 | grep -q "could not read the certificate list" || exit 1
  occ() { echo "[]"; }                    # answers "absent", under errexit -> must survive
  survives
  # Offline: the handshake itself fails. The stub used to return 0 for everything, so this
  # branch was invisible to the gate — and a change that made the phase FATAL without a
  # network passed it. Every failure in this helper is a warning by design (lib.sh:579).
  docker() { [[ "$*" == *s_client* ]] && return 1; return 0; }
  ensure_aia_intermediate example.test 2>&1 | grep -q "no CA-Issuers pointer" || exit 1
  survives
  # A leaf past the pipe buffer. Splitting the handshake with `head -1` closed the pipe on line
  # two, so the writer took SIGPIPE and the assignment returned 141 — fatal under pipefail. The
  # leaf is as big as the remote host cares to make it, and every stub above emits a few bytes,
  # which is exactly why the gate could not see it.
  docker() {
    [[ "$*" == *s_client* ]] && { echo "http://secure.globalsign.com/cacert/ca.crt"; echo; printf "%*s" 200000 ""; }
    return 0
  }
  survives
  # A failed transfer warns and leaves later certificate sources available.
  docker() {
    case "$*" in
      *s_client*) echo "http://secure.globalsign.com/cacert/ca.crt"; echo; echo LEAF ;;
      *"mktemp -d"*) echo /tmp/aps-ca.ABCDEF1234 ;;
      *"cat >"*) return 1 ;;
      *) echo PEM ;;
    esac
    return 0
  }
  survives
  # Valid JSON of the wrong shape raises on `.get`, not on `load`. Uncaught that exits 1,
  # which this function reads as "absent" and answers with the re-import #143 exists to
  # prevent — a WRITE on a provisioned instance. It must read as unreadable instead, and
  # an empty list must still mean absent or the guard has swallowed the real answer too.
  docker() {
    case "$*" in
      *s_client*) echo "http://x.test/ca.crt"; echo; echo LEAF ;;
      *"mktemp -d"*) echo /tmp/aps-ca.ABCDEF1234 ;;
      *) echo PEM ;;
    esac
    return 0
  }
  for shape in "{\"a\":1}" "\"x\"" "[1,2]"; do
    occ() { echo "$shape"; }
    ensure_aia_intermediate example.test 2>&1 | grep -q "unreadable" || exit 1
  done
  # And every status that is not 0 or 1 is a non-answer too. The case listed only 0 and 2,
  # so a python3 the kernel kills — 137 — fell through to "absent" and re-imported.
  python3() { return 137; }
  occ() { echo "[]"; }
  ensure_aia_intermediate example.test 2>&1 | grep -q "unreadable" || exit 1
  unset -f python3
  # The positive control, last: an empty list really does mean absent, and if the guards
  # above have swallowed that too they have swallowed the answer along with the non-answers.
  ensure_aia_intermediate example.test 2>&1 | grep -q "imported ca.pem" || exit 1'
# R22: the installer's own CA, on an install by IP. Phase 07 imports it into Nextcloud's own bundle
# once; a domain install mounts no such file and gets no call at all; a container or a list that
# cannot be asked is a non-answer (#143), never an absence; and a failed import fails the phase — an install by IP that
# does not trust its own address is broken. Behavioural, through the real seam, under errexit.
installer_ca_cases() (
  grep -qx "ensure_installer_ca" provisioning/phases/07-certs.sh || { echo "installer CA: phase 07 does not call it" >&2; exit 1; }
  log="$(mktemp)"; trap 'rm -f "$log"' EXIT
  ca=/usr/local/share/ca-certificates/aps-conecta-ca.crt
  ca_run() {  # HAS LIST IMP — a fresh bash, so errexit holds (check's `if` suppresses it in here)
    : > "$log"
    out="$(HAS="$1" LIST="$2" IMP="$3" LOG="$log" CA="$ca" bash -e -o pipefail -c '
      . scripts/env.sh; . provisioning/lib.sh
      nc_exec() {   # the probe: words on stdout; "err" is docker exec failing as for a stopped container
        [ "$1 $2 $3 $5 $6" = "-- sh -c _ $CA" ] || return 2
        case "$HAS" in 1) echo yes ;; 0) echo no ;; *) return 1 ;; esac
      }
      occ() {
        printf "%s\n" "$*" >> "$LOG"
        case "$1" in
          security:certificates) [ "$LIST" != fail ] && printf "%s" "$LIST" ;;
          security:certificates:import) return "$IMP" ;;
        esac
      }
      ensure_installer_ca' 2>&1)"; rc=$?
  }
  imports() { grep -cx "security:certificates:import $ca" "$log"; }
  ca_run 0 '[]' 0
  [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$log" ] || { echo "installer CA: a domain install was touched: $out" >&2; exit 1; }
  ca_run err '[]' 0
  [ "$rc" = 0 ] && [[ "$out" == *"could not ask the container for aps-conecta-ca.crt"* ]] && [ ! -s "$log" ] \
    || { echo "installer CA: a container that could not be asked was read as a domain install: $out" >&2; exit 1; }
  ca_run 1 '[{"name":"aps-conecta-ca.crt"}]' 0
  [ "$rc" = 0 ] && [[ "$out" == *"aps-conecta-ca.crt already imported"* ]] && [ "$(imports)" = 0 ] \
    || { echo "installer CA: imported again: $out" >&2; exit 1; }
  for list in fail '{"a":1}' '[1,2]'; do
    ca_run 1 "$list" 0
    [ "$rc" = 0 ] && [[ "$out" == *"could not read the certificate list"* ]] && [ "$(imports)" = 0 ] \
      || { echo "installer CA: a non-answer ($list) was read as absent: $out" >&2; exit 1; }
  done
  ca_run 1 '[]' 1
  [ "$rc" != 0 ] && [[ "$out" == *"import of aps-conecta-ca.crt FAILED"* ]] || { echo "installer CA: a failed import passed: $out" >&2; exit 1; }
  ca_run 1 '[]' 0   # the positive control, last
  [ "$rc" = 0 ] && [[ "$out" == *"certs: imported aps-conecta-ca.crt for this server's own address"* ]] && [ "$(imports)" = 1 ] \
    || { echo "installer CA: an absent CA was not imported: $out" >&2; exit 1; }
)
check installer_ca_cases
# R22: phase 14's install-by-IP block, extracted from the phase and run under its errexit. An
# address in overwrite.cli.url (the entrypoint's, every boot) sends both server-to-server legs
# inside the wizard's network; a domain writes nothing — a domain install keeps its public legs
# (B-019) — and a value that cannot be read is said, never taken for a domain (B-014).
office_by_ip_cases() {
  local block out pub want
  block="$(sed -n '/^# --- by IP (R22)/,/^# --- end by IP ---$/p' provisioning/phases/14-office.sh)"
  [ -n "$block" ] || { echo "office by IP: block not found in 14-office.sh" >&2; return 1; }
  while IFS='|' read -r pub want; do
    out="$(PUB="$pub" bash -e -o pipefail -c '
      conf_load() { :; }
      conf_get() { [ "$PUB" != fail ] && printf "%s\n" "$PUB"; }
      app_config_set() { printf "SET %s %s %s\n" "$@"; }
      log() { printf "LOG %s\n" "$*"; }
      eval "$1"' _ "$block" 2>&1)" || { echo "office by IP: the block failed for $pub: $out" >&2; return 1; }
    case "$want" in
      internal) [ "$out" = "SET eurooffice DocumentServerInternalUrl http://aps-conecta-eurooffice/
SET eurooffice StorageUrl http://aps-conecta-apache.nextcloud-aio:23973/" ] ;;
      none) [ -z "$out" ] ;;
      said) [ "$out" = "LOG AIO: overwrite.cli.url could not be read — the office's internal URLs left as they are" ] ;;
    esac || { echo "office by IP: $pub expected $want, got: $out" >&2; return 1; }
  done <<'CASES'
https://10.0.0.5/|internal
https://192.168.1.50/|internal
https://clinica.example/|none
https://10.0.0.5.example/|none
fail|said
CASES
}
check office_by_ip_cases
# The other half of the WRITES meta-gate, and the half it cannot express: an alternative must match
# the WRITE line of a helper and NOT its noop line. `certs:` is the pair that proves it — the write
# says "certs: imported X for Y", the noop says "certs: X already imported", and an unanchored
# ` imported` matches both, which would fail a second seed that did nothing. Asserted rather than
# commented because the anchor is one character away from being deleted as noise.
check python3 -c '
import re, sys
src = ""
for line in open("scripts/seed-idempotent.sh", encoding="utf-8"):
    if line.startswith("WRITES="):
        src = line.split("=", 1)[1].strip().strip("\x27\"")
write = "    certs: imported gsgccr6 for www.ispch.gob.cl"
noop  = "    certs: gsgccr6 already imported"
hit = lambda s: any(re.search(a, s) for a in src.split("|"))
if not hit(write):
    print("WRITES no longer matches the cert import — a re-import would report PASS"); sys.exit(1)
if hit(noop):
    print("WRITES matches the cert NOOP line — every second seed would fail"); sys.exit(1)'
# THE GATE'S OWN GATE. scripts/seed-idempotent.sh decides whether a second seed wrote anything by
# grepping the log for write verbs. Every alternative in that regex is a claim about vocabulary
# lib.sh's log() actually emits — and when one stops being true the gate does not fail, it silently
# stops looking. That is not hypothetical: `installed/enabled` sat in WRITES matching nothing that
# any phase emits, so on `main` the idempotency gate was structurally incapable of failing on an app
# enable (found 2026-08-02, fixed in #121).
#
# So: assert every alternative still matches something the code can print. The corpus is every
# log()/printf literal under provisioning/, with ${...} and $(...) blanked — a write verb is a
# constant, the values around it are not. This is the direction that catches the real bug; the
# reverse (a write verb no alternative covers) needs a judgement about which log lines ARE writes,
# and a heuristic for that flags correct code, which is why the 2026-08-02 sweep rejected it.
check python3 -c '
import re, glob, sys
corpus = []
for f in glob.glob("provisioning/**/*.sh", recursive=True):
    for line in open(f, encoding="utf-8"):
        for m in re.finditer(r"(?:log|printf)\s+([\"\x27])(.*?)\1", line):
            corpus.append("    " + re.sub(r"\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_]\w*", "X", m.group(2)))
src = ""
for line in open("scripts/seed-idempotent.sh", encoding="utf-8"):
    if line.startswith("WRITES="):
        src = line.split("=", 1)[1].strip().strip("\x27\"")
dead = [a for a in src.split("|") if not any(re.search(a, c) for c in corpus)]
if dead:
    print("WRITES alternatives that match nothing provisioning/ can emit: " + repr(dead))
    print("seed-idempotent.sh cannot fail on these. Fix the regex or the log line.")
    sys.exit(1)
if not src:
    print("could not read WRITES= from scripts/seed-idempotent.sh"); sys.exit(1)'
# Regression guard (#39): a `set -e` subshell's status must not be consumed in a conditional
# context — bash suppresses errexit inside it, so what reads as a guard runs on and reports
# success. Two shapes, because the second is the one that shipped:
#   - something TESTS it from the left: `if (`, `while (`, `&& (`. Matched on what PRECEDES
#     the `(` rather than by listing keywords — nothing but whitespace may.
#   - something tests it from the right: `( set -e … ) || exit 1`. This reads exactly like a
#     guard and is not one: it asserts nothing. The sweep reads the whole tree, not only seed.sh,
#     because the shape turns up wherever a guard is written.
# Comments are stripped first, since seed.sh documents the wrong shape on purpose.
# Over `git ls-files`, not a hand-written list of directories: a third copy of that list is a
# third thing to forget, and a sweep that matches nothing passes — which is the very hole the
# lint sweep above was rewritten to close. Python rather than grep because the subshell and the
# `||` that tests it are not always on one line. The file set is namespace-scoped like the lint
# sweep's: upstream's shell stays out of it — their shellcheck.yml owns those bytes on every push
# and PR.
check python3 -c '
import re, subprocess, sys

ERREXIT = r"set\s+(-[a-z]*e|-o[ \t]+errexit)"
FROM_THE_LEFT = re.compile(r"\S[ \t]*\(\s*" + ERREXIT)
FROM_THE_RIGHT = re.compile(r"\(\s*" + ERREXIT + r"[^()]*\)[ \t]*(\|\||&&)")

tracked = subprocess.run(["git", "ls-files", "-z", "*.sh"],
                         capture_output=True, text=True, check=True).stdout.split("\0")
files = [f for f in tracked if re.match(r"^(scripts|provisioning|host)/", f) or f == "install.sh"]
bad = []
for name in filter(None, files):
    with open(name, encoding="utf-8") as handle:
        # Comments are stripped first: seed.sh documents the wrong shape on purpose.
        body = "".join(l for l in handle if not l.lstrip().startswith("#"))
    for hit in FROM_THE_LEFT.finditer(body):
        bad.append(f"{name}: tested from the left — {hit.group(0).strip()!r}")
    for hit in FROM_THE_RIGHT.finditer(body):
        bad.append(f"{name}: tested from the right — the {hit.group(2)} after the subshell")

if bad:
    print("errexit is suppressed in a tested context, so these guard nothing:")
    for line in bad:
        print("  " + line)
    sys.exit(1)'
# --- gate: a new file in the fork's namespaces carries an SPDX header (#63) ---------------------
# AGENTS.md's inherited rule ("new fork-owned scripts carry an SPDX header") met 46 of them
# without one, so every PR asked its reviewer to weigh the rule against precedent (#30's retro).
# The owner's call on #63: enforce for files added from now on, fork namespaces only — the same
# namespaces the lint and errexit sweeps own, upstream's shell staying upstream's, and, because
# the rule names scripts, over .sh and .py both; other files (.json, .conf, docs) stay out.
# SPDX_BASELINE freezes the headerless scripts that predate the decision, so main is green by
# construction and the row reds only on a file it has never seen: a tracked one without the
# header line and not on the list. When a baseline file gains its header, drop its line here;
# an exception is a baseline extension in a commit that says why — never a silent row-weakening.
SPDX_BASELINE='
install.sh
provisioning/app-policy.sh
provisioning/intravox/render.py
provisioning/lib.sh
provisioning/phases/05-security.sh
provisioning/phases/06-jobs.sh
provisioning/phases/07-certs.sh
provisioning/phases/10-locale.sh
provisioning/phases/12-apps.sh
provisioning/phases/14-office.sh
provisioning/phases/15-branding.sh
provisioning/phases/16-app-policy.sh
provisioning/phases/20-groups.sh
provisioning/phases/30-folders.sh
provisioning/phases/40-acl.sh
provisioning/phases/41-intravox.sh
provisioning/phases/50-users.sh
provisioning/seed.sh
provisioning/standings.sh
provisioning/usuarios.sh
scripts/acquisition-gate.sh
scripts/brand-gate.sh
scripts/cleanboot-site.sh
scripts/comuna-package.sh
scripts/deis.py
scripts/divergence.sh
scripts/env.sh
scripts/lockup.py
scripts/office-smoke.sh
scripts/package-release.sh
scripts/provisionador.py
scripts/rename-containers.py
scripts/seed-idempotent.sh
scripts/smoke.sh
scripts/test.sh
scripts/validate.sh
'
spdx_offenders() {
  # every argument that neither carries the header line nor sits on the frozen baseline
  local f
  for f in "$@"; do
    grep -qxF "$f" <<<"$SPDX_BASELINE" && continue
    grep -qx "# SPDX-License-Identifier: AGPL-3.0-or-later" "$f" || printf "%s\n" "$f"
  done
}
spdx_header_row() {
  local off
  off="$(spdx_offenders $(git ls-files "*.sh" "*.py" | grep -E '^scripts/|^provisioning/|^host/|^install\.sh$'))"
  [ -z "$off" ] || { printf "tracked scripts lacking an SPDX header and not on the #63 baseline:\n%s\n" "$off" >&2; return 1; }
}
check spdx_header_row
# The baseline's own gate (the seed-idempotent lesson: an allowlist that can rot must not rot
# silently). spdx_header_row pins one direction — every tracked script is headered or on the
# baseline; this pins the other — every baseline line still names a tracked, headerless script.
# Together they make baseline ≡ the headerless set, so green on main cannot erode: a line left
# behind by a rename or a deletion, or by a file that gained its header, reds here instead of
# rotting, and a line appended that names nothing real reds on the spot.
spdx_baseline_row() {
  local line
  local -a dead=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! git ls-files -- "$line" | grep -qx "$line"; then
      dead+=("$line (no longer a tracked file)")
    elif grep -qx "# SPDX-License-Identifier: AGPL-3.0-or-later" "$line"; then
      dead+=("$line (has the header — drop its baseline line)")
    fi
  done <<<"$SPDX_BASELINE"
  [ ${#dead[@]} -eq 0 ] || { printf 'SPDX_BASELINE lines that no longer name a headerless tracked script:\n' >&2; printf '%s\n' "${dead[@]}" >&2; return 1; }
}
check spdx_baseline_row
# Every script under scripts/ has a caller (#181): another tracked file — a workflow, a script, the
# host CLI, a runbook — names its path on a live line. Comment lines, the dated history
# (aps/CHANGELOG.md, BUGS.md) and a bare list entry (the baseline above) call nothing, so a script
# only they name is dead weight the next reader has to rule out.
script_caller_row() {
  local f refs
  local -a orphans=()
  for f in $(git ls-files 'scripts/*.sh' 'scripts/*.py'); do
    refs="$(git grep -n -F -e "$f" -- . ":!$f" ":!aps/CHANGELOG.md" ":!BUGS.md" \
      | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#" | grep -vxE "[^:]+:[0-9]+:$f")"
    [ -n "$refs" ] || orphans+=("$f")
  done
  [ ${#orphans[@]} -eq 0 ] || { printf 'scripts no tracked file calls:\n' >&2; printf '%s\n' "${orphans[@]}" >&2; return 1; }
}
check script_caller_row
# The detector's own gate (the AGNOSTIC_SHAPE lesson: a row whose detector cannot go red is not a
# row). The same spdx_offenders bytes the row runs, over a fabricated corpus: a new unheadered
# script is the one offender; a baseline member without the header and a newcomer WITH it are not.
spdx_offenders_cases() {
  local tmp off
  tmp="$(mktemp -d)"
  printf "#!/usr/bin/env bash\necho hi\n" > "$tmp/new.sh"
  printf "#!/usr/bin/env bash\n" > "$tmp/old.sh"
  printf "#!/usr/bin/env bash\n# SPDX-FileCopyrightText: 2026 APS Conecta\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n" > "$tmp/headered.sh"
  off="$(SPDX_BASELINE="$tmp/old.sh" spdx_offenders "$tmp/new.sh" "$tmp/old.sh" "$tmp/headered.sh")"
  rm -rf "$tmp"
  [ "$off" = "$tmp/new.sh" ] \
    || { echo "spdx detector: expected exactly the new unheadered script, got: $off" >&2; return 1; }
}
check spdx_offenders_cases
# And the baseline row's red test, in a scratch git tree so "tracked" is real: a frozen line
# naming a tracked headerless script passes; a line for a file that gained its header, and one
# for a file that is gone, both red — each named with its cause.
spdx_baseline_cases() {
  local tmp out
  tmp="$(mktemp -d)"
  printf "#!/usr/bin/env bash\n" > "$tmp/old.sh"
  printf "#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n" > "$tmp/gained.sh"
  if ! ( cd "$tmp" && git init -q . && git add old.sh gained.sh \
         && SPDX_BASELINE="old.sh" spdx_baseline_row ); then
    rm -rf "$tmp"; echo "spdx baseline: a frozen line naming a tracked headerless script red" >&2; return 1
  fi
  out="$( cd "$tmp" && SPDX_BASELINE="old.sh
gained.sh
gone.sh" spdx_baseline_row 2>&1 )"
  rm -rf "$tmp"
  printf '%s\n' "$out" | grep -q "gained.sh (has the header — drop its baseline line)" \
    && printf '%s\n' "$out" | grep -q "gone.sh (no longer a tracked file)" \
    || { echo "spdx baseline: a gained header or a vanished file did not red with its cause: $out" >&2; return 1; }
}
check spdx_baseline_cases
# The AIA URI is read out of a REMOTE certificate over an unverified handshake, so it is
# attacker-chosen input that used to be interpolated into a `sh -c` string. The strip that
# looked like a mitigation (`tr -d '[:space:]'`) is not one: a payload needs no whitespace.
check bash -c '
  source provisioning/lib.sh
  q=$(printf "\047")
  aia_is_safe "https://ca.example.org/int.crt"   || exit 1
  aia_is_safe "http://ca.example.org/int.crt"    || exit 1
  aia_is_safe ""                                 && exit 1
  aia_is_safe "file:///etc/passwd"               && exit 1
  aia_is_safe "https://x.org/a;id>/tmp/pwned;"   && exit 1
  aia_is_safe "https://x.org/a${q}b"             && exit 1
  aia_is_safe "https://x.org/a b"                && exit 1
  # A LINE-anchored match would let this through: the first line is clean.
  aia_is_safe "$(printf "https://ok.example.org/a\n;id")" && exit 1
  # The two pointers this actually follows in production. Nothing else pins them, and
  # refusing a legal one silently kills the feeds the whole function exists to keep.
  aia_is_safe "http://secure.globalsign.com/cacert/gsgccr6alphasslca2025.crt" || exit 1
  aia_is_safe "http://secure.globalsign.com/cacert/gsrsaovsslca2018.crt"      || exit 1
  # Legal AIA forms a tighter set would have refused (AD CS emits %20).
  aia_is_safe "http://ca.example.org/a%20b.crt" || exit 1
  aia_is_safe "http://ca.example.org/a+b.crt"   || exit 1
  aia_is_safe "HTTP://ca.example.org/a.crt"     || exit 1
  aia_is_safe "http://ca.example.org/a.crt?id=7" || exit 1
  # Length is a safety property here, not tidiness: every character is legal, and the
  # value goes on to be an argv entry and a path component. At 128KB `basename` cannot
  # exec at all, which under the phase errexit is fatal — measured rc 126.
  aia_is_safe "http://ca.example.org/$(printf "a%.0s" $(seq 1 200000)).crt" && exit 1
  # `[A-Za-z]` is a range, and a range collates: under es_CL.UTF-8 — the locale a Chilean
  # dev runs — an accented byte falls inside it, so the allowlist read narrower than it was.
  aia_is_safe "http://ca.example.org/café.crt" && exit 1
  exit 0'
# The reporter's welcome arm lists live sections with a fragment that runs INSIDE the container
# (`sh -c` under nc_exec) — the parser class divergence.sh's header warns turns a report silently
# green when it rots. Read out of the script (not restated) and run against a scratch groupfolder
# tree: a folder that owns its JSON is a section, images/ and a JSON-less folder are not.
check python3 -c '
import os, re, subprocess, sys, tempfile
src = open("scripts/divergence.sh", encoding="utf-8").read()
m = re.search(r"# --- welcome sections.*?nc_exec --user www-data -- sh -c \x27(.*?)\x27 sh ", src, re.S)
if not m:
    print("welcome arm listing fragment not found in scripts/divergence.sh"); sys.exit(1)
frag = m.group(1)
root = tempfile.mkdtemp(); es = os.path.join(root, "__groupfolders", "20", "files", "es")
for d in ("noticias", "images", "_resources", "campanas"): os.makedirs(os.path.join(es, d))
open(os.path.join(es, "noticias", "noticias.json"), "w").write("{}")
open(os.path.join(es, "images", "x.svg"), "w").write("<svg/>")
out = subprocess.run(["sh", "-c", frag, "sh", root, "20"], capture_output=True, text=True)
if out.returncode != 0 or out.stdout.split() != ["noticias"]:
    print("welcome arm listing fragment answered " + repr(out.stdout) + " (want exactly noticias): " + out.stderr[:200]); sys.exit(1)
out = subprocess.run(["sh", "-c", frag, "sh", root, "99"], capture_output=True, text=True)
if out.returncode != 0 or out.stdout.strip() != "":
    print("welcome arm listing fragment must answer nothing, exit 0, when the folder is absent"); sys.exit(1)'
# The renderer is the seam's whole "declare, don't hard-code" (review M3) in one file, so it is
# gated the way the identity round-trip is: real values in, the produced tree inspected, and the
# refusals SEEDED — a renderer that cannot go red is not a gate. The register holds names with
# quotes and backslashes (the deis round trip in the register gate), so one identity value carries both.
check python3 -c '
import json, os, shlex, subprocess, sys, tempfile
R = "provisioning/intravox/render.py"; L = "provisioning/intravox/es"
base = {"SITE_NOMBRE": "Centro de Salud Familiar Prueba", "SITE_NOMBRE_CORTO": "CESFAM Prueba",
        "SITE_DIRECCION": "Calle 1", "SITE_COMUNA": "Comuna", "SITE_SERVICIO_SALUD": "SS Prueba", "IV_MOUNT": "Intranet",
        "SITE_FOLDERS": "Transversal\nSectores/Sector 1\nProgramas/X\nUnidades/OIRS", "SITE_SUBFOLDERS": "Protocolos\nFlujogramas",
        "SITE_TEAMS": "sector-1|Sector 1\nprog-x|Programa X", "SITE_WELCOME": "noticias|wall\nvida-cesfam|\ndocumentos|wall"}
def run(env):
    # The values sit in bash as PLAIN shell variables (what seed.sh has after sourcing the site
    # file — nothing exported) and only the phase-shaped `env NAME="$NAME" …` line hands them to
    # python. A name that line forgets is invisible to render.py, exactly as on a real seed; a
    # gate that filled os.environ directly could never see that.
    stage = tempfile.mkdtemp() + "/s"
    shell = "; ".join(k + "=" + shlex.quote(v) for k, v in env.items())
    forward = " ".join(k + "=\"$" + k + "\"" for k in env)
    p = subprocess.run(["bash", "-c", shell + "; env " + forward + " python3 " + R + " " + L + " " + stage],
                       env={k: v for k, v in os.environ.items() if not k.startswith("SITE_")}, capture_output=True, text=True)
    return p, stage
p, stage = run(base)
if p.returncode != 0: print("default render failed: " + p.stderr.strip()); sys.exit(1)
if os.path.isdir(stage + "/equipos"): print("default renders equipos — L0-01 says it ships without"); sys.exit(1)
nav = json.load(open(stage + "/navigation.json"))
if [i["id"] for i in nav["items"]] != ["nav_inicio", "nav_noticias", "nav_vida_cesfam", "nav_documentos"]:
    print("nav is not Inicio + the declared sections in order: " + str([i["id"] for i in nav["items"]])); sys.exit(1)
docs = open(stage + "/documentos/documentos.json").read()
if "/Transversal/Protocolos" not in docs or "/Transversal/Documentación" in docs:
    print("Documentos links are not the declared SITE_SUBFOLDERS"); sys.exit(1)
if "__" in open(stage + "/home.json").read(): print("home.json shipped a raw placeholder"); sys.exit(1)
p, stage = run({**base, "IV_MOUNT": "Sitio Web"})
for rel in ["noticias/bienvenida/bienvenida.json", "noticias/como-publicar/como-publicar.json"]:
    page = open(stage + "/" + rel, encoding="utf-8").read()
    if "__IV_MOUNT__" in page or "Sitio Web" not in page or "Intranet" in page:
        print(rel + " does not name the storage folder IV_MOUNT names (ADR-0016)"); sys.exit(1)
p, stage = run({**base, "SITE_WELCOME": base["SITE_WELCOME"] + "\nequipos|wall"})
if p.returncode != 0: print("equipos render failed: " + p.stderr.strip()); sys.exit(1)
hub = json.load(open(stage + "/equipos/equipos.json"))
links = [w for r in hub["layout"]["rows"] for w in r["widgets"] if w["type"] == "links"][0]["items"]
if len(links) != 2 or not os.path.isfile(stage + "/equipos/sector-1/sector-1.json"):
    print("equipos hub is not exactly the two declared teams"); sys.exit(1)
if "/Sectores/Sector 1" not in open(stage + "/equipos/sector-1/sector-1.json").read():
    print("team page does not link its own declared folder"); sys.exit(1)
p, stage = run({**base, "SITE_WELCOME": base["SITE_WELCOME"] + "\nequipos|wall", "SITE_TEAMS": "role-oirs|OIRS",
                "SITE_NOMBRE_CORTO": "CESFAM \"Dr. X\" \\ Sur"})
if p.returncode != 0: print("role row / hostile identity render failed: " + p.stderr.strip()[-300:]); sys.exit(1)
if "?dir=/Unidades/OIRS" not in json.dumps(json.load(open(stage + "/equipos/role-oirs/role-oirs.json")), ensure_ascii=False):
    print("a role row does not link the declared folder named after it (Unidades/OIRS)"); sys.exit(1)
hero = json.load(open(stage + "/home.json"))["layout"]["rows"][0]["widgets"][1]["content"]
if hero != "CESFAM \"Dr. X\" \\ Sur": print("an identity value with a quote and a backslash did not round-trip: " + repr(hero)); sys.exit(1)
for bad, why in [({"SITE_WELCOME": "noticias|fortress"}, "unknown flag"),
                 ({"SITE_WELCOME": "campanas|"}, "undeclared library section"),
                 ({"SITE_FOLDERS": "Sectores/Sector 1"}, "Files link to an undeclared root"),
                 ({"IV_MOUNT": "a/b"}, "a storage folder name with a slash"),
                 ({"SITE_WELCOME": base["SITE_WELCOME"] + "\nequipos|wall", "SITE_TEAMS": "sector-9|Sector 9"},
                  "a team whose folder the site does not declare")]:
    p, _ = run({**base, **bad})
    if p.returncode == 0 or "FATAL:" not in p.stderr:
        print("render.py accepted " + why); sys.exit(1)'
# The wall flag is the only thing the seam hands the engine about protection (review L4-01):
# per page, from the declaration, never a folder rule. Rendered and inspected, both ways. A wall
# is the section's STRUCTURE (owner decision 2026-09-28): the hub, a seeded page with sub-pages
# (noticias/avisos), every team page; the seeded example posts stay ordinary, deletable pages.
check python3 -c '
import json, os, shlex, subprocess, sys, tempfile
R = "provisioning/intravox/render.py"; L = "provisioning/intravox/es"
base = {"SITE_NOMBRE": "Centro de Salud Familiar Prueba", "SITE_NOMBRE_CORTO": "CESFAM Prueba",
        "SITE_DIRECCION": "Calle 1", "SITE_COMUNA": "Comuna", "SITE_SERVICIO_SALUD": "SS Prueba", "IV_MOUNT": "Intranet",
        "SITE_FOLDERS": "Transversal\nSectores/Sector 1\nProgramas/X", "SITE_SUBFOLDERS": "Protocolos\nFlujogramas",
        "SITE_TEAMS": "sector-1|Sector 1\nprog-x|Programa X",
        "SITE_WELCOME": "noticias|wall\nvida-cesfam|\ndocumentos|wall\nequipos|wall"}
def run(env):
    stage = tempfile.mkdtemp() + "/s"
    shell = "; ".join(k + "=" + shlex.quote(v) for k, v in env.items())
    forward = " ".join(k + "=\"$" + k + "\"" for k in env)
    p = subprocess.run(["bash", "-c", shell + "; env " + forward + " python3 " + R + " " + L + " " + stage],
                       env={k: v for k, v in os.environ.items() if not k.startswith("SITE_")}, capture_output=True, text=True)
    return p, stage
def walled(stage, rel):
    return json.load(open(stage + "/" + rel)).get("protected") is True
p, stage = run(base)
if p.returncode != 0: print("render failed: " + p.stderr.strip()); sys.exit(1)
for rel in ["noticias/noticias.json", "noticias/avisos/avisos.json", "documentos/documentos.json",
            "equipos/equipos.json", "equipos/sector-1/sector-1.json", "equipos/prog-x/prog-x.json"]:
    if not walled(stage, rel): print("wall page not stamped: " + rel); sys.exit(1)
for rel in ["vida-cesfam/vida-cesfam.json", "home.json", "noticias/bienvenida/bienvenida.json",
            "noticias/como-publicar/como-publicar.json", "noticias/avisos/aviso-ejemplo/aviso-ejemplo.json"]:
    if walled(stage, rel): print("editable page stamped as a wall: " + rel); sys.exit(1)
p, stage = run({**base, "SITE_WELCOME": "noticias|\nvida-cesfam|wall\ndocumentos|wall"})
if p.returncode != 0: print("render failed: " + p.stderr.strip()); sys.exit(1)
if walled(stage, "noticias/noticias.json") or not walled(stage, "vida-cesfam/vida-cesfam.json"):
    print("the wall follows the library, not the declaration"); sys.exit(1)'
# The mount name has ONE seam-side home (env.sh) and ONE engine-side reader (appconfig
# groupfolder_name, ADR-0016). Both readers here take it from env.sh; the sandbox stub derives the
# folder row from the appconfig row — so a rename is one line, and a literal left behind is a mount
# the seed cannot find. Seeded: the stub arm is exercised with no row, one row, and a re-set (the
# config:app:set arm appends, so the LAST write must win, as it does in Nextcloud).
check python3 -c '
import re, sys
env = open("scripts/env.sh", encoding="utf-8").read()
if len(re.findall(r"^IV_MOUNT=", env, re.M)) != 1:
    print("scripts/env.sh must define IV_MOUNT exactly once"); sys.exit(1)
for f in ["provisioning/phases/41-intravox.sh", "scripts/divergence.sh"]:
    src = open(f, encoding="utf-8").read()
    if "$IV_MOUNT" not in src:
        print(f + " does not read IV_MOUNT"); sys.exit(1)
    if re.search(r"==\s*\"IntraVox\"|\"IntraVox\"\)", src):
        print(f + " still looks a mount up by the literal"); sys.exit(1)
stub = open("scripts/provisionador.py", encoding="utf-8").read()
m = re.search(r"elif \"intravox:setup\" in args:\n(.*?)\nelif ", stub, re.S)
if not m or "groupfolder_name" not in m.group(1):
    print("provisionador: the intravox:setup arm does not derive the folder name from the appconfig row"); sys.exit(1)
arm = "\n".join(l[4:] if l.startswith("    ") else l for l in m.group(1).splitlines())
cfg = lambda v: ["appconfig", "intravox", "groupfolder_name", v]
for rows, want in (([cfg("Intranet")], "Intranet"), ([], "IntraVox"), ([cfg("Intranet"), cfg("Sitio")], "Sitio")):
    ns = {"rows": list(rows), "args": ["occ", "intravox:setup"], "save": lambda r: None}
    exec(arm, ns)
    if [r[1] for r in ns["rows"] if r[0] == "folder"] != [want]:
        print("provisionador setup arm: expected one folder row named " + want + ", got " + repr(ns["rows"])); sys.exit(1)'
# Phase 41's refusal is the only thing between an install whose folder carries another name and
# a second, empty mount (ADR-0016). Extracted from the phase's own bytes (a named function: the
# stub needs quotes the bash -c wrapper cannot nest) and run against a stubbed occ, both ways:
# a fresh install, the runbook's end state and an explicit override pass; the lab's unrenamed
# folder, a half-done runbook, a later IV_MOUNT change, a dict-shaped listing and a name the
# engine refuses all FATAL.
iv_mount_guard_cases() {
  local guard want mounts told iv out rc
  guard="$(sed -n '/^case "\$IV_MOUNT" in$/,/^occ config:app:set intravox groupfolder_name/p' provisioning/phases/41-intravox.sh | sed '$d')"
  [ -n "$guard" ] || { echo "iv mount guard: block not found in 41-intravox.sh" >&2; return 1; }
  while IFS='|' read -r want mounts told iv; do
    out="$(MOUNTS_JSON="$mounts" TOLD="$told" IV_MOUNT="$iv" bash -c '
      occ() { case "$1" in
        groupfolders:list) printf "%s" "$MOUNTS_JSON" ;;
        config:app:get) [ -n "$TOLD" ] && printf "%s\n" "$TOLD" ;;
      esac; }
      eval "$1"; echo PASSED' _ "$guard" 2>&1)"; rc=$?
    case "$want" in
      pass) [ "$rc" = 0 ] && [ "${out##*$'\n'}" = PASSED ] || { echo "iv mount guard: expected pass for mounts=$mounts told=$told IV_MOUNT=$iv, got: $out" >&2; return 1; } ;;
      fatal) [ "$rc" != 0 ] && [[ "$out" == FATAL:* ]] || { echo "iv mount guard: expected FATAL for mounts=$mounts told=$told IV_MOUNT=$iv, got: $out" >&2; return 1; } ;;
    esac
  done <<'CASES'
pass|[]||Intranet
pass|[{"id":1,"mount_point":"Intranet"}]|Intranet|Intranet
pass|[{"id":1,"mount_point":"IntraVox"}]||IntraVox
pass|[{"id":1,"mount_point":"Transversal"}]||Intranet
fatal|[{"id":1,"mount_point":"IntraVox"}]||Intranet
fatal|[{"id":1,"mount_point":"IntraVox"}]|Intranet|Intranet
fatal|[{"id":1,"mount_point":"Intranet"}]|Intranet|Sitio Web
fatal|{"1":{"id":1,"mount_point":"IntraVox"}}||Intranet
fatal|[]||a/b
fatal|[]||   
CASES
}
check iv_mount_guard_cases
# divergence.sh's side of the same rule: a live storage root under another name (the default, or
# the name the engine was last told) is reported as a rename, never with the generic delete
# advice; an unrelated undeclared folder still gets that advice. Extracted from the script.
iv_mount_divergence_cases() {
  local loop out
  loop="$(sed -n '/^iv_told="\$(occ config:app:get intravox groupfolder_name/,/^done <<< "\$live_folders"$/p' scripts/divergence.sh)"
  [ -n "$loop" ] || { echo "divergence mount loop not found" >&2; return 1; }
  out="$(IV_MOUNT="Sitio Web" TOLD=Intranet bash -c '
    occ() { [ "$1" = config:app:get ] && [ -n "$TOLD" ] && printf "%s\n" "$TOLD"; }
    note() { printf "NOTE %s\n" "$*"; }
    declared_folders="$(printf "%s\n" Transversal "$IV_MOUNT")"
    live_folders="$(printf "1\tIntranet\n2\tIntraVox\n3\tViejo\n4\tTransversal\n")"
    eval "$1"' _ "$loop" 2>&1)"
  printf '%s\n' "$out" | grep -q "^NOTE la carpeta compartida 'Intranet' guarda la portada.*cámbiele el nombre una vez" \
    || { echo "divergence: the told name is not reported as a rename: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "^NOTE la carpeta compartida 'IntraVox' guarda la portada" \
    || { echo "divergence: the default name is not reported as a rename: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "^NOTE la carpeta compartida 'Viejo' existe pero no está en SITE_FOLDERS" \
    || { echo "divergence: an unrelated folder lost the generic note: $out" >&2; return 1; }
  [ "$(printf '%s\n' "$out" | grep -c "groupfolders:delete [12]\b")" = 0 ] \
    || { echo "divergence: a storage root was offered for deletion: $out" >&2; return 1; }
}
check iv_mount_divergence_cases
# Estadística's establishment, both halves, extracted from the scripts: phase 16 writes the three
# keys only behind a six-digit SITE_DEIS (anything else the app reads as no establishment, in
# silence), and divergence.sh names each key that differs from the site file — and an occ that
# cannot answer, never as a clean pass.
estadistica_identity_cases() {
  local guard section out rc want deis
  guard="$(sed -n '/^case "\${SITE_DEIS:-}" in$/,/^app_config_set estadistica comuna_cut/p' provisioning/phases/16-app-policy.sh)"
  [ -n "$guard" ] || { echo "estadistica guard: block not found in 16-app-policy.sh" >&2; return 1; }
  while IFS='|' read -r want deis; do
    out="$(SITE=lab SITE_DEIS="$deis" SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 bash -c '
      app_config_set() { printf "SET %s %s %s\n" "$@"; }
      eval "$1"' _ "$guard" 2>&1)"; rc=$?
    case "$want" in
      pass) [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^SET estadistica ')" = 3 ] \
        && printf '%s\n' "$out" | grep -qx "SET estadistica deis_code $deis" \
        || { echo "estadistica guard: expected three writes for SITE_DEIS='$deis', got: $out" >&2; return 1; } ;;
      fatal) [ "$rc" != 0 ] && [[ "$out" == FATAL:* ]] && ! printf '%s\n' "$out" | grep -q '^SET ' \
        || { echo "estadistica guard: expected FATAL and no write for SITE_DEIS='$deis', got: $out" >&2; return 1; } ;;
    esac
  done <<'CASES'
pass|999001
fatal|
fatal|99900
fatal|9990011
fatal|99900a
fatal| 999001
CASES
  section="$(sed -n "/^# --- estadistica's establishment/,/^fi$/p" scripts/divergence.sh)"
  [ -n "$section" ] || { echo "estadistica divergence: section not found in divergence.sh" >&2; return 1; }
  out="$(SITE=lab SITE_DEIS=999001 SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 bash -c '
    occ() { case "$1" in status) return 0 ;; config:app:get) case "$3" in deis_code) echo 999001 ;; establishment_type) echo CESFAM ;; comuna_cut) echo 09999 ;; esac ;; esac; }
    note() { printf "NOTE %s\n" "$*"; }
    eval "$1"' _ "$section" 2>&1)"
  [ -z "$out" ] || { echo "estadistica divergence: matching keys were reported: $out" >&2; return 1; }
  out="$(SITE=lab SITE_DEIS=999001 SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 bash -c '
    occ() { case "$1" in status) return 0 ;; config:app:get) [ "$3" = deis_code ] && echo 999002; return 0 ;; esac; }
    note() { printf "NOTE %s\n" "$*"; }
    eval "$1"' _ "$section" 2>&1)"
  printf '%s\n' "$out" | grep -q "^NOTE estadistica deis_code es '999002' pero sites/lab/site.sh dice '999001'" \
    && printf '%s\n' "$out" | grep -q "^NOTE estadistica establishment_type es '<sin valor>' pero sites/lab/site.sh dice 'CESFAM'" \
    && [ "$(printf '%s\n' "$out" | grep -c '^NOTE ')" = 3 ] \
    || { echo "estadistica divergence: a wrong and two unset keys were not each reported: $out" >&2; return 1; }
  out="$(SITE=lab SITE_DEIS=999001 bash -c '
    occ() { return 1; }
    note() { printf "NOTE %s\n" "$*"; }
    eval "$1"' _ "$section" 2>&1)"
  printf '%s\n' "$out" | grep -q "^NOTE no se pudieron leer las claves del establecimiento en estadistica" \
    || { echo "estadistica divergence: an occ that did not answer passed: $out" >&2; return 1; }
}
check estadistica_identity_cases

# Phase 30 installs the organization conventions verbatim as «LÉEME — Convenciones.md». The whole
# phase runs under errexit (seed.sh's own shape) with its helpers stubbed, from a scratch root: with
# provisioning/data/convenciones.md present the file's bytes are what it writes; without it the
# phase stops before writing (a failing $(cat …) inside an argument would not trip errexit).
conventions_phase_cases() {
  local tmp out rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/provisioning/data"
  printf 'regla uno\n«dos»\n' > "$tmp/provisioning/data/convenciones.md"
  run30() {
    ( cd "$tmp" && bash -c '
        set -e
        SITE_FOLDERS=(); SITE_SUBFOLDERS=()
        phase_begin() { :; }; phase_end() { :; }
        ensure_groupfolder() { :; }; ensure_gf_subfolder() { :; }
        ensure_gf_file() { printf "WRITE %s|%s|%s\n" "$1" "$2" "$3"; }
        . "$1"' _ "$OLDPWD/provisioning/phases/30-folders.sh" 2>&1 )
  }
  out="$(run30)"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = "$(printf 'WRITE Transversal|LÉEME — Convenciones.md|regla uno\n«dos»')" ] \
    || { echo "phase 30: expected the conventions file's bytes written, got rc=$rc: $out" >&2; rm -rf "$tmp"; return 1; }
  rm "$tmp/provisioning/data/convenciones.md"
  out="$(run30)"; rc=$?
  [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q '^FATAL: ' && ! printf '%s\n' "$out" | grep -q '^WRITE ' \
    || { echo "phase 30: a missing conventions file must stop the phase before any write, got rc=$rc: $out" >&2; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}
check conventions_phase_cases

# Phase 10 seeds the instance time zone (default_timezone) from the Nextcloud container's TZ, the
# zone chosen in AIO. Same shape as above: the whole phase under errexit, helpers stubbed, nc_exec
# standing in for the container's printenv. Not AIO (the legacy container) seeds no zone.
locale_phase_cases() {
  local out rc
  run10() {  # AIO(1|0) CONTAINER_UP(1|0)
    AIO="$1" UP="$2" bash -c '
      set -e
      phase_begin() { :; }; phase_end() { :; }
      config_system_set() { printf "SET %s|%s\n" "$1" "$2"; }
      is_aio() { [ "$AIO" = 1 ]; }
      nc_exec() {
        [ "$UP" = 1 ] || return 1
        [ "$*" = "-- printenv TZ" ] && echo America/Santiago
      }
      . provisioning/phases/10-locale.sh' 2>&1
  }
  out="$(run10 1 1)"; rc=$?
  [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qxF 'SET default_timezone|America/Santiago' \
    || { echo "phase 10: expected default_timezone seeded from the container's TZ, got rc=$rc: $out" >&2; return 1; }
  out="$(run10 1 0)"; rc=$?
  [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q '^FATAL: ' && ! printf '%s\n' "$out" | grep -q '^SET default_timezone' \
    || { echo "phase 10: an unreadable TZ must stop the phase with a FATAL and no zone written, got rc=$rc: $out" >&2; return 1; }
  out="$(run10 0 1)"; rc=$?
  [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q '^SET default_timezone' \
    || { echo "phase 10: the legacy container has no AIO zone and must get none, got rc=$rc: $out" >&2; return 1; }
}
check locale_phase_cases

# The suite manifest unreadable: the gate's apps section says so in ONE Spanish note carrying the
# cause — apps.py's own stderr no longer reaches the operator beside it, and the red branch never
# execs into the instance. Extracted, run in a temp tree whose apps.json is not JSON.
manifest_unreadable_divergence_case() {
  local section tmp out
  section="$(sed -n '/^# --- apps unpacked into custom_apps/,/^fi$/p' scripts/divergence.sh)"
  [ -n "$section" ] || { echo "manifest divergence: apps section not found in divergence.sh" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir "$tmp/scripts"
  cp scripts/apps.py "$tmp/scripts/apps.py"; printf '{no es JSON' > "$tmp/apps.json"
  out="$(cd "$tmp" && bash -c '
    note() { printf "NOTE %s\n" "$*"; }
    nc_exec() { echo "nc_exec reached"; }
    eval "$1"' _ "$section" 2>&1)"
  rm -rf "$tmp"
  [ "$out" = "NOTE no se pudieron revisar las aplicaciones: no se pudo leer la lista de aplicaciones de la suite ($tmp/apps.json): no es JSON válido (línea 1, columna 2)" ] \
    || { echo "manifest divergence: expected the one Spanish note, got: $out" >&2; return 1; }
}
check manifest_unreadable_divergence_case

# Territorio's basemap is OpenStreetMap's own tile service (ADR-0021 in that repo), loaded by each
# user's browser: nothing about it is provisioned. Phase 16 used to write a tile_url (the suite's
# /tiles/ archive); it writes none now, and the two keys the app derives its map extent from —
# the comuna's CUT and name — must still land. Behavioural, not a grep: the WHOLE phase runs under
# errexit with its helpers stubbed, once as AIO and once not (the old block branched on that), and
# the assertions are on what it writes. is_aio / conf_load / conf_get are stubbed to a marker so a
# phase that went back to asking how the instance is reached is caught too.
territorio_phase16_cases() {
  local aio out
  for aio in 1 0; do
    out="$(AIO="$aio" SITE=lab SITE_DEIS=999001 SITE_TIPO=CESFAM SITE_COMUNA_CUT=09999 SITE_COMUNA="Comuna Prueba" \
      SEED_CTX=1 bash -e -o pipefail -c '
      phase_begin() { :; }; phase_end() { :; }
      app_restrict_to_groups() { printf "RESTRICT %s\n" "$1"; }; app_disable() { printf "DISABLE %s\n" "$1"; }
      is_aio() { echo "ASKED is_aio"; [ "$AIO" = 1 ]; }
      conf_load() { echo "ASKED conf_load"; }
      conf_get() { echo "ASKED conf_get $*"; }
      log() { :; }
      app_config_set() { printf "SET %s %s %s\n" "$@"; }
      . provisioning/phases/16-app-policy.sh' 2>&1)" \
      || { echo "phase 16: failed under errexit for aio=$aio: $out" >&2; return 1; }
    printf '%s\n' "$out" | grep -qx "SET territorio comuna_cut 09999" \
      && printf '%s\n' "$out" | grep -qx "SET territorio comuna_name Comuna Prueba" \
      || { echo "phase 16: territorio's comuna_cut / comuna_name were not written for aio=$aio: $out" >&2; return 1; }
    ! printf '%s\n' "$out" | grep -Eq '^(DISABLE|RESTRICT) office$' \
      || { echo "phase 16: Office navigation must remain available to staff" >&2; return 1; }
    ! printf '%s\n' "$out" | grep -q "tile_url" \
      || { echo "phase 16: a tile_url was written or mentioned for aio=$aio — nothing provisions the basemap any more: $out" >&2; return 1; }
    ! printf '%s\n' "$out" | grep -q "^ASKED" \
      || { echo "phase 16: asked how the instance is reached (aio=$aio) — only the tile_url needed that: $out" >&2; return 1; }
  done
}
check territorio_phase16_cases

# I0: the session posture of phase 05 and the helper it calls. Three
# extracted-block cases in the shape above. Phase 05 is sourced with its three helpers stubbed to
# print what they were asked, so the assertion is the call itself (key, value, type), not a grep
# for a spelling. The last line is a NEGATIVE pin: `encryption.enabled` /
# `encryption.key_storage_migrated` were deliberately NOT ported (not verified as config.php keys;
# server-side encryption is `occ encryption:enable` plus a key-management decision with backup,
# group-folder and Office consequences) — a later edit that adds them must be a decision, not drift.
session_hardening_cases() {
  local out
  out="$(bash -e -o pipefail -c '
    phase_begin() { :; }
    phase_end() { :; }
    config_system_set() { printf "SET %s %s %s\n" "$@"; }
    app_enable() { printf "ENABLE %s\n" "$@"; }
    . provisioning/phases/05-security.sh' 2>&1)" \
    || { echo "session hardening: phase 05 failed under errexit: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -qxF "SET session_lifetime 900 integer" \
    || { echo "session hardening: session_lifetime 900 (integer) not set: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -qxF "SET session_keepalive false boolean" \
    || { echo "session hardening: session_keepalive false (boolean) not set: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -qxF "ENABLE admin_audit" \
    || { echo "session hardening: admin_audit not enabled: $out" >&2; return 1; }
  printf '%s\n' "$out" | grep -q "encryption" \
    && { echo "session hardening: phase 05 touches encryption.* — deliberately not ported: $out" >&2; return 1; }
  return 0
}
check session_hardening_cases
# The break-glass role is a role/group only — no permissions, no override mechanism. What is pinned
# is its presence in the registry both readers parse (registry_groups, role_categories) and its
# category, which 50-users and the roster frame read to decide the cat-* its holder also joins.
check python3 -c '
import sys
sys.path.insert(0, "scripts")
import provisionador as p
f = "provisioning/phases/20-groups.sh"
rid = "role-emergencia-breakglass"
assert rid in p.registry_groups(f), "registry_groups does not know " + rid
assert p.role_categories(f, [])[rid] == "cat-clinicos", "wrong category for " + rid
assert [rid, "Acceso de Emergencia (Break-Glass)"] in p.role_names(f), "role_names lacks " + rid'
# app_enable: query-before-enable, like app_disable beside it. Already enabled -> no occ call at all
# (a second seed must write nothing, or seed-idempotent reddens), twice in a row; absent -> one
# `app:enable`; a failing enable is reported and returned, never swallowed.
app_enable_cases() {
  local out
  # The helper sends occ's own output to /dev/null, so the stub records its calls in a file.
  out="$(CALLS="$(mktemp)" bash -c '
    . scripts/env.sh; . provisioning/lib.sh
    conf_load() { :; }
    conf_get() { printf "yes\n"; }
    occ() { printf "OCC %s\n" "$*" >> "$CALLS"; }
    log() { printf "LOG %s\n" "$*"; }
    app_enable admin_audit && app_enable admin_audit; cat "$CALLS"; rm -f "$CALLS"' 2>&1)" \
    || { echo "app_enable: an already-enabled app failed: $out" >&2; return 1; }
  [ "$out" = "LOG app admin_audit already enabled
LOG app admin_audit already enabled" ] \
    || { echo "app_enable: not idempotent when already enabled: $out" >&2; return 1; }
  out="$(CALLS="$(mktemp)" bash -c '
    . scripts/env.sh; . provisioning/lib.sh
    conf_load() { :; }
    conf_get() { return 1; }
    occ() { printf "OCC %s\n" "$*" >> "$CALLS"; }
    log() { printf "LOG %s\n" "$*"; }
    app_enable admin_audit; cat "$CALLS"; rm -f "$CALLS"' 2>&1)" \
    || { echo "app_enable: enabling an absent app failed: $out" >&2; return 1; }
  [ "$out" = "LOG app admin_audit -> enabled
OCC app:enable admin_audit" ] \
    || { echo "app_enable: an absent app was not enabled once: $out" >&2; return 1; }
  out="$(bash -c '
    . scripts/env.sh; . provisioning/lib.sh
    conf_load() { :; }
    conf_get() { printf "no\n"; }
    occ() { return 1; }
    log() { printf "LOG %s\n" "$*"; }
    app_enable admin_audit' 2>&1)" \
    && { echo "app_enable: a failing enable returned 0: $out" >&2; return 1; }
  [ "$out" = "LOG FAILED to enable admin_audit" ] \
    || { echo "app_enable: a failing enable was not said: $out" >&2; return 1; }
}
check app_enable_cases

# A boolean system key converges: config:list stores session_keepalive as JSON false and conf_get
# renders it "" (occ's own rendering), so a setter that compares that against the word "false"
# writes on every seed and seed-idempotent reddens. Stored false -> no write; absent or true -> one.
config_system_bool_cases() {
  local cache want out
  while IFS='|' read -r cache want; do
    out="$(CALLS="$(mktemp)" CACHE="$cache" bash -c '
      . scripts/env.sh; . provisioning/lib.sh
      CONF_CACHE="$CACHE"
      occ() { printf "OCC %s\n" "$*" >> "$CALLS"; }
      log() { :; }
      config_system_set session_keepalive false boolean; cat "$CALLS"; rm -f "$CALLS"' 2>&1)"
    case "$want" in
      none) [ -z "$out" ] ;;
      write) [ "$out" = "OCC config:system:set session_keepalive --type=boolean --value=false" ] ;;
    esac || { echo "config_system_set: cache $cache expected $want, got: $out" >&2; return 1; }
  done <<'CASES'
{"system": {"session_keepalive": false}}|none
{"system": {}}|write
{"system": {"session_keepalive": true}}|write
CASES
}
check config_system_bool_cases

# The café case above is behavioural, and load-bearing only under a COLLATING locale — which a
# Chilean dev has and GitHub's runners do not, defaulting to C.UTF-8 where that range refuses `é`
# anyway. So CI stays green on a revert, and CI is the only mechanical gate (AGENTS.md). This is
# the half CI can see. A grep for the fix, deliberately: where it runs, the behaviour is not
# observable at all, and a check that cannot fail there is worse than one that admits what it is.
check grep -q "local LC_ALL=C" provisioning/lib.sh

# --- gate: the tree stays establishment-agnostic (ADR-0009, generalized from the one-code grep) ---
# Shape-based, not literal: the pilot's residue was a hardcoded `deis.py` call in CI's fixture and steering
# examples in docs. A literal grep on one clinic's code is the pilot's number all over again — the
# next clinic's code passes it. The SHAPE is the contract: no tracked file may hand deis.py a DEIS
# code. Only the register CSVs are excluded — they ARE the codes, by design — and dated history
# is scrubbed, so nothing else gets a pass. git grep, not grep -r: tracked files only,
# so a developer's sites/<slug>/site.sh (untracked, generated) never trips it. The shape lives in
# ONE exported variable so the self-test below red-tests the same bytes this check runs — and the
# planted literal is ASSEMBLED at run time (%s + a fabricated code), because a literal here would
# itself be a tracked hit and the gate would trip on its own detector test forever.
AGNOSTIC_SHAPE='deis\.py [0-9]{4,6}'
export AGNOSTIC_SHAPE
check bash -c '
  hits=$(git grep -nE "$AGNOSTIC_SHAPE" -- . ":(exclude)sites/establecimientos-deis-*.csv" 2>/dev/null || true)
  [ -z "$hits" ] || { printf "establishment-agnostic gate — tracked files naming a DEIS code:\n%s\n" "$hits" >&2; exit 1; }'
# The negative half: the detector must detect, and must not fire on a clean line. Same shape
# variable, fabricated corpus, run-time-assembled plant.
check bash -c '
  tmp=$(mktemp); trap "rm -f $tmp" EXIT
  printf "run: scripts/deis.py %s --new x\nclean line, no code\n" 999999 > "$tmp"
  grep -nE "$AGNOSTIC_SHAPE" "$tmp" >/dev/null || { echo "agnostic detector: planted literal went undetected" >&2; exit 1; }
  printf "nothing here at all\n" | grep -nE "$AGNOSTIC_SHAPE" >/dev/null && { echo "agnostic detector: false positive on a clean line" >&2; exit 1; }
  exit 0'

# === the theme, the sites register and the data masters ===========================================
# Their gates live beside them: the vendored map bytes, the env template's placeholders, the
# theme's assets and lockups, the DEIS register's round trip through deis.py, and the data manifest.
# --- gate (L5 S4): the vendored map libraries are the pinned bytes ---------------------------------
# The Centro pane's engine is two files copied byte-identical from territorio's node_modules
# (https://aps-conecta.github.io/documentation/desarrollo/licencias.html). Vendored bytes are the one diff a reviewer reads as "just assets":
# territorio upgrades, a re-vendor misses a file, an editor "fixes" a minified line — and the
# installer's map changes with no gate the eye can catch. The pair-pin discipline,
# applied to vendored files: each must exist and hash to its pin. The negative half mutates one
# byte of a copy — a gate that cannot go red is not a gate.
check python3 -c '
import hashlib, os, sys, tempfile
PINS = {
    "themes/apsconecta/core/mapa/leaflet.js":
        "db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a",
    "themes/apsconecta/core/mapa/leaflet.css":
        "a7837102824184820dfa198d1ebcd109ff6d0ff9a2672a074b9a1b4d147d04c6",
}
def distinta(corpus):   # the first path whose bytes are not its pin, or None
    for ruta, pin in corpus.items():
        with open(ruta, "rb") as fh:
            if hashlib.sha256(fh.read()).hexdigest() != pin:
                return ruta
    return None
real = distinta(PINS)
with tempfile.TemporaryDirectory() as tmp:
    mutada = os.path.join(tmp, "leaflet.css")
    with open("themes/apsconecta/core/mapa/leaflet.css", "rb") as src:
        datos = bytearray(src.read())
    datos[100] ^= 1
    with open(mutada, "wb") as dst:
        dst.write(datos)
    drill = distinta({**PINS, mutada: PINS["themes/apsconecta/core/mapa/leaflet.css"]})
if real is not None:
    print("the vendored map libraries are not the pinned bytes: " + real)
if drill != mutada:
    print("the mutation drill passed — the gate could not see a changed byte")
sys.exit(0 if real is None and drill == mutada else 1)'
# A clinic must never be installed with the secrets this repository publishes. The Provisionador
# generates the fixture password when .env has none, so a placeholder survives only a hand-copy of
# the template. Behavioural, and driven from .env.example: the template is what defines a
# placeholder, so this cannot rot when one is reworded.
check bash -c '
  . scripts/env.sh
  require_real_secrets || exit 1
  shipped() { grep "^$1=" .env.example | cut -d= -f2-; }
  ( export "FIXTURE_USER_PASSWORD=$(shipped FIXTURE_USER_PASSWORD)"; require_real_secrets 2>/dev/null ) && exit 1
  # And a value that CARRIES the marker without EQUALING the template byte for byte. That is
  # what a quoted placeholder becomes once the loader in env.sh strips its quotes, and what a
  # `$$` one becomes once it undoes the escape — both conventions .env.example already uses.
  # The equality test this replaced let exactly this through: the
  # gate failed OPEN, silently, and a clinic would install with a published secret.
  ( export FIXTURE_USER_PASSWORD="\"$(shipped FIXTURE_USER_PASSWORD)\""; require_real_secrets 2>/dev/null ) && exit 1
  exit 0'
# Regression guard (ADR-0003): every STATIC asset server.css references must exist on disk. It shipped
# for months declaring four .woff2 files that were never generated, and the TTF fallback swallowed the
# 404s. The COUNT is asserted before the existence loop, and that is the point: `grep | while read`
# runs zero times when grep matches nothing and exits 0, so the guard passed on a file with no themed
# reference at all. Requiring every reference to be a themed absolute path also catches one of four
# drifting, which "at least one" would not.
#
# ONE path is excluded, by exact name and never by pattern: site.css is @import-ed by server.css but
# is GENERATED per install by phase 15 and is not tracked, so a checkout that has never been
# provisioned legitimately does not have it — and server.css declares the fallback that renders the
# product's own name until it does. A `*.css` or directory-wide exclusion here would silently stop
# checking assets added later, which is the exact shape of the bug this guard exists for.
check bash -c '
  css=themes/apsconecta/core/css/server.css
  total=$(grep -oE "url\(\"" "$css" | wc -l)   # the quote matters: server.css says "url()" in prose
  themed=$(grep -oE "url\(\"/themes/apsconecta[^\"]+\"" "$css" | wc -l)
  [ "$total" -ge 1 ] && [ "$total" -eq "$themed" ] || exit 1
  grep -oE "/themes/apsconecta[^\")]+" "$css" | sed "s|^/||" \
    | grep -vFx "themes/apsconecta/core/css/site.css" \
    | while read -r f; do [ -f "$f" ] || exit 1; done'
# Regression guard: every brand SVG must PARSE, not merely exist. Nextcloud serves a malformed SVG
# with a 200 and the browser renders nothing — silent, and the existence check above cannot see it.
# A double hyphen inside an XML comment once made logo-header.svg unparseable and the header logo
# vanished while every gate stayed green.
check python3 -c 'import glob,sys,xml.etree.ElementTree as ET
bad=[]
for f in sorted(glob.glob("themes/apsconecta/core/img/**/*.svg", recursive=True)):
    try: ET.parse(f)
    except Exception as e: bad.append(f"{f}: {e}")
if bad: print("\n".join(bad)); sys.exit(1)'
# Regression guard: a lockup that draws text must carry the font that text is set in. An SVG
# served as an image is an isolated document and cannot see server.css's @font-face, so the wordmark
# still renders — just in the OS fallback, which nobody reports as a bug.
# themes/apsconecta/tools/embed-fonts.py puts the subset in; this asserts it was run.
check python3 -c 'import glob,sys,re
bad=[]
for f in sorted(glob.glob("themes/apsconecta/core/img/**/*.svg", recursive=True)):
    s = open(f, encoding="utf-8").read()
    if not re.search(r"<text[ >]", s): continue
    if "@font-face" not in s or "data:font/woff2;base64," not in s:
        bad.append(f"{f}: draws <text> with no embedded @font-face — run themes/apsconecta/tools/embed-fonts.py")
    for fam in set(re.findall(r"font-family=\"([^\"]+)\"", s)):
        if "," in fam:
            bad.append(f"{f}: font-family=\"{fam}\" keeps an OS fallback; the embedded face must be the only option")
if bad: print("\n".join(bad)); sys.exit(1)'
# scripts/deis.py writes sites/<slug>/site.sh and provisioning/seed.sh SOURCES it, so every value
# it emits is shell syntax unless it is quoted. It was not: five register fields went into the file
# inside double quotes, raw. Six values in the shipped register carry a `"` or a backtick, and the
# two failure modes are different sizes of bad — DEIS 113314's address holds a backtick, which is a
# syntax error that kills the phase loop, while DEIS 201079's name holds quotes, which parses CLEAN,
# runs `Juan` as a command and leaves SITE_NOMBRE EMPTY. A clinic provisioned with no name, silently.
#
# Behavioural, and over the WHOLE register rather than the six known-bad rows: the register is
# regenerated from DEIS by `--snapshot`, so tomorrow's hostile value is one nobody has seen. Every
# row is emitted, sourced by a real bash, and compared byte-for-byte with what the CSV holds — one
# bash process for all of them, because 2655 forks is a gate nobody would keep.
#
# `bash -n` alone would not catch it: the DEIS 201079 shape passes a syntax check and still loses
# the value. The round trip is the assertion.
check python3 -c '
import csv, glob, re, subprocess, sys, os
sys.path.insert(0, "scripts")
import deis

register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))
if len(rows) < 100:
    print("register looks truncated: " + str(len(rows)) + " rows"); sys.exit(1)

FIELDS = {"SITE_NOMBRE": "nombre", "SITE_DIRECCION": "direccion",
          "SITE_COMUNA": "comuna", "SITE_SERVICIO_SALUD": "servicio_salud",
          "SITE_COMUNA_CUT": "comuna_codigo", "SITE_LON": "longitud", "SITE_LAT": "latitud"}

script = ["set -u"]
for row in rows:
    script.append(deis.block(row, "gate"))
    for var in FIELDS:
        script.append("printf \"%s\\n\" \"$" + var + "\"")
# On stdin, not argv: 2655 blocks is past ARG_MAX and bash never starts.
out = subprocess.run(["bash"], input="\n".join(script), capture_output=True, text=True)
if out.returncode != 0:
    print("sourcing the generated identity blocks failed: " + out.stderr.strip()[:300]); sys.exit(1)

got = out.stdout.split("\n")
bad = []
for i, row in enumerate(rows):
    for j, (var, field) in enumerate(FIELDS.items()):
        want, have = row[field], got[i * len(FIELDS) + j]
        if want != have:
            bad.append("DEIS " + row["codigo"] + " " + var + ": wrote " + repr(want) + ", bash read " + repr(have))
if bad:
    print("values the generated site.sh does not round-trip (" + str(len(bad)) + "):")
    for line in bad[:5]:
        print("  " + line)
    sys.exit(1)
# The CUT parity half: territorio'"'"'s Comuna::of() accepts exactly five digits, and a register
# value that missed that shape would disarm the import door silently on every install — the
# phase writes whatever the register says. Wrong-shaped CUTs are a register defect, and this
# is where it goes red instead.
bad_cut = [r["codigo"] for r in rows if not re.fullmatch(r"[0-9]{5}", r["comuna_codigo"])]
if bad_cut:
    print("comuna_codigo values Comuna::of() would refuse (not 5 digits) — a phase 16 write"
          " of any of these silently disarms the import door: " + ", ".join(bad_cut[:5]))
    sys.exit(1)'
# The register's coordinates have a WRITER (deis.py --coordenadas) that runs by hand once per
# MINSAL release, so this is where it is proven. On a scratch register of three real rows —
# 201079's quotes and 113314's backtick among them — it must refuse a source that misses an
# establishment and one whose latitude or longitude is not plain degrees, leaving the file untouched;
# then append the two columns as published (text, never re-rounded) with every original line kept
# byte for byte; then rewrite the same bytes when run again.
check python3 -c '
import csv, glob, os, shutil, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
point = {"110485": ("-33.976637", "-71.468749"), "201079": ("-51.728207", "-72.482647"),
         "113314": ("-33.56136", "-70.67469")}
rows = [r for r in csv.DictReader(open(register, encoding="utf-8")) if r["codigo"] in point]
if len(rows) != 3:
    print("the three probe rows are not in the register -- this check measured nothing"); sys.exit(1)
def source(path, codes, bad=None):
    feats = []
    for c in codes:
        lat, lon = point[c]
        if c == "113314" and bad:
            lat, lon = bad
        feats.append("{\"type\":\"Feature\",\"geometry\":null,\"properties\":{\"cod_vig\":" + c
                     + ".0,\"latitud\":" + lat + ",\"longitud\":" + lon + "}}")
    open(path, "w", encoding="utf-8").write("{\"type\":\"FeatureCollection\",\"features\":[" + ",".join(feats) + "]}")
def run(path):
    try:
        deis.coordinates_from(path)
        return None
    except SystemExit as e:
        return str(e)
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE); os.makedirs(os.path.join(tmp, "sites"))
    reg = os.path.join(tmp, "sites", "establecimientos-deis-2099-01-01.csv")
    with open(reg, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh); w.writerow(deis.COLUMNS); w.writerows([r[k] for k in deis.COLUMNS] for r in rows)
    before = open(reg, "rb").read()
    gj = os.path.join(tmp, "src.geojson")
    source(gj, ["110485", "201079"]); short = run(gj)
    source(gj, list(point), bad=("\"-33.5; id\"", "-70.67469")); hostile = run(gj)
    source(gj, list(point), bad=("-33.56136", "-70.6e1")); hostile_lon = run(gj)
    untouched = open(reg, "rb").read() == before
    source(gj, list(point)); full = run(gj)
    after = open(reg, "rb").read()
    again = run(gj) is None and open(reg, "rb").read() == after
    out = list(csv.DictReader(open(reg, encoding="utf-8")))
finally:
    shutil.rmtree(tmp)
old, new = before.split(b"\r\n"), after.split(b"\r\n")
fails = []
if not short or "113314" not in short: fails.append("a source missing 113314 was not refused: " + repr(short))
if not hostile or "113314" not in hostile: fails.append("a latitude that is not plain degrees was not refused: " + repr(hostile))
if not hostile_lon or "113314" not in hostile_lon: fails.append("a longitude that is not plain degrees was not refused: " + repr(hostile_lon))
if not untouched: fails.append("a refused run changed the register")
if full is not None: fails.append("the full source was refused: " + full)
if not out or tuple(out[0]) != deis.COLUMNS + deis.COORDS: fails.append("the header is not the ten columns, then latitud,longitud")
if any((r["latitud"], r["longitud"]) != point[r["codigo"]] for r in out): fails.append("coordinates not written as published")
if len(old) != len(new) or not all(n.startswith(o + b",") for o, n in zip(old, new) if o): fails.append("an original line changed")
if not again: fails.append("a second run did not rewrite the same bytes")
if fails:
    print("\n".join(fails)); sys.exit(1)'
# Every establishment the installer offers carries its official point: the point is where the
# Centro map starts and what SITE_LON/SITE_LAT copy. A --snapshot that skipped --coordenadas is the
# realistic way to get here — snapshot_from writes the ten columns only.
check python3 -c '
import csv, glob, sys
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))
if len(rows) < 100:
    print("register truncated: " + str(len(rows)) + " rows -- this check measured nothing"); sys.exit(1)
bad = [r["codigo"] for r in rows if not all(deis.DEGREES.fullmatch(r.get(k) or "") for k in deis.COORDS)]
if bad:
    print(str(len(bad)) + " register rows without a plain-degree point: " + ", ".join(bad[:5])); sys.exit(1)'
# A --snapshot whose points never came is the newest file, so every reader would take it and
# block() would die on a KeyError inside the installer. load() stops instead, naming both ways
# out, and a refused --coordenadas on it says how to step back to the register before it. On a
# scratch tree: an older register with points, then a fresh ten-column snapshot of the same rows.
check python3 -c '
import csv, glob, os, shutil, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))[:3]
if len(rows) != 3 or not all(r.get("latitud") for r in rows):
    print("no register rows with points to build the scratch tree -- this check measured nothing"); sys.exit(1)
def stop(fn, *a):
    try:
        fn(*a); return None
    except SystemExit as e:
        return str(e)
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE); os.makedirs(os.path.join(tmp, "sites"))
    for name, cols in (("2099-01-01", deis.COLUMNS + deis.COORDS), ("2099-02-01", deis.COLUMNS)):
        with open(os.path.join(tmp, "sites", "establecimientos-deis-" + name + ".csv"), "w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh); w.writerow(cols); w.writerows([r[k] for k in cols] for r in rows)
    loaded = stop(deis.load)
    gj = os.path.join(tmp, "empty.geojson")
    open(gj, "w", encoding="utf-8").write("{\"type\":\"FeatureCollection\",\"features\":[]}")
    refused = stop(deis.coordinates_from, gj)
    os.remove(os.path.join(tmp, "sites", "establecimientos-deis-2099-02-01.csv"))
    back = deis.load()
    os.remove(os.path.join(tmp, "sites", "establecimientos-deis-2099-01-01.csv"))
    with open(os.path.join(tmp, "sites", "establecimientos-deis-2099-03-01.csv"), "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh); w.writerow(deis.COLUMNS); w.writerows([r[k] for k in deis.COLUMNS] for r in rows)
    alone = stop(deis.load)
finally:
    shutil.rmtree(tmp)
fails = []
if not loaded or "--coordenadas" not in loaded or "fall back to establecimientos-deis-2099-01-01.csv" not in loaded:
    fails.append("load() on a snapshot without points did not stop with both ways out: " + repr(loaded))
if not refused or "remove establecimientos-deis-2099-02-01.csv to fall back" not in refused:
    fails.append("a refused --coordenadas on a fresh snapshot did not say how to step back: " + repr(refused))
if back[0] != "2099-01-01" or len(back[1]) != 3:
    fails.append("removing the snapshot did not hand the register back: " + repr(back[0]))
if not alone or "fall back" in alone:
    fails.append("with no register before it, the fix hint must not offer a fallback: " + repr(alone))
if fails:
    print("\n".join(fails)); sys.exit(1)'
# The welcome declaration has a WRITER (deis.py) and a READER (seed.sh's guard + phase 41). This
# proves the writer's output is what the reader expects: written to a scratch tree (write_site
# refuses an existing sites/<name>/), sourced by a real bash, the rows read back — and `equipos`
# absent, because that is the product decision the default carries.
check python3 -c '
import csv, glob, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
row = next(csv.DictReader(open(register, encoding="utf-8")))
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE)
    deis.write_site(row, "gate", "probe", sectors=[], programs=[])
    out = subprocess.run(["bash", "-c", "set -u; . sites/probe/site.sh; printf \"%s\\n\" \"${SITE_WELCOME[@]}\""],
                         cwd=tmp, capture_output=True, text=True)
finally:
    shutil.rmtree(tmp)
if out.returncode != 0:
    print("sourcing the written site file failed: " + out.stderr.strip()[:300]); sys.exit(1)
rows = out.stdout.split()
if rows != ["noticias|wall", "vida-cesfam|", "documentos|wall"]:
    print("SITE_WELCOME default is not the three declared rows: " + repr(rows)); sys.exit(1)'
# The seed's array contract (#195): a PSR or SAPU has no sectors and no programs, and the site file
# the writer emits for it must seed — empty is legal, unset is not. The real seed.sh runs from a
# scratch root with env.sh, lib.sh and the phases stubbed, over write_site's own file, that file
# with SITE_FOLDERS emptied, and that file with each array deleted.
seed_array_contract_cases() {
  local tmp out rc name want
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts" "$tmp/provisioning/phases"
  cp provisioning/seed.sh "$tmp/provisioning/"
  : > "$tmp/scripts/env.sh"
  echo 'require_site() { :; }; require_real_secrets() { :; }; nc_container() { :; }; require_installed() { :; }' \
    > "$tmp/provisioning/lib.sh"
  # shellcheck disable=SC2016  # expanded by the seed, not here
  printf '%s\n' 'echo "teams=${#SITE_TEAMS[@]}"' 'echo "folders=${#SITE_FOLDERS[@]}"' > "$tmp/provisioning/phases/20-probe.sh"
  python3 - "$tmp" <<'PY' >/dev/null || { rm -rf "$tmp"; return 1; }
import csv, glob, os, re, sys
sys.path.insert(0, "scripts")
import deis
tmp = sys.argv[1]
row = next(csv.DictReader(open(sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1], encoding="utf-8")))
deis.HERE = os.path.join(tmp, "scripts")
deis.write_site(row, "gate", "psr", sectors=[], programs=[])
text = open(os.path.join(tmp, "sites", "psr", "site.sh"), encoding="utf-8").read()
def block(name):
    return re.compile(rf"(?ms)^{name}=\(\n.*?^\)\n")
for name, body in (("vacio", block("SITE_FOLDERS").sub("SITE_FOLDERS=()\n", text)),
                   ("sin-SITE_TEAMS", block("SITE_TEAMS").sub("", text)),
                   ("sin-SITE_FOLDERS", block("SITE_FOLDERS").sub("", text))):
    if body == text:
        sys.exit(name + ": the site file did not change — this arm would measure nothing")
    os.makedirs(os.path.join(tmp, "sites", name))
    open(os.path.join(tmp, "sites", name, "site.sh"), "w", encoding="utf-8").write(body)
PY
  for name in psr vacio sin-SITE_TEAMS sin-SITE_FOLDERS; do
    out="$(SITE="$name" bash "$tmp/provisioning/seed.sh" 2>&1)"; rc=$?
    case "$name" in
      psr) want="teams=0" ;;
      vacio) want="folders=0" ;;
      *) want="FATAL: sites/$name/site.sh must set ${name#sin-} (empty is legal, unset is not)" ;;
    esac
    if [ "${name#sin-}" = "$name" ]; then
      [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qxF "$want" \
        || { echo "seed: site $name must seed ($want), got rc=$rc: $out" >&2; rm -rf "$tmp"; return 1; }
    else
      [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -qxF "$want" && ! printf '%s\n' "$out" | grep -q '^teams=' \
        || { echo "seed: site $name must be refused ($want), got rc=$rc: $out" >&2; rm -rf "$tmp"; return 1; }
    fi
  done
  rm -rf "$tmp"
}
check seed_array_contract_cases
# --- gate: sites/ ships the register and NOTHING else ------------------------------------
# The register CSVs are tracked under sites/ beside generated site trees that .gitignore keeps
# out by DIRECTORY — which stops nothing from `git add -f sites/x/site.sh` landing a real site
# record (identity, teams, folders, ACL — a clinic's whole shape) in the public repo. The list
# comes from git ls-files (sites/-PREFIXED paths), piped; the filter is a function so the
# self-test exercises the same bytes. The register is a FLOOR, not an option: an empty listing
# (register deleted, glob renamed) is the empty-glob-goes-green class — red, not green.
sites_register_only() {  # sites/-prefixed file list on stdin; exit 0 = only register CSVs, >=1
  local list n bad
  # Captured ONCE: two greps over one stdin would race — the first consumes the stream and the
  # second reads an exhausted pipe, outputs nothing, and the intruder check goes green vacuously
  # (caught by sanity-running the fence against the real repo, not by review).
  list=$(cat)
  n=$(printf "%s\n" "$list" | grep -cE "^sites/establecimientos-deis-[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv$" || true)
  [ "$n" -ge 1 ] || { printf "no register CSV tracked under sites/ — the register is the floor\n" >&2; return 1; }
  bad=$(printf "%s\n" "$list" | grep -vE "^sites/establecimientos-deis-[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv$" || true)
  [ -z "$bad" ] || { printf "unexpected tracked files under sites/:\n%s\n" "$bad" >&2; return 1; }
}
export -f sites_register_only
check bash -c 'git ls-files sites/ | sites_register_only'
# Negative half, fabricated lists through the same function: a site.sh must be flagged, an
# empty listing must be flagged, the register alone must pass.
check bash -c '
  printf "sites/establecimientos-deis-2026-07-23.csv\nsites/x/site.sh\n" | sites_register_only \
    && { echo "sites gate: a tracked site.sh was not flagged" >&2; exit 1; }
  printf "" | sites_register_only && { echo "sites gate: an empty listing went green" >&2; exit 1; }
  printf "sites/establecimientos-deis-2026-07-23.csv\n" | sites_register_only'
# --- gate: the data manifest and the comuna reference describe each other ---------------------
# packages.json pins the masters; comunas-deis.csv is the coding authority the recipes validate
# against. One python block holds the validator ONCE and runs it on the real corpus AND on three
# fabricated defect corpora (single-sourced: the self-test exercises the same bytes the real check
# runs — slice 4's locked lesson). The row-count expectation is READ FROM THE MANIFEST, not
# restated: a future ODS refresh (a 347th comuna) is one manifest edit + one CSV regen, and this
# gate follows — never three uncoordinated literals.
check python3 -c '
import json, re, sys
def validate(rows, why, expect):
    if len(rows) != expect: print(why + ": " + str(len(rows)) + " rows, expected " + str(expect)); sys.exit(1)
    for cut, glosa in rows:
        if not re.fullmatch(r"[0-9]{5}", cut): print(why + ": CUT " + repr(cut) + " is not 5 digits"); sys.exit(1)
        if "\xa0" in glosa: print(why + ": glosa of " + cut + " carries a non-breaking space"); sys.exit(1)
    if not any(c == "99999" for c, _ in rows): print(why + ": the 99999/Ignorada sentinel row is gone"); sys.exit(1)
m = json.load(open("provisioning/data/packages.json"))
assert m["masters"], "no masters in the data manifest"
for x in m["masters"]:
    for k in ("id", "origin", "sha256", "records"):
        if not x.get(k): print("master " + x.get("id", "?") + ": missing " + k); sys.exit(1)
expect = m["comuna_reference"]["records"]
real = [l.rstrip("\n").split(",", 1) for l in open("provisioning/data/comunas-deis.csv", encoding="utf-8")][1:]
validate(real, "comunas-deis.csv", expect)
# The negative half — three corpora, one defect each, through the SAME validator:
try:
    validate([("1234", "Cuatro"), ("99999", "Ignorada"), ("12345", "Santiago")], "4-digit CUT", expect)
except SystemExit: pass
else: print("fabricated 4-digit corpus passed"); sys.exit(1)
try:
    validate([("99999", "Ignorada"), ("12345", "NBSP\xa0glosa")], "NBSP glosa", 2)
except SystemExit: pass
else: print("fabricated NBSP corpus passed"); sys.exit(1)
try:
    validate([("12345", "Santiago"), ("13101", "Providencia")], "missing sentinel", 2)
except SystemExit: pass
else: print("fabricated sentinel-less corpus passed"); sys.exit(1)
print("ok")'

comuna_archive_extraction_cases() {
  python3 - <<'PY'
import csv, hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile, zipfile
source = pathlib.Path.cwd()
fixtures = source / 'tests/fixtures/comuna'
uv = json.loads((fixtures / 'archive-uv-v1.geojson').read_text())
cut = uv['features'][0]['properties']['t_com'].strip().zfill(5)
with (fixtures / 'establecimientos-deis-v1.csv').open() as stream:
    rows = list(csv.DictReader(stream, delimiter=';'))
expected = [row for row in rows if row['ComunaCodigo'].strip().zfill(5) == cut]
assert len(expected) == 1
with tempfile.TemporaryDirectory(prefix='aps comuna archive ') as directory:
    root = pathlib.Path(directory)
    tools = root / 'bin'
    tools.mkdir()
    for program in ('awk', 'curl', 'dirname', 'find', 'head', 'mkdir', 'mktemp', 'rm', 'sha256sum'):
        (tools / program).symlink_to(shutil.which(program))
    (tools / 'python3').symlink_to(sys.executable)
    converter = tools / 'ogr2ogr'
    converter.write_text('#!' + sys.executable + '\n' + '''
import pathlib, shutil, sys
source, destination = pathlib.Path(sys.argv[-1]), pathlib.Path(sys.argv[-2])
shutil.copyfile(source, destination)
''')
    converter.chmod(0o755)
    for valid in (True, False):
        repo = root / ('valid' if valid else 'invalid')
        for folder in ('scripts', 'provisioning/data', 'inputs', 'work'):
            (repo / folder).mkdir(parents=True, exist_ok=True)
        for name in ('scripts/env.sh', 'scripts/comuna-package.sh', 'provisioning/data/comunas-deis.csv'):
            shutil.copyfile(source / name, repo / name)
        archive_path = repo / 'inputs/unidades-vecinales-v1.zip'
        if valid:
            with zipfile.ZipFile(archive_path, 'w') as archive:
                archive.writestr('nested/source.shp', json.dumps(uv))
        else:
            archive_path.write_bytes(b'invalid archive')
        csv_path = repo / 'inputs/establecimientos-deis-v1.csv'
        shutil.copyfile(fixtures / csv_path.name, csv_path)
        masters = [{'id': key, 'origin': path.as_uri(), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                   for key, path in (('unidades-vecinales-2024', archive_path), ('minsal-deis-establecimientos', csv_path))]
        (repo / 'provisioning/data/packages.json').write_text(json.dumps({'masters': masters}))
        result = subprocess.run(['/bin/bash', 'scripts/comuna-package.sh', cut], cwd=repo,
                                env=dict(os.environ, PATH=str(tools), WORK_DIR=str(repo / 'work')),
                                capture_output=True, text=True, timeout=10)
        assert (result.returncode == 0) == valid, 'Comuna extraction requires an unavailable program or accepted an invalid archive\n' + result.stderr
        if valid:
            package = next((repo / 'work').glob('comuna-package.*'))
            areas = json.loads((package / ('uv-' + cut + '.geojson')).read_text())
            places = json.loads((package / ('deis-establecimientos-' + cut + '.geojson')).read_text())
            assert areas['comuna'] == places['comuna'] == cut
            assert len(areas['features']) == len(places['features']) == 1
            assert areas['features'][0]['properties']['uid'] == uv['features'][0]['properties']['t_id_uv_ca']
            assert areas['features'][0]['properties']['name'] == uv['features'][0]['properties']['t_uv_nom']
            assert places['features'][0]['properties']['uid'] == 'deis:' + expected[0]['EstablecimientoCodigo']
            assert places['features'][0]['properties']['name'] == expected[0]['EstablecimientoGlosa']
PY
}
check comuna_archive_extraction_cases

comuna_master_origins_versioned() {
  python3 - <<'PY'
import json, pathlib, re, subprocess, urllib.parse
def versioned(origin):
    url = urllib.parse.urlsplit(origin)
    if url.scheme not in ('https', 'file') or url.query:
        return False
    if url.hostname == 'datos.gob.cl' and re.search(r'/resource/[^/]+/download(?:/|$)', url.path):
        return False
    if url.hostname == 'raw.githubusercontent.com':
        parts = url.path.strip('/').split('/')
        if len(parts) < 4 or not re.fullmatch('[0-9a-f]{40}', parts[2]):
            return False
    name = pathlib.PurePosixPath(url.path).name
    return bool(re.search(r'(?:^|[-_])(?:20\d{2}(?:[-_]\d{2}[-_]\d{2}|\d{4})?|v\d+(?:\.\d+)*)\.(?:csv|zip)$', name))
assert versioned('file:///fixture/unidades-vecinales-v1.zip')
assert versioned('https://example.test/masters/establecimientos_20260908.csv')
assert not versioned('https://datos.gob.cl/dataset/source/resource/resource-id/download/establecimientos_20260908.csv')
assert not versioned('https://raw.githubusercontent.com/APS-Conecta/gestion/main/masters/establecimientos-deis-2026-11-01.csv')
manifest = json.loads(pathlib.Path('provisioning/data/packages.json').read_text())
for master in manifest['masters']:
    assert versioned(master['origin']), master['id'] + ': master origin is not a versioned asset'
assert 'geoportal-dpa-comunas-2023' not in {m['id'] for m in manifest['masters']}, 'An unused master remains'
assert 'recipes' not in manifest, 'Recipe prose duplicates the packaging command'
payload = b'original\r\nsource\r\n'
def object_hash(*options):
    return subprocess.run(['git', 'hash-object', '--stdin', *options], input=payload,
                          capture_output=True, check=True).stdout
assert object_hash('--path=provisioning/data/masters/establecimientos-deis-2026-11-01.csv') == object_hash('--no-filters'), 'Git changes literal source bytes'
PY
}
check comuna_master_origins_versioned

# --- gate: a21 (L5): the map is the suite's own route — the separate tiles server is gone -------------
# The grep is a21's own clause, with the pattern assembled without its literals
# ("nginx:alp""ine|TILES_""PORT|:80""84"): a21 covers scripts/ too, and a gate that spelled its
# own banned tokens would be its own hit. tiles.nginx.conf gone, no nginx pin, port or knob left
# anywhere the map used to need one. (Phase 16 no longer points territorio at /tiles/ — its own
# case above asserts the absence.)
check bash -c '
  test ! -e tiles.nginx.conf \
    && ! git grep -qE "nginx:alp""ine|TILES_""PORT|:80""84" -- .env.example host scripts provisioning'

# --- gate: the tile machinery is retired (territorio draws OpenStreetMap's tile service, territorio ADR-0021) -----
# The map-folder default used to be spelled in six places that had to agree (org review L5-S3, I7);
# with the folder gone there is nothing to agree on, and the proof is the absence: the build, the
# refresh, the timer's two units and the host CLI's map step do not exist, and no knob that fed them
# survives. The tokens are assembled without their literals so this file is not its own hit. The ONE
# place the old folder is still named is the host CLI's retirement of a host that ran the earlier
# bundle (retire_tile_remnants, TILES_REMNANT_DIR) — a different name on purpose, so this grep can stay
# absolute. APS_TILES_""DIR itself survives in patch 239's brand-gate row (its own change) and in the
# host self-test's legacy-environment arm, so it is checked only where it would still do work: the
# run string and the testbed.
check bash -c '
  for f in host/tiles.sh scripts/refresh-""basemap.sh host/aps-conecta-tiles.service host/aps-conecta-tiles.timer; do
    [ ! -e "$f" ] || { echo "$f is back — the tile machinery is retired" >&2; exit 1; }
  done
  hits="$(git grep -nE "APS_SKIP_""MAP|TILES_""HOME|TILES_""ARCHIVE|suite_tiles_""dir|refresh-""basemap" -- host scripts provisioning .github || true)"
  [ -z "$hits" ] || { printf "tile-machinery knobs survive:\n%s\n" "$hits" >&2; exit 1; }
  hits="$(git grep -nE "APS_TILES_""DIR" -- scripts/aio-testbed.sh scripts/env.sh .github || true)"
  [ -z "$hits" ] || { printf "the map folder is still handed to the mastercontainer:\n%s\n" "$hits" >&2; exit 1; }
  out="$(APS_SUITE_TAG=v0.0.0 bash host/aps-conecta run-command 2>&1)"
  case "$out" in "docker run"*) ;; *) echo "run-command printed no docker run string: $out" >&2; exit 1 ;; esac
  ! grep -q "APS_TILES_""DIR" <<<"$out"'

# --- gate (#178): AppAPI runs through HaRP only — the board app and the deprecated socket proxy are gone ---
# #175 removes both from the suite with no tombstone, so the proof is the absence, tree-wide: no image
# directory, no container definition (the release list is parsed from it), no wizard setting or checkbox,
# no entrypoint block, no doc line. The pattern is assembled without its literals so this file is not
# its own hit.
check bash -c '
  re="white""board|piza""rra|docker.?socket""[._ -]?proxy"
  hits="$(git ls-files | grep -iE "$re"; git grep -nIiE "$re")"
  [ -z "$hits" ] || { printf "still in the tree:\n%s\n" "$hits" >&2; exit 1; }'

# --- gate (#180): the suite carries no document-search footprint ------------------------------------
# No tracked file names the document-search app, its two database roles or the database extension
# it needed. BUGS.md's rows are frozen records and keep their bytes. The tokens are assembled
# without their literals so this file is not its own hit.
check bash -c '
  hits="$(git grep -nIiE "busc""ador|bd_(own""er|work""er)|pgvec""tor|vec""tor extension|extension (if not exists )?vec""tor" -- . \
          | grep -v "^BUGS\.md:[0-9]*:| A-[0-9]* |" || true)"
  [ -z "$hits" ] || { printf "document-search footprint survives:\n%s\n" "$hits" >&2; exit 1; }'

# Clean boot resolves its suite tag once, in the «suite-tag» job: the dispatch's suite-tag input, else
# scripts/aio-testbed.sh's one pin, judged by one regex before docker sees it — the rehearsal's ci-YYYYMMDD-N,
# a release vX.Y.Z, or the pipeline's rehearsal vX.Y.Z-ci.N — then looked up on ghcr.io. The step is extracted
# from the workflow and run here over a fixture testbed and a stubbed docker: each accepted form reaches
# GITHUB_OUTPUT after one manifest lookup of its own tag; no pin, two pins, a floating tag or a smuggled shell
# word are refused with no docker call; a tag ghcr.io does not have fails, and the FATAL names it.
cleanboot_suite_tag_cases() {
  local script tmp got calls kind val want input
  script="$(awk '/- name: The suite tag both jobs install/ {f=1; next}
                 f && /run: \|/ {r=1; next}
                 r && /^          / {sub(/^          /, ""); print; next}
                 r {exit}' .github/workflows/cleanboot.yml)"
  [ -n "$script" ] || { echo "cleanboot: the suite-tag step was not found" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir "$tmp/scripts"
  pin() { printf 'IMAGE="${AIO_TEST_IMAGE:-ghcr.io/aps-conecta/all-in-one:%s}"\n' "$1"; }
  while IFS='|' read -r kind val want input; do
    case "$kind" in
      one)  pin "$val" > "$tmp/scripts/aio-testbed.sh" ;;
      two)  { pin "$val"; pin ci-20261004-2; } > "$tmp/scripts/aio-testbed.sh" ;;
      none) printf 'IMAGE="${AIO_TEST_IMAGE:-nginx}"\n' > "$tmp/scripts/aio-testbed.sh" ;;
    esac
    : > "$tmp/out"; : > "$tmp/calls"
    ( cd "$tmp" && GITHUB_OUTPUT="$tmp/out" DISPATCH_TAG="$input" bash -e -c '
        docker() { printf "%s\n" "$*" >> calls
          case "$*" in *:v0.0.0-ci.99) echo "manifest unknown" >&2; return 1 ;; esac; }
        eval "$1"' _ "$script" ) >/dev/null 2>"$tmp/err"
    got="$(sed -n 's/^tag=//p' "$tmp/out")"; calls="$(cat "$tmp/calls")"
    case "$want" in
      fail)   [ -z "$got" ] && [ -z "$calls" ] \
                || { echo "cleanboot: $kind '$val' input '$input' should be refused before docker, got '$got', docker: $calls" >&2; rm -rf "$tmp"; return 1; } ;;
      absent) [ -z "$got" ] && grep -q "FATAL.*$input" "$tmp/err" \
                || { echo "cleanboot: input '$input' is not on ghcr.io — expected a FATAL naming it, got '$got'" >&2; rm -rf "$tmp"; return 1; } ;;
      *)      [ "$got" = "$want" ] && [ "$calls" = "manifest inspect ghcr.io/aps-conecta/all-in-one:$want" ] \
                || { echo "cleanboot: $kind '$val' input '$input' expected '$want', got '$got', docker: $calls" >&2; rm -rf "$tmp"; return 1; } ;;
    esac
  done <<'CASES'
one|ci-20261004-2|ci-20261004-2
one|v0.4.0|v0.4.0
one|v10.20.30|v10.20.30
one|v0.0.0-ci.6|v0.0.0-ci.6
one|v0.5.0-ci.12|v0.5.0-ci.12
two|v0.4.0|fail
none|x|fail
one|latest|fail
one|v0.4|fail
one|v0.4.0-|fail
one|ci-2026-1|fail
one|v0.4.0;touch x|fail
one|v0.4.0|v0.0.0-ci.8|v0.0.0-ci.8
none|x|v0.0.0-ci.8|v0.0.0-ci.8
one|v0.4.0|fail|latest
one|v0.4.0|fail|v0.4.0;touch x
one|v0.4.0|absent|v0.0.0-ci.99
CASES
  rm -rf "$tmp"
}
check cleanboot_suite_tag_cases

# Clean boot (by IP) asserts Territorio carries the site's comuna and NO tile_url. The step is a YAML block
# no runner has run until CI does, so its script is extracted and run here over a stubbed occ: absent (occ
# exits 1, as for a key that was never set) and stored-empty (exit 0, no value) both pass; a stored value, a
# wrong comuna_cut and a missing comuna_name each fail.
cleanboot_tile_url_cases() {
  local script tmp rc
  script="$(awk '/- name: Territorio carries the site.s comuna and no tile_url/ {f=1; next}
                 f && /run: \|/ {r=1; next}
                 r && /^          / {sub(/^          /, ""); print; next}
                 r {exit}' .github/workflows/cleanboot.yml | grep -v 'source scripts/env.sh')"
  [ -n "$script" ] || { echo "cleanboot: the comuna / tile_url step was not found" >&2; return 1; }
  tmp="$(mktemp -d)"; printf 'SITE_COMUNA="Comuna Prueba"\nSITE_COMUNA_CUT=09999\n' > "$tmp/site.sh"
  while IFS='|' read -r tile cut name want; do
    ( cd "$tmp" && RUNNER_TEMP="$tmp" TILE="$tile" CUT="$cut" NAME="$name" bash -e -o pipefail -c '
        occ() { [ "$1 $2" = "config:app:get territorio" ] || return 2
          case "$3" in
            comuna_cut) printf "%s\n" "$CUT" ;;
            comuna_name) printf "%s\n" "$NAME" ;;
            tile_url) case "$TILE" in absent) return 1 ;; empty) return 0 ;; *) printf "%s\n" "$TILE" ;; esac ;;
          esac; }
        eval "$1"' _ "$script" ) >/dev/null 2>&1
    rc=$?
    case "$want" in pass) [ "$rc" -eq 0 ] ;; fail) [ "$rc" -ne 0 ] ;; esac \
      || { echo "cleanboot: tile_url=$tile cut=$cut name=$name expected $want, got rc=$rc" >&2; rm -rf "$tmp"; return 1; }
  done <<'CASES'
absent|09999|Comuna Prueba|pass
empty|09999|Comuna Prueba|pass
https://x/tiles/chile.pmtiles|09999|Comuna Prueba|fail
absent|01234|Comuna Prueba|fail
absent|09999||fail
CASES
  rm -rf "$tmp"
}
check cleanboot_tile_url_cases

# Clean boot's usage collector over a stub df that prints GNU's real header
# (8 words for 7 columns), a source seen twice and a mount point with a space: the record is
# written, one row per source, each named by the columns asked for. Host counters use explicit
# fixtures so the sample cannot substitute the runner's nominal size or silently omit pressure.
cleanboot_usage_cases() {
  local py tmp rc task_usage_error
  py="$(cat scripts/usage.py)"
  [ -n "$py" ] || { echo "cleanboot: the usage collector was not found" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir "$tmp/bin"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/docker"
  printf '#!/bin/sh\nprintf "%%s\\n" "Filesystem Type 1B-blocks Used Avail Use%% Mounted on" "/dev/sda1 ext4 100 40 60 40%% /" "/dev/sda1 ext4 100 40 60 40%% /var/lib/docker" "/dev/sdb1 ext4 100 10 90 10%% /mnt/with space"\n' > "$tmp/bin/df"
  chmod +x "$tmp/bin/docker" "$tmp/bin/df"
  printf '%s\n' "$py" > "$tmp/usage.py"
  PATH="$tmp/bin:$PATH" python3 - "$tmp/uso.json" "$tmp/usage.py" <<'PY' > "$tmp/result" 2>&1
import builtins, io, json, os, pathlib, sys
from unittest.mock import patch

source = pathlib.Path(sys.argv[2]).read_text()
real_open = builtins.open
fixtures = {
    '/proc/meminfo': 'MemTotal: 12582912 kB\nMemAvailable: 3145728 kB\nSwapTotal: 2097152 kB\nSwapFree: 1048576 kB\n',
    '/proc/stat': 'cpu 100 2 30 400 5 6 7 8 9 10\n',
    '/proc/vmstat': 'pswpin 11\npswpout 12\noom_kill 2\n',
    '/proc/sys/kernel/random/boot_id': '00000000-0000-0000-0000-000000000001\n',
}
def fixture_open(path, *args, **kwargs):
    return io.StringIO(fixtures[str(path)]) if str(path) in fixtures else real_open(path, *args, **kwargs)

with patch('builtins.open', fixture_open), patch('os.cpu_count', return_value=6), \
        patch('os.sched_getaffinity', return_value={1, 3, 5}), \
        patch('os.sysconf', side_effect={'SC_PAGE_SIZE': 4096, 'SC_CLK_TCK': 100}.__getitem__):
    namespace = {'__name__': 'usage_fixture'}
    exec(compile(source, 'scripts/usage.py', 'exec'), namespace)
    assert namespace['main']([sys.argv[1]]) == 0
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert record['host'] == {
    'memory_total_kib': 12582912, 'memory_available_kib': 3145728,
    'swap_total_kib': 2097152, 'swap_free_kib': 1048576,
    'logical_cpus': 6, 'available_cpus': 3,
    'page_size_bytes': 4096, 'clock_ticks_per_second': 100,
    'boot_id': '00000000-0000-0000-0000-000000000001',
    'cpu_ticks': [100, 2, 30, 400, 5, 6, 7, 8, 9, 10],
    'vm_counters': {'pswpin': 11, 'pswpout': 12, 'oom_kill': 2},
}, record
assert record['sampled_at'].endswith('+00:00'), record
root = pathlib.Path(sys.argv[1]).parent
race, pid_file = root / 'completion-race.jsonl', root / 'completion-race.pid'
race.write_text((json.dumps(record) + '\n') * 2)
pid_file.write_text('4242')
def finish_before_cmdline(path):
    assert str(path) == '/proc/4242/cmdline'
    with race.open('a') as stream:
        stream.write(json.dumps({'event': 'complete', 'samples': 2, 'sampler_pid': 4242}) + '\n')
    return b''
with patch('pathlib.Path.read_bytes', finish_before_cmdline), patch('os.kill') as kill:
    namespace['stop'](race, pid_file)
    kill.assert_not_called()
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then cat "$tmp/result" >&2; rm -rf "$tmp"; return 1; fi
  python3 -c '
import json, sys
disco = json.load(open(sys.argv[1], encoding="utf-8"))["disco"]
assert len(disco) == 2 and all("source" in d and "target" in d for d in disco), disco
assert disco[1]["target"] == "/mnt/with space", disco' "$tmp/uso.json" >/dev/null 2>&1 && [ "$rc" -eq 0 ] \
    || { echo "cleanboot: the usage record was not written as one row per source (rc=$rc)" >&2; rm -rf "$tmp"; return 1; }
  PATH="$tmp/bin:$PATH" python3 - "$tmp/series.jsonl" --interval 0.05 --duration 0.5 <<<"$py" > "$tmp/result" 2>&1; rc=$?
  python3 - "$tmp/series.jsonl" <<'PY' >> "$tmp/result" 2>&1
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) >= 3 and rows[-1]['event'] == 'complete' and rows[-1]['reason'] == 'duration', rows
assert rows[-1]['samples'] == len(rows) - 1, rows
assert all('host' in row and 'sampled_at' in row for row in rows[:-1]), rows
PY
  if [ "$?" -ne 0 ] || [ "$rc" -ne 0 ]; then cat "$tmp/result" >&2; rm -rf "$tmp"; return 1; fi
  PATH="$tmp/bin:$PATH" python3 - "$tmp" <<'PY' > "$tmp/result" 2>&1
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
output, pid_file = root / 'stopped.jsonl', root / 'sampler.pid'
command = [sys.executable, 'scripts/usage.py', str(output)]
process = subprocess.Popen(command + ['--interval', '0.05', '--duration', '30'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
try:
    pid_file.write_text(str(process.pid))
    deadline = time.monotonic() + 10
    while True:
        try:
            if len(output.read_text().splitlines()) >= 2:
                break
        except FileNotFoundError:
            pass
        assert process.poll() is None and time.monotonic() < deadline, 'sampler did not produce two records'
        time.sleep(0.05)
    result = subprocess.run(command + ['--stop', str(pid_file)], capture_output=True, text=True, timeout=25)
    assert result.returncode == 0, result.stderr
    assert process.wait(timeout=5) == 0, process.stderr.read()
    rows = [json.loads(line) for line in output.read_text().splitlines()]
    assert rows[-1]['event'] == 'complete' and rows[-1]['reason'] == 'stopped', rows
    assert rows[-1]['samples'] == len(rows) - 1 >= 2, rows
    process.stderr.close()
    output = root / 'duration-complete.jsonl'
    command = [sys.executable, 'scripts/usage.py', str(output)]
    process = subprocess.Popen(command + ['--interval', '0.05', '--duration', '0.5'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    pid_file.write_text(str(process.pid))
    deadline = time.monotonic() + 10
    while True:
        try:
            rows = [json.loads(line) for line in output.read_text().splitlines()]
            if rows and rows[-1].get('event') == 'complete':
                break
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        assert time.monotonic() < deadline, 'sampler did not reach its duration'
        time.sleep(0.05)
    time.sleep(0.05)
    result = subprocess.run(command + ['--stop', str(pid_file)], capture_output=True, text=True, timeout=25)
    assert result.returncode == 0, result.stderr
    assert process.wait(timeout=5) == 0, process.stderr.read()
    pid_file.write_text(str(os.getpid()))
    result = subprocess.run(command + ['--stop', str(pid_file)], capture_output=True, text=True, timeout=5)
    assert result.returncode == 1, 'an unrelated PID accepted another collector\'s complete series'
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    process.stderr.close()
PY
  if [ "$?" -ne 0 ]; then cat "$tmp/result" >&2; rm -rf "$tmp"; return 1; fi
  for task_usage_error in unavailable disappeared; do
    case "$task_usage_error" in
      unavailable) printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/docker" ;;
      disappeared) printf '#!/bin/sh\ncase "$1" in ps) echo aps-conecta-nextcloud;; esac\n' > "$tmp/bin/docker" ;;
    esac
    PATH="$tmp/bin:$PATH" python3 scripts/usage.py "$tmp/$task_usage_error.json" > "$tmp/result" 2>&1; rc=$?
    python3 - "$tmp/$task_usage_error.json" <<'PY' >> "$tmp/result" 2>&1
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert record['containers_status'] == 'unavailable' and record['contenedores'] is None, record
assert record['host']['memory_total_kib'] > 0, record
PY
    if [ "$?" -ne 0 ] || [ "$rc" -ne 0 ]; then cat "$tmp/result" >&2; rm -rf "$tmp"; return 1; fi
  done
  rm -rf "$tmp"
}
check cleanboot_usage_cases

# Clean boot's package installs are bounded (#85): both jobs install through scripts/cleanboot-apt.sh and
# cleanboot.yml calls apt-get nowhere else. The script runs over PATH stubs — sudo passes through, timeout
# records its limit and runs the real one at 1s, apt-get stalls on the case's step or, on an unreachable
# mirror, answers as the runner's apt did on the forced stall (update warns and exits 0 unless run with
# --error-on=any; install then finds no package) — and a fixture /etc: a failure ends within seconds, its
# FAIL line naming the step and its stderr the mirrors (the list behind a mirror+file: URI included); a
# healthy run passes; every apt-get call ran under a limit of a few minutes.
cleanboot_apt_cases() {
  local tmp stall want rc start
  [ "$(grep -c '^          bash scripts/cleanboot-apt.sh signify-openbsd$' .github/workflows/cleanboot.yml)" -eq 2 ] \
    && ! grep -q 'apt-get' .github/workflows/cleanboot.yml \
    || { echo "cleanboot: both jobs must install through scripts/cleanboot-apt.sh, and nothing else call apt-get" >&2; return 1; }
  tmp="$(mktemp -d)"; mkdir -p "$tmp/bin" "$tmp/etc/apt/sources.list.d"
  printf 'Types: deb\nURIs: mirror+file:%s/mirrors.txt\nSuites: noble\n\nTypes: deb\nURIs: http://10.255.255.1/ubuntu/\nSuites: noble-security\n' \
    "$tmp" > "$tmp/etc/apt/sources.list.d/ubuntu.sources"
  printf 'http://azure.invalid/ubuntu/\tpriority:1\n' > "$tmp/mirrors.txt"
  printf '#!/bin/sh\nexec "$@"\n' > "$tmp/bin/sudo"
  printf '#!/bin/sh\necho "$1" >> %s/limits; shift\nAPT_BOUNDED=1 exec %s 1 "$@"\n' "$tmp" "$(command -v timeout)" > "$tmp/bin/timeout"
  printf '#!/bin/sh\n[ -n "${APT_BOUNDED:-}" ] || echo unbounded >> %s/limits\n[ "$1" = "$STALL" ] && exec sleep 30\n[ "$STALL" = unreachable ] || exit 0\ncase "$*" in update*--error-on=any*) exit 100 ;; update*) exit 0 ;; *) exit 100 ;; esac\n' "$tmp" > "$tmp/bin/apt-get"
  chmod +x "$tmp/bin/"*
  while IFS='|' read -r stall want; do
    : > "$tmp/limits"; start=$SECONDS
    PATH="$tmp/bin:$PATH" ETC_DIR="$tmp/etc" STALL="$stall" bash scripts/cleanboot-apt.sh signify-openbsd >/dev/null 2>"$tmp/err"
    rc=$?
    case "$want" in
      pass) [ "$rc" -eq 0 ] && [ "$(wc -l < "$tmp/limits")" -eq 2 ] ;;
      *) [ "$rc" -ne 0 ] && [ $((SECONDS - start)) -lt 10 ] && grep -q "^FAIL: apt-get $want " "$tmp/err" \
              && grep -q 'http://10.255.255.1/ubuntu/' "$tmp/err" && grep -q 'http://azure.invalid/ubuntu/' "$tmp/err" ;;
    esac && ! grep -vxE '[0-9]+' "$tmp/limits" && [ "$(sort -n "$tmp/limits" | tail -1)" -le 300 ] \
      || { echo "cleanboot: apt stall=$stall expected $want, got rc=$rc, limits: $(paste -sd' ' "$tmp/limits"), stderr: $(cat "$tmp/err")" >&2; rm -rf "$tmp"; return 1; }
  done <<'CASES'
none|pass
update|update
install|install
unreachable|update
CASES
  rm -rf "$tmp"
}
check cleanboot_apt_cases


# --- office-smoke's DS pin: the running DocumentServer is the one the Dockerfile pins (#140) -------
# The real office-smoke (and the env.sh it sources) runs from a fixture tree whose
# Containers/eurooffice/Dockerfile is the real one with a synthetic pin, v1.2.3: a hard-coded
# version reds, and so does a FROM line whose shape the parse no longer reads. A stub docker
# answers apache's public HTTPS posture, the connector enabled and --check with $DS_VERSION; a stub
# curl answers the healthcheck. Both the public smoke and the real container probe must
# require a successful response containing true, even when nginx's port is open.
office_pin_cases() {
  local tmp out rc tag ver want health_body health_status probe signature_rc integrity_rc
  tmp="$(mktemp -d)"; mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/Containers/eurooffice"
  cp scripts/office-smoke.sh scripts/env.sh "$tmp/scripts/"
  cp Containers/eurooffice/healthcheck.sh "$tmp/Containers/eurooffice/"
  cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ps -q"*) echo ds0 ;;
  ps*) echo aps-conecta-nextcloud ;;
  inspect*aps-conecta-apache*) printf 'APACHE_PORT=443\nNC_DOMAIN=clinica.example\n' ;;
  "inspect ds0"*) echo ghcr.io/aps-conecta/aio-eurooffice:v0.0.0-ci.0 ;;
  *"config:app:get eurooffice enabled"*) echo yes ;;
  *"test -s /var/www/html/custom_apps/eurooffice/appinfo/signature.json"*) exit "${OFFICE_SIGNATURE_RC:-0}" ;;
  *"integrity:check-app eurooffice"*) exit "${OFFICE_INTEGRITY_RC:-0}" ;;
  *"eurooffice:documentserver --check"*) echo "Document server http://x/ version $DS_VERSION is successfully connected" ;;
esac
exit 0
STUB
  cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${OFFICE_HEALTH_BODY-true}"
exit "${OFFICE_HEALTH_RC:-0}"
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/nc"
  chmod +x "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/nc"
  while IFS='|' read -r tag ver want; do
    printf 'FROM ghcr.io/euro-office/documentserver:v%s\n' "$tag" > "$tmp/Containers/eurooffice/Dockerfile"
    rc=0; out="$(PATH="$tmp/bin:$PATH" DS_VERSION="$ver" bash "$tmp/scripts/office-smoke.sh" 2>&1)" || rc=1
    [ "$rc" = "$want" ] \
      || { echo "office pin: DS $ver against the pin $tag exited $rc, want $want: $out" >&2; rm -rf "$tmp"; return 1; }
  done <<'CASES'
1.2.3|1.2.3.37|0
1.2.3|1.2.3|0
1.2.3|1.2.30.1|1
1.2.3|9.3.1.37|1
1.2.3-1|1.2.3.37|0
1.2.3-1|1.2.3|0
1.2.3-1|1.2.30.1|1
1.2.3-rc.1|1.2.3.37|1
CASES
  printf 'FROM ghcr.io/euro-office/documentserver:v1.2.3\n' > "$tmp/Containers/eurooffice/Dockerfile"
  while IFS='|' read -r health_body health_status want; do
    for probe in scripts/office-smoke.sh Containers/eurooffice/healthcheck.sh; do
      rc=0; out="$(PATH="$tmp/bin:$PATH" DS_VERSION=1.2.3.37 AIO_LOG_LEVEL=info \
        OFFICE_HEALTH_BODY="$health_body" OFFICE_HEALTH_RC="$health_status" bash "$tmp/$probe" 2>&1)" || rc=1
      [ "$rc" = "$want" ] \
        || { echo "office health: $probe body '$health_body' curl exit $health_status gave $rc, want $want: $out" >&2; rm -rf "$tmp"; return 1; }
    done
  done <<'CASES'
true|0|0
false|0|1
|0|1
not-ready|0|1
true|22|1
true|28|1
CASES
  while IFS='|' read -r signature_rc integrity_rc want; do
    rc=0; out="$(PATH="$tmp/bin:$PATH" DS_VERSION=1.2.3.37 \
      OFFICE_SIGNATURE_RC="$signature_rc" OFFICE_INTEGRITY_RC="$integrity_rc" \
      bash "$tmp/scripts/office-smoke.sh" 2>&1)" || rc=1
    [ "$rc" = "$want" ] \
      || { echo "office provenance: signature exit $signature_rc, integrity exit $integrity_rc gave $rc, want $want: $out" >&2; rm -rf "$tmp"; return 1; }
  done <<'CASES'
0|0|0
1|0|1
0|1|1
CASES
  rm "$tmp/Containers/eurooffice/Dockerfile"
  rc=0; out="$(PATH="$tmp/bin:$PATH" DS_VERSION=1.2.3.37 bash "$tmp/scripts/office-smoke.sh" 2>&1)" || rc=1
  rm -rf "$tmp"
  [ "$rc" = 1 ] && case "$out" in *"could not read the document server pin"*) ;; *) false ;; esac \
    || { echo "office pin: no Dockerfile must fail closed naming the pin, got exit $rc: $out" >&2; return 1; }
}
check office_pin_cases

# A dependency timeout cannot remove an installed feature or its Office navigation.
entrypoint_timeout_cases() {
  python3 - <<'PY'
import pathlib, re, sys
apps = ('office', 'eurooffice', 'files_antivirus', 'fulltextsearch',
        'fulltextsearch_elasticsearch', 'files_fulltextsearch')
pattern = re.compile(
    r'^\s*(?:php\s+/var/www/html/occ|startup_occ)\s+app:disable\s+["\']?('
    + '|'.join(apps) + r')(?=["\'\s]|$)', re.M)
for app in apps:
    assert pattern.search('php /var/www/html/occ app:disable ' + app)
text = '\n'.join(path.read_text() for path in pathlib.Path('Containers/nextcloud').glob('*.sh'))
matches = pattern.findall(text)
if matches:
    print('entrypoint timeouts disable configured apps: ' + ', '.join(matches))
    sys.exit(1)
PY
}
check entrypoint_timeout_cases

entrypoint_wait_cases() {
  python3 - <<'PY'
import os, pathlib, re, subprocess, tempfile
entrypoint = pathlib.Path('Containers/nextcloud/entrypoint.sh').read_text()
for condition in re.findall(r'^\s*(?:while|until)\s+([^\n]+)', entrypoint, re.M):
    assert re.search(r'\[ "\$(?:SECONDS|try)" -lt "\$(?:[a-z_]+_deadline|max_retries)" \]', condition), \
        'Nextcloud wait has no finite condition: ' + condition
module = pathlib.Path('Containers/nextcloud/configure-apps.sh').resolve()
result = subprocess.run(['bash', '-c', '''
source "$1"
nc() { return 1; }
sleep() { SECONDS=$((SECONDS + $1)); }
startup_wait unavailable.invalid 1234 'Talk Recording'
''', 'wait-fixture', str(module)], capture_output=True, text=True, timeout=5)
assert result.returncode == 2 and 'configuration deferred' in result.stdout
block = entrypoint.split('# Check connection to appstore start', 1)[1].split('# Check connection to appstore end', 1)[0]
block = block.split('\n', 1)[1]
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    wrapper = root / 'wait.sh'
    wrapper.write_text('''#!/bin/bash
grep() { return 1; }
sleep() { SECONDS=$((SECONDS + $1)); }
curl() { printf '%s\\n' "$*" >> "$CASE_CALLS"; printf '%s' "$CASE_STATUS"; }
''' + block + '\nprintf "continued\\n"\n')
    for status in ('200', '503'):
        calls = root / ('calls-' + status)
        result = subprocess.run(['bash', str(wrapper)], capture_output=True, text=True, timeout=5,
                                env=dict(os.environ, CASE_STATUS=status, CASE_CALLS=str(calls)))
        assert (result.returncode == 0) == (status == '200'), result.stderr
        assert ('continued' in result.stdout) == (status == '200')
        requests = calls.read_text().splitlines()
        assert requests and all('--connect-timeout 5' in line and '--max-time ' in line for line in requests)
        assert len(requests) <= 18, 'The app-store wait exceeded its existing 90-second budget'
PY
}
check entrypoint_wait_cases

recording_trust_cases() {
  python3 - <<'PY'
import json, pathlib, shutil, subprocess, tempfile
containers = json.loads(pathlib.Path('php/containers.json').read_text())['aio_services_v1']
recorder = next(row for row in containers if row['container_name'] == 'aps-conecta-talk-recording')
assert any(row['source'] == '%NEXTCLOUD_TRUSTED_CACERTS_DIR%'
           and row['destination'] == '/usr/local/share/ca-certificates'
           and row['writeable'] is False for row in recorder['volumes']), 'Recording must receive the suite CA read-only'
helper = pathlib.Path('Containers/talk-recording/prepare-trust.py')
assert helper.is_file(), 'Recording must prepare verified Python and Firefox trust before starting'
with tempfile.TemporaryDirectory(prefix='aps recording ') as directory:
    root = pathlib.Path(directory)
    certificates = root / 'certificates'
    certificates.mkdir()
    output = root / 'output'
    output.mkdir()
    def openssl(*args, success=True):
        result = subprocess.run(['openssl', *map(str, args)], capture_output=True)
        assert (result.returncode == 0) == success, result.stderr.decode()
    for name in ('system', 'suite', 'unknown'):
        openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                '-nodes', '-days', '1', '-subj', '/CN=' + name,
                '-keyout', root / (name + '.key'), '-out', root / (name + '.crt'))
    shutil.copyfile(root / 'suite.crt', certificates / 'suite.crt')
    openssl('req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
            '-nodes', '-subj', '/CN=127.0.0.1', '-keyout', root / 'leaf.key', '-out', root / 'leaf.csr')
    (root / 'extensions').write_text('subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
    for name in ('suite', 'unknown'):
        openssl('x509', '-req', '-days', '1', '-in', root / 'leaf.csr', '-set_serial', '1',
                '-CA', root / (name + '.crt'), '-CAkey', root / (name + '.key'),
                '-extfile', root / 'extensions', '-out', root / (name + '-leaf.crt'))
    def prepare(success=True):
        result = subprocess.run(['python3', str(helper), str(root / 'system.crt'),
                                 str(certificates), str(output)], capture_output=True, text=True, timeout=5)
        assert (result.returncode == 0) == success, result.stderr
    prepare()
    bundle = output / 'ca-certificates.crt'
    openssl('verify', '-CAfile', bundle, root / 'system.crt')
    openssl('verify', '-purpose', 'sslserver', '-verify_ip', '127.0.0.1', '-CAfile', bundle,
            root / 'suite-leaf.crt')
    openssl('verify', '-purpose', 'sslserver', '-verify_ip', '127.0.0.2', '-CAfile', bundle,
            root / 'suite-leaf.crt', success=False)
    openssl('verify', '-CAfile', bundle, root / 'unknown-leaf.crt', success=False)
    policies = json.loads((output / 'firefox-policies.json').read_text())
    assert policies == {'policies': {'Certificates': {'Install': [str(certificates / 'suite.crt')]}}}
    shutil.copyfile(root / 'unknown.crt', certificates / 'suite.crt')
    prepare()
    openssl('verify', '-CAfile', bundle, root / 'suite-leaf.crt', success=False)
    openssl('verify', '-CAfile', bundle, root / 'unknown-leaf.crt')
    (certificates / 'suite.crt').write_text('invalid certificate')
    prepare(success=False)
    (certificates / 'suite.crt').unlink()
    prepare()
    openssl('verify', '-CAfile', bundle, root / 'system.crt')
    assert json.loads((output / 'firefox-policies.json').read_text()) == {'policies': {'Certificates': {'Install': []}}}
    (root / 'system.crt').unlink()
    prepare(success=False)
PY
}
check recording_trust_cases

harp_trust_cases() {
  python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
entrypoint = pathlib.Path('Containers/harp/start.sh')
assert entrypoint.is_file(), 'HaRP must adapt the suite CA before starting its upstream agent'
with tempfile.TemporaryDirectory(prefix='aps harp ') as directory:
    root = pathlib.Path(directory)
    certificates = root / 'certificates'
    certificates.mkdir()
    def openssl(*args, success=True):
        result = subprocess.run(['openssl', *map(str, args)], capture_output=True)
        assert (result.returncode == 0) == success, f'Certificate command {args}: {result.stderr.decode()}'
    for name in ('system', 'suite', 'unknown'):
        openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=' + name, '-keyout', root / (name + '.key'),
                '-out', root / (name + '.crt'))
    shutil.copyfile(root / 'suite.crt', certificates / 'suite.crt')
    openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=127.0.0.1',
            '-keyout', root / 'leaf.key', '-out', root / 'leaf.csr')
    (root / 'extensions').write_text('subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
    for name in ('suite', 'unknown'):
        openssl('x509', '-req', '-days', '1', '-in', root / 'leaf.csr', '-set_serial', '1',
                '-CA', root / (name + '.crt'), '-CAkey', root / (name + '.key'),
                '-extfile', root / 'extensions', '-out', root / (name + '-leaf.crt'))
    result_file = root / 'result.json'
    upstream = root / 'upstream'
    upstream.write_text('#!' + sys.executable + '\n' +
        'import json, os, sys\n' +
        'json.dump({"ca":os.environ.get("SSL_CERT_FILE"),"args":sys.argv[1:]},open(os.environ["HARP_RESULT"],"w"))\n' +
        'sys.exit(int(os.environ.get("HARP_EXIT", "0")))\n')
    upstream.chmod(0o755)
    source = entrypoint.read_text()
    for original, replacement in {
        '/usr/local/share/ca-certificates': certificates,
        '/etc/ssl/certs/ca-certificates.crt': root / 'system.crt',
        '/tmp/ca-certificates.crt': root / 'bundle.crt',
        '/usr/local/bin/start.sh': upstream,
    }.items():
        assert original in source, 'The entrypoint filesystem boundary moved'
        source = source.replace(original, str(replacement))
    wrapper = root / 'start.sh'
    wrapper.write_text(source)
    env = dict(os.environ, HARP_RESULT=str(result_file))
    for key in ('SSL_CERT_FILE', 'SSL_CERT_DIR'):
        env.pop(key, None)
    def run(status=0, **extra):
        result_file.unlink(missing_ok=True)
        result = subprocess.run(['bash', str(wrapper), 'argument with spaces', 'second'],
                                env=dict(env, **extra), capture_output=True, text=True)
        assert result.returncode == status, 'HaRP entrypoint returned an unexpected status'
        return json.loads(result_file.read_text()) if result_file.exists() else None
    state = run()
    assert state == {'ca':str(root / 'bundle.crt'), 'args':['argument with spaces', 'second']}
    for certificate in ('system.crt', 'suite-leaf.crt'):
        openssl('verify', '-CAfile', state['ca'], root / certificate)
    openssl('verify', '-purpose', 'sslserver', '-verify_ip', '127.0.0.1',
            '-CAfile', state['ca'], root / 'suite-leaf.crt')
    openssl('verify', '-purpose', 'sslserver', '-verify_ip', '127.0.0.1',
            '-CAfile', state['ca'], root / 'unknown-leaf.crt', success=False)
    (root / 'system.crt').unlink()
    assert run(status=1) is None, 'A failed CA bundle must not start the agent'
    shutil.rmtree(certificates)
    state = run()
    assert state == {'ca':None, 'args':['argument with spaces', 'second']}
    run(status=23, HARP_EXIT='23')
print('HaRP preserves system roots, trusts the suite CA, rejects an unknown CA and retains upstream arguments/status')
PY
}
check harp_trust_cases

appapi_smoke_cases() {
  python3 - <<'PY'
import os, pathlib, shutil, subprocess, sys, tempfile
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    (root / 'scripts').mkdir()
    (root / 'bin').mkdir()
    for name in ('appapi-smoke.sh', 'env.sh'):
        shutil.copyfile(pathlib.Path('scripts') / name, root / 'scripts' / name)
    docker = root / 'bin/docker'
    docker.write_text('#!' + sys.executable + '\n' + r'''
import json, os, sys
args = sys.argv[1:]
case = os.environ['APPAPI_CASE']
if args[0] == 'inspect':
    print('NC_DOMAIN=clinica.example')
elif args[:3] == ['exec', '-i', 'aps-conecta-harp']:
    sys.stdin.read()
    if case == 'tls':
        print('FAIL: synthetic TLS peer rejected', file=sys.stderr)
        sys.exit(1)
elif 'app_api:daemon:list' in args:
    daemon = {'name':'harp_aio', 'deploy_id':'docker-install', 'protocol':'http',
              'host':'nextcloud-aio-harp:8780', 'deploy_config':{
                  'net':'nextcloud-aio', 'nextcloud_url':'https://clinica.example',
                  'haproxy_password':'synthetic credential must stay private',
                  'harp':{'exapp_direct':True, 'docker_socket_port':24000}}}
    if case == 'string-port': daemon['deploy_config']['harp']['docker_socket_port'] = '24000'
    if case == 'wrong-network': daemon['deploy_config']['net'] = 'another-network'
    if case == 'malformed': print('{broken')
    elif case == 'empty': print('No registered daemon configs.')
    else: print(json.dumps([daemon, daemon] if case == 'duplicate' else [daemon]))
elif 'config:app:get' in args:
    print('' if case == 'no-default' else 'harp_aio')
elif 'setupchecks' in args:
    severity = 'error' if case == 'unreachable' else 'success'
    print(json.dumps({'system':{'OCA\\AppAPI\\SetupChecks\\DaemonCheck':{'severity':severity},
                                 'AnotherCheck':{'severity':'warning'}}}))
    sys.exit(1)
else:
    sys.exit(2)
''')
    docker.chmod(0o755)
    for case in ('good', 'string-port', 'wrong-network', 'malformed', 'empty',
                 'duplicate', 'no-default', 'unreachable', 'tls'):
        result = subprocess.run(['bash', str(root / 'scripts/appapi-smoke.sh')],
            env=dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'], APPAPI_CASE=case),
            capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == (case in ('good', 'string-port')), case
        assert 'synthetic credential' not in result.stdout + result.stderr, case
print('AppAPI accepts valid native state and refuses missing, duplicate, malformed, unreachable or untrusted state')
PY
}
check appapi_smoke_cases

registry_manifest_cases() {
  python3 - <<'PY'
import os, pathlib, subprocess, tempfile
module = pathlib.Path('php/src/Docker/GitHubContainerRegistryManager.php').resolve()
with tempfile.TemporaryDirectory() as directory:
    fixture = pathlib.Path(directory) / 'registry.php'
    fixture.write_text(r'''<?php
namespace GuzzleHttp {
    class Reply {
        public function __construct(private string $body = '') {}
        public function getBody(): self { return $this; }
        public function getContents(): string { return $this->body; }
        public function getHeader(string $name): array { return ['sha256:' . str_repeat('a', 64)]; }
    }
    class Client {
        public function request(string $method, string $url, array $options = []): Reply {
            if ($method === 'GET') {
                return new Reply(json_encode(['token' => 'synthetic registry credential']));
            }
            if (getenv('REGISTRY_UNAVAILABLE') === '1') { throw new \RuntimeException('registry unavailable'); }
            $accepted = array_map('trim', explode(',', $options['headers']['Accept']));
            if (!in_array(getenv('REGISTRY_MEDIA_TYPE'), $accepted, true)) {
                throw new \RuntimeException('registry cannot serve this manifest format');
            }
            return new Reply();
        }
    }
}
namespace AIO\Docker {
    function apcu_fetch(string $key): bool { return false; }
    function apcu_add(string $key, string $value, int $ttl): bool { return true; }
}
namespace {
    require $argv[1];
    $digest = (new \AIO\Docker\GitHubContainerRegistryManager())->GetLatestDigestOfTag('aps-conecta/aio-postgresql', 'fixture');
    echo $digest ?? 'missing';
}
''')
    for media_type in ('application/vnd.docker.distribution.manifest.v2+json',
                       'application/vnd.docker.distribution.manifest.list.v2+json',
                       'application/vnd.oci.image.index.v1+json',
                       'application/vnd.oci.image.manifest.v1+json'):
        for unavailable in ('0', '1'):
            result = subprocess.run(['php', str(fixture), str(module)],
                env=dict(os.environ, REGISTRY_MEDIA_TYPE=media_type, REGISTRY_UNAVAILABLE=unavailable),
                capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, 'The native registry method failed'
            assert result.stdout == ('missing' if unavailable == '1' else 'sha256:' + 'a' * 64), media_type
            assert 'synthetic registry credential' not in result.stdout + result.stderr
print('The native registry client accepts Docker and OCI manifests and preserves unavailable-registry results')
PY
}
check registry_manifest_cases

# Exercise the actual public container module with disposable command fixtures;
# the JSON parser is real PHP, while OCC and backend probes have controlled state.
app_startup_cases() {
  python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
module = pathlib.Path('Containers/nextcloud/configure-apps.sh').resolve()
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    commands = root / 'bin'
    commands.mkdir()
    state_path = root / 'state.json'
    real_php = shutil.which('php')
    assert real_php
    php = commands / 'php'
    php.write_text('#!' + sys.executable + '\n' + r'''
import json, os, pathlib, sys
if sys.argv[1] == '-r':
    os.execv(os.environ['REAL_PHP'], [os.environ['REAL_PHP'], *sys.argv[1:]])
p = pathlib.Path(os.environ['APP_STATE'])
s = json.loads(p.read_text())
a = sys.argv[2:]
s['calls'].append(a)
def save(): p.write_text(json.dumps(s))
if s.get('fail') == a[0]:
    save(); print('synthetic secret must never escape'); sys.exit(1)
if a[0] == 'app:list':
    save()
    if s.get('malformed'):
        print('{broken'); sys.exit()
    print(json.dumps({key: {app: '1.0' for app in s[key]} for key in ('enabled', 'disabled')}))
elif a[0] in ('app:enable', 'app:install'):
    if a[0] == 'app:install':
        assert a[1] == 'notify_push' and os.environ.get('NC_appstoreenabled') == '1'
    if a[1] in s['disabled']: s['disabled'].remove(a[1])
    if a[1] not in s['enabled']: s['enabled'].append(a[1])
    save()
elif a[0] in ('config:app:set', 'config:system:set'):
    key = ':'.join(a[:3])
    old = s['config'].get(key)
    s['config'][key] = a[3:]
    save()
    print('Config value were not updated' if old == a[3:] else "Config value 'key' for app 'app' is now set to 'synthetic secret must never escape'")
elif a[0] == 'config:list':
    save()
    print('{broken' if s.get('malformed_config') else json.dumps({
        'system': s.get('system', {}),
        'apps': {**dict.fromkeys(s['enabled'], {}),
                 **{key: value for key, value in s['config'].items() if isinstance(value, dict)}}}))
elif a[0] == 'config:import':
    payload = json.load(sys.stdin)
    assert set(payload) <= {'apps', 'system'}
    for app, values in payload.get('apps', {}).items():
        s['config'].setdefault(app, {}).update(values)
    s.setdefault('system', {}).update(payload.get('system', {}))
    s.setdefault('imports', []).append(payload)
    save()
elif a[0] == 'config:app:get':
    save()
    values = s['config'].get(a[1], {})
    if a[2] not in values: sys.exit(1)
    print(values[a[2]])
elif a[0] == 'config:system:get':
    save()
    print('OCA\\Eurooffice\\Preview' if a[1] == 'enabledPreviewProviders' else s.get('system', {}).get(a[1], ''))
elif a[0].endswith(':configure'):
    app = a[0].split(':')[0]
    for key, value in json.loads(a[1]).items():
        s['config']['app:' + app + ':' + key] = value
    save()
else:
    save()
''')
    php.chmod(0o755)
    for name, body in {
        'nc': 'exit 0', 'chmod': 'exit 0',
    }.items():
        command = commands / name
        command.write_text('#!/bin/bash\n' + body + '\n')
        command.chmod(0o755)
    digest = commands / 'sha256sum'
    digest.write_text('#!' + sys.executable + '\n' +
                      'import hashlib, json, os\n' +
                      's = json.load(open(os.environ["APP_STATE"]))\n' +
                      'system = {k:v for k,v in s["config"].items() if k.startswith("config:system:set:")}\n' +
                      'print(hashlib.sha256(json.dumps(system, sort_keys=True).encode()).hexdigest())\n')
    digest.chmod(0o755)
    env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'],
               APP_STATE=str(state_path), REAL_PHP=real_php,
               EUROOFFICE_ENABLED='yes', EUROOFFICE_HOST='aps-conecta-eurooffice',
               EUROOFFICE_SECRET='synthetic secret must never escape " \\ $', NC_DOMAIN='test.invalid',
               TALK_ENABLED='no', TALK_RECORDING_ENABLED='no', CLAMAV_ENABLED='no',
               FULLTEXTSEARCH_ENABLED='no', HARP_ENABLED='no', REMOVE_DISABLED_APPS='no',
               SERVERINFO_TOKEN='', SUBSCRIPTION_KEY='', IMAGINARY_ENABLED='no', IMAGINARY_HOST='imaginary.invalid',
               NEXTCLOUD_DATA_DIR=str(root), CLAMAV_HOST='clam', CLAMAV_BLOCKLISTED_DIRECTORIES='', PHP_UPLOAD_LIMIT='1G',
               FULLTEXTSEARCH_HOST='search', FULLTEXTSEARCH_PORT='9200', FULLTEXTSEARCH_USER='test',
               FULLTEXTSEARCH_PASSWORD='synthetic secret must never escape', FULLTEXTSEARCH_INDEX='test')
    (root / 'fts-index.done').touch()
    def reset(enabled=(), disabled=(), **extra):
        if 'eurooffice' in (*enabled, *disabled) and not extra.pop('missing_office', False):
            disabled = (*disabled, 'office')
        state_path.write_text(json.dumps(dict(enabled=list(enabled), disabled=list(disabled),
                                              config={}, calls=[], **extra)))
    def run(target='eurooffice', success=True, extra=None):
        effective = dict(env, **(extra or {}))
        result = subprocess.run(['bash', '-x', str(module), target], env=effective,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert (result.returncode == 0) == success, (result.returncode, result.stdout, result.stderr)
        assert 'synthetic secret must never escape' not in result.stdout + result.stderr
        for key in ('EUROOFFICE_SECRET', 'TURN_SECRET', 'SIGNALING_SECRET', 'RECORDING_SECRET',
                    'FULLTEXTSEARCH_PASSWORD', 'SERVERINFO_TOKEN', 'IMAGINARY_SECRET', 'SUBSCRIPTION_KEY'):
            value = effective.get(key)
            assert not value or value not in result.stdout + result.stderr, f'{key} was printed'
        return json.loads(state_path.read_text()), result.stdout
    reset()
    state, output = run()
    assert 'deferred' in output
    assert not any(call[0] in ('app:install', 'config:app:set', 'config:system:set') for call in state['calls'])
    reset(disabled=['eurooffice'], system={'eurooffice': {'custom_setting': 'keep'}})
    state, output = run()
    assert ['app:enable', 'eurooffice'] in state['calls']
    assert 'office' in state['enabled'], 'The native Office navigation app must be enabled'
    assert not any(call[:2] == ['app:disable', 'office'] for call in state['calls'])
    assert any(call[:3] == ['config:app:set', 'eurooffice', 'DocumentServerUrl'] and
               call[3] == '--value=https://test.invalid/eurooffice' for call in state['calls'])
    assert 'app:eurooffice:DocumentServerUrl -> updated' in output
    assert 'synthetic secret must never escape' not in json.dumps(state['calls']), 'Office secrets entered process arguments'
    assert state['system']['eurooffice']['jwt_secret'] == env['EUROOFFICE_SECRET']
    assert state['config']['eurooffice']['jwt_secret'] == env['EUROOFFICE_SECRET']
    assert output.count('system:eurooffice -> updated') == 3
    assert state['system']['eurooffice']['custom_setting'] == 'keep'
    first_config, first_system = state['config'], state['system']
    state, output = run()
    assert state['config'] == first_config and state['system'] == first_system and ' -> ' not in output
    assert len(state['imports']) == 2, 'Repeated Office wiring must not import unchanged secrets'
    assert sum(call == ['app:enable', 'eurooffice'] for call in state['calls']) == 1
    assert state['calls'].count(['app:enable', 'office']) == 1, 'Reruns must preserve the Office hub'
    rotated_office = env['EUROOFFICE_SECRET'] + ' rotated'
    state, _ = run(extra={'EUROOFFICE_SECRET': rotated_office})
    assert state['system']['eurooffice'] == {'custom_setting': 'keep', 'jwt_secret': rotated_office}
    assert state['config']['eurooffice']['jwt_secret'] == rotated_office
    assert len(state['imports']) == 4 and rotated_office not in json.dumps(state['calls'])
    for failure in ('app:list', 'app:enable', 'config:app:set', 'config:system:set', 'config:list', 'config:import'):
        reset(disabled=['eurooffice'], fail=failure)
        run(success=False)
    reset(disabled=['eurooffice'], missing_office=True)
    run(success=False)
    reset(malformed=True)
    run(success=False)
    reset(fail='app:install')
    run('boot', success=False)
    reset(enabled=['notify_push'])
    state, _ = run('boot', extra={'CLAMAV_ENABLED': 'yes', 'FULLTEXTSEARCH_ENABLED': 'yes'})
    assert not any(call[0] == 'app:install' or call[0].endswith(':configure') for call in state['calls'])
    assert not any(call[:2] == ['app:disable', app] for app in
                   ('eurooffice', 'files_antivirus', 'fulltextsearch', 'fulltextsearch_elasticsearch', 'files_fulltextsearch')
                   for call in state['calls'])
    reset()
    state, _ = run('boot')
    assert [call for call in state['calls'] if call[0] == 'app:install'] == [['app:install', 'notify_push']]
    reset(enabled=['notify_push', 'eurooffice', 'files_antivirus', 'fulltextsearch',
                   'fulltextsearch_elasticsearch', 'files_fulltextsearch', 'app_api'])
    state, _ = run('boot', extra={'CLAMAV_ENABLED': 'yes', 'FULLTEXTSEARCH_ENABLED': 'yes', 'HARP_ENABLED': 'yes'})
    assert sum(call[0].endswith(':configure') for call in state['calls']) == 3
    assert any(call[:3] == ['config:app:set', 'files_antivirus', 'av_host'] for call in state['calls'])
    reset(enabled=['notify_push', 'eurooffice', 'fulltextsearch', 'files_fulltextsearch'])
    state, _ = run('boot', extra={'FULLTEXTSEARCH_ENABLED': 'yes'})
    assert not any(call[0].endswith(':configure') for call in state['calls'])
    reset()
    state, output = run('fulltextsearch', extra={'FULLTEXTSEARCH_ENABLED': 'yes'})
    assert 'deferred' in output
    assert not any(call[0] == 'app:install' or call[0].endswith(':configure') for call in state['calls'])
    reset(disabled=['fulltextsearch', 'fulltextsearch_elasticsearch', 'files_fulltextsearch'])
    state, _ = run('fulltextsearch', extra={'FULLTEXTSEARCH_ENABLED': 'yes'})
    assert set(state['enabled']) == {'fulltextsearch', 'fulltextsearch_elasticsearch', 'files_fulltextsearch'}
    assert state['config']['app:fulltextsearch:search_platform'] == 'OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform'
    assert 'synthetic secret must never escape' not in json.dumps(state['calls']), 'Search secrets entered process arguments'
    assert state['config']['fulltextsearch_elasticsearch']['elastic_host'] == 'http://test:synthetic%20secret%20must%20never%20escape@search:9200'
    assert state['config']['app:fulltextsearch_elasticsearch:elastic_index'] == 'test'
    assert state['config']['app:files_fulltextsearch:files_pdf'] is True
    assert state['config']['app:files_fulltextsearch:files_office'] is True
    assert not any(call[0] == 'app:install' for call in state['calls'])
    reset()
    run('unknown', success=False)
    tokens = dict(SERVERINFO_TOKEN='synthetic server token " \\ $', IMAGINARY_ENABLED='yes',
                  IMAGINARY_SECRET='synthetic image key " \\ $', SUBSCRIPTION_KEY='synthetic subscription key " \\ $')
    reset(enabled=['notify_push'])
    state, _ = run('boot', extra=tokens)
    assert state['config'].get('serverinfo', {}).get('token') == tokens['SERVERINFO_TOKEN'], 'Serverinfo token did not reach Nextcloud'
    assert state['system']['preview_imaginary_key'] == tokens['IMAGINARY_SECRET']
    assert state['config'].get('support', {}).get('potential_subscription_key') == tokens['SUBSCRIPTION_KEY'], 'Subscription key did not reach Nextcloud'
    assert all(value not in word for value in (tokens['SERVERINFO_TOKEN'], tokens['IMAGINARY_SECRET'], tokens['SUBSCRIPTION_KEY'])
               for call in state['calls'] for word in call), 'Startup tokens entered process arguments'
    state, output = run('boot', extra=tokens)
    assert len(state['imports']) == 3 and ' -> ' not in output
    changed = dict(tokens, SERVERINFO_TOKEN='different server token', IMAGINARY_SECRET=tokens['IMAGINARY_SECRET'] + ' rotated',
                   SUBSCRIPTION_KEY='different subscription key')
    state, _ = run('boot', extra=changed)
    assert state['config']['serverinfo']['token'] == tokens['SERVERINFO_TOKEN'], 'An existing server token was overwritten'
    assert state['config']['support']['potential_subscription_key'] == tokens['SUBSCRIPTION_KEY']
    assert state['calls'].count(['config:app:delete', 'support', 'last_check']) == 1
    assert state['system']['preview_imaginary_key'] == changed['IMAGINARY_SECRET'] and len(state['imports']) == 4
    talk = dict(TALK_ENABLED='yes', TALK_HOST='aps-conecta-talk', TALK_PORT='3478',
                TURN_SECRET='synthetic secret must never escape " \\ $',
                SIGNALING_SECRET='synthetic secret must never escape " \\ $')
    reset()
    state, output = run('talk', extra=talk)
    assert 'deferred' in output and not state.get('imports')
    reset(disabled=['spreed'])
    state, output = run('talk', extra=talk)
    assert state['enabled'] == ['spreed']
    config = state['config']['spreed']
    assert json.loads(config['signaling_servers']) == {
        'servers': [{'server': 'https://test.invalid/standalone-signaling/', 'verify': True}],
        'secret': talk['SIGNALING_SECRET']}
    assert json.loads(config['turn_servers']) == [{'schemes': 'turn', 'server': 'test.invalid:3478',
        'protocols': 'udp,tcp', 'secret': talk['TURN_SECRET']}]
    assert json.loads(config['stun_servers']) == ['test.invalid:3478']
    assert config['certificate_expiration_days'] == '2'
    assert len(state['imports']) == 1
    state, output = run('talk', extra=talk)
    assert len(state['imports']) == 1 and ' -> ' not in output, 'Repeated Talk wiring must not write'
    rotated = dict(talk, SIGNALING_SECRET=talk['SIGNALING_SECRET'] + ' rotated')
    state, _ = run('talk', extra=rotated)
    assert set(state['imports'][-1]['apps']['spreed']) == {'signaling_servers'}
    assert json.loads(state['config']['spreed']['signaling_servers'])['secret'] == rotated['SIGNALING_SECRET']
    assert 'synthetic secret must never escape' not in json.dumps(state['calls']), 'Talk secrets entered process arguments'
    for failure in ('app:list', 'app:enable', 'config:list', 'config:import'):
        reset(disabled=['spreed'], fail=failure)
        run('talk', success=False, extra=talk)
    reset(enabled=['spreed'], malformed_config=True)
    run('talk', success=False, extra=talk)
    reset(enabled=['spreed'])
    run('talk', success=False, extra=dict(talk, TURN_SECRET=''))
    reset(enabled=['notify_push', 'spreed'])
    state, _ = run('boot', extra=talk)
    assert len(state['imports']) == 1, 'Boot must use the same Talk configuration owner'
    recording = dict(talk, TALK_RECORDING_ENABLED='yes', TALK_RECORDING_HOST='recording.invalid',
                     RECORDING_SECRET='synthetic secret must never escape " \\ $')
    reset(enabled=['notify_push', 'spreed'])
    state, _ = run('boot', extra=recording)
    assert 'synthetic secret must never escape' not in json.dumps(state['calls']), 'Recording secrets entered process arguments'
    assert json.loads(state['config']['spreed']['recording_servers']) == {
        'servers': [{'server': 'http://recording.invalid:1234/', 'verify': True}],
        'secret': recording['RECORDING_SECRET']}
    state, output = run('boot', extra=recording)
    assert len(state['imports']) == 2 and ' -> ' not in output
    rotated_recording = recording['RECORDING_SECRET'] + ' rotated'
    state, _ = run('boot', extra=dict(recording, RECORDING_SECRET=rotated_recording))
    assert len(state['imports']) == 3 and set(state['imports'][-1]['apps']['spreed']) == {'recording_servers'}
    assert json.loads(state['config']['spreed']['recording_servers'])['secret'] == rotated_recording
    clock = root / 'clock.sh'
    clock.write_text('sleep() { SECONDS=$((SECONDS + $1)); }\n')
    (commands / 'nc').write_text('#!/bin/bash\nexit 1\n')
    reset(disabled=['eurooffice'])
    state, _ = run(extra={'BASH_ENV': str(clock)})
    assert 'office' in state['enabled'], 'A delayed editor must not hide the Office hub'
    reset(enabled=['notify_push', 'spreed'])
    state, output = run('boot', extra=dict(talk, TALK_RECORDING_ENABLED='yes',
        TALK_RECORDING_HOST='recording.invalid', RECORDING_SECRET='synthetic secret must never escape',
        BASH_ENV=str(clock)))
    assert 'Talk Recording unavailable' in output
    assert not any(call[:3] == ['config:app:set', 'spreed', 'recording_servers'] for call in state['calls'])
    assert state['enabled'] == ['notify_push', 'spreed'], 'Recording timeout must preserve Talk'
phase = pathlib.Path('provisioning/phases/14-office.sh').read_text()
assert 'nc_exec --user www-data -- bash /configure-apps.sh eurooffice' in phase
entrypoint = pathlib.Path('Containers/nextcloud/entrypoint.sh').read_text()
assert 'source /configure-apps.sh' in entrypoint and 'configure_startup_apps || exit 1' in entrypoint
assert 'app:install' not in entrypoint
PY
}
check app_startup_cases

talk_smoke_cases() {
  python3 - <<'PY'
import copy, json, os, pathlib, shutil, subprocess, sys, tempfile
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    for name in ('scripts', 'bin'):
        (root / name).mkdir()
    for name in ('env.sh', 'talk-smoke.sh'):
        shutil.copyfile('scripts/' + name, root / 'scripts' / name)
    ca = root / 'ca.crt'
    ca.touch()
    state_path = root / 'state.json'
    command = '#!' + sys.executable + '\n' + r'''
import json, os, pathlib, sys
p = pathlib.Path(os.environ['TALK_SMOKE_STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
s['calls'].append([pathlib.Path(sys.argv[0]).name, *a])
p.write_text(json.dumps(s))
if pathlib.Path(sys.argv[0]).name == 'curl':
    if s.get('curl_failure'): print('synthetic secret must never escape', file=sys.stderr); sys.exit(60)
    print(s['welcome'] + '\n' + s.get('http_status', '200'))
elif a[0] == 'inspect':
    print('NC_DOMAIN=192.0.2.50')
elif a[4:7] == ['test', '-s', '/var/www/html/custom_apps/spreed/appinfo/signature.json']:
    sys.exit(s.get('signature_exit', 0))
elif a[6:8] == ['integrity:check-app', 'spreed']:
    sys.exit(s.get('integrity_exit', 0))
else:
    assert a[:5] == ['exec', '--user', 'www-data', 'aps-conecta-nextcloud', 'php']
    name = a[6]
    assert name in s['native']
    if s.get('native_failure') == name: print('synthetic secret must never escape'); sys.exit(2)
    print(s['native'][name])
    sys.exit(s.get('setup_exit', 0) if name == 'setupchecks' else 0)
'''
    for name in ('docker', 'curl'):
        path = root / 'bin' / name
        path.write_text(command)
        path.chmod(0o755)
    check = 'OCA\\Talk\\SetupCheck\\HighPerformanceBackend'
    base = {'calls': [], 'welcome': '{"nextcloud-spreed-signaling":"Welcome","version":"2.1.1"}', 'native': {
        'talk:signaling:list': json.dumps({'servers': [{'server': 'https://192.0.2.50/standalone-signaling/', 'verify': True}], 'secret': 'synthetic secret must never escape'}),
        'talk:turn:list': json.dumps([{'schemes': 'turn', 'server': '192.0.2.50:3478', 'protocols': 'udp,tcp', 'secret': 'synthetic secret must never escape'}]),
        'talk:stun:list': '["192.0.2.50:3478"]',
        'setupchecks': json.dumps({'talk': {check: {'severity': 'success'}},
            'system': {'OCA\\Settings\\SetupChecks\\MemcacheConfigured': {'severity': 'success'}}}),
        'config:system:get': '\\OC\\Memcache\\Redis'}}
    env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
               SUITE_CA=str(ca), TALK_SMOKE_STATE=str(state_path), NC_CONTAINER='aps-conecta-nextcloud')
    def run(state, success=True):
        state_path.write_text(json.dumps(state))
        result = subprocess.run(['bash', str(root / 'scripts/talk-smoke.sh')], env=env,
                                capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert 'synthetic secret must never escape' not in result.stdout + result.stderr
        state = json.loads(state_path.read_text())
        state['output'] = result.stdout + result.stderr
        return state
    state = run(base)
    assert any(call[0] == 'docker' and 'setupchecks' in call for call in state['calls']), 'Talk smoke must run the native signaling check'
    curl = next(call for call in state['calls'] if call[0] == 'curl')
    assert '--cacert' in curl and str(ca) in curl
    assert curl[-1] == 'https://192.0.2.50/standalone-signaling/api/v1/welcome'
    assert not any(arg in ('-k', '--insecure', '-L', '--location') for arg in curl)
    for key in ('signature_exit', 'integrity_exit'):
        state = copy.deepcopy(base); state[key] = 1
        run(state, success=False)
    state = copy.deepcopy(base); state['setup_exit'] = 1
    run(state)
    state = copy.deepcopy(base)
    checks = json.loads(state['native']['setupchecks'])
    checks['talk'][check] = {'severity': 'warning', 'description':
        'Warning: Running version: 2.1.1; Server does not support all features of this Talk version, missing features: changed-users'}
    state['native']['setupchecks'] = json.dumps(checks)
    state['setup_exit'] = 1
    compatible = copy.deepcopy(state)
    result = run(state)
    assert 'WARN:' in result['output'] and any('config:system:get' in call for call in result['calls'])
    checks['talk'][check]['description'] = 'Advertencia: Versión en ejecución: 2.1.1; El servidor no soporta todas las características de esta versión de Talk, características que faltan: changed-users'
    state['native']['setupchecks'] = json.dumps(checks)
    run(state)
    for description in (
        'Warning: Running version: 2.1.1; Server does not support all features of this Talk version, missing features: chat-relay, changed-users',
        'Warning: Running version: 2.1.1; Server does not support all features of this Talk version, missing features: chat-relay; Server does not support all features of this Talk version, missing features: changed-users',
        'It is highly recommended to configure a memory cache when running Nextcloud Talk with a High-performance backend.',
    ):
        state = copy.deepcopy(compatible)
        checks = json.loads(state['native']['setupchecks'])
        checks['talk'][check]['description'] = description
        state['native']['setupchecks'] = json.dumps(checks)
        run(state, success=False)
    for cache_state in ('warning', 'error', 'missing'):
        state = copy.deepcopy(compatible)
        checks = json.loads(state['native']['setupchecks'])
        checks['system'] = {} if cache_state == 'missing' else {'OCA\\Settings\\SetupChecks\\MemcacheConfigured': {'severity': cache_state}}
        state['native']['setupchecks'] = json.dumps(checks)
        run(state, success=False)
    state = copy.deepcopy(compatible)
    state['native']['config:system:get'] = '\\OC\\Memcache\\NullCache'
    run(state, success=False)
    for key, value in [('native_failure', 'config:system:get'), ('curl_failure', True), ('setup_exit', 2)]:
        state = copy.deepcopy(compatible); state[key] = value
        run(state, success=False)
    state = copy.deepcopy(base)
    state['native']['setupchecks'] = json.dumps({'talk': {check: {'severity': 'warning',
        'description': 'synthetic secret must never escape; changed-users'}}})
    result = run(state, success=False)
    assert 'severity=warning; changed-users mentioned=yes' in result['output'], 'Native failure details must expose only safe diagnostic facts'
    for name, value in [('talk:signaling:list', '[]'), ('talk:turn:list', '[]'),
                        ('talk:stun:list', '["stun.nextcloud.com:443"]'), ('setupchecks', '{}'),
                        ('setupchecks', json.dumps({'talk': {check: {'severity': 'warning'}}})),
                        ('setupchecks', '{broken')]:
        state = copy.deepcopy(base); state['native'][name] = value
        run(state, success=False)
    for key, value in [('native_failure', 'setupchecks'), ('curl_failure', True),
                       ('welcome', '{}'), ('welcome', '{broken'), ('http_status', '302')]:
        state = copy.deepcopy(base); state[key] = value
        run(state, success=False)
print('Talk smoke verifies native wiring, CA-verified public welcome and the native signaling diagnostic')
PY
}
check talk_smoke_cases

phase12_talk_cases() {
  python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    for name in ('scripts', 'provisioning/phases', 'bin', 'store/spreed'):
        (root / name).mkdir(parents=True)
    for name in ('scripts/env.sh', 'scripts/apps.py', 'scripts/releases.py',
                 'provisioning/lib.sh', 'provisioning/phases/12-apps.sh'):
        shutil.copyfile(name, root / name)
    (root / 'apps.json').write_text(json.dumps([
        {'id':'spreed', 'source':'store', 'optional':False, 'containers':[]}]))
    state_path = root / 'state.json'
    docker = root / 'bin/docker'
    docker.write_text('#!' + sys.executable + '\n' + r'''
import json, os, pathlib, sys
path = pathlib.Path(os.environ['TALK_PHASE_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
assert args.pop(0) == 'exec'
while args[0].startswith('-'):
    option = args.pop(0)
    if option in ('--user', '-e'): args.pop(0)
    else: assert option == '-i'
assert args.pop(0) == 'aps-conecta-nextcloud'
state['calls'].append(args)
def save(): path.write_text(json.dumps(state))
if args[-1] == '/var/www/html/custom_apps/spreed/appinfo/info.xml':
    save(); print(state.get('version', ''))
elif args[:4] == ['php', '/var/www/html/occ', 'app:install', 'spreed']:
    assert '-e' in sys.argv and 'NC_appstoreenabled=1' in sys.argv, 'Store install must be scoped'
    if state.get('fail') == 'install': save(); sys.exit(1)
    state['version'] = '24.0.6'
    save()
elif args[0] == 'php' and args[2] == 'config:list':
    if state.get('fail') == 'config': save(); sys.exit(1)
    save(); print(json.dumps({'apps':{'spreed':{'enabled':'yes' if state['enabled'] else 'no'}}}))
elif args[0] == 'php' and args[2:4] == ['app:enable', 'spreed']:
    state['enabled'] = True
    save()
elif args == ['bash', '/configure-apps.sh', 'talk']:
    assert state['enabled'] and state['version'] == '24.0.6', 'Talk wiring ran before installation'
    state['wired'] += 1
    save()
    if state.get('fail') == 'wire': sys.exit(1)
else:
    raise AssertionError('Unexpected container command')
''')
    docker.chmod(0o755)
    env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
               APS_APPS_LOCK=str(root / 'lock.json'), APS_APPS_STORE=str(root / 'store'),
               TALK_PHASE_STATE=str(state_path))
    env.pop('NC_CONTAINER', None)
    runner = '''set -euo pipefail
source scripts/env.sh
source provisioning/lib.sh
HERE="$PWD/provisioning"
SEED_CTX=1
source provisioning/phases/12-apps.sh
'''
    def run(success=True):
        result = subprocess.run(['bash', '-c', runner], cwd=root, env=env,
                                capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == success, 'Phase 12 returned an unexpected status'
        return json.loads(state_path.read_text())
    state_path.write_text(json.dumps({'enabled':False, 'wired':0, 'calls':[]}))
    state = run()
    assert state['wired'] == 1, 'Phase 12 must wire Talk immediately after its official store install'
    assert state['calls'].index(['php', '/var/www/html/occ', 'app:enable', 'spreed']) < state['calls'].index(['bash', '/configure-apps.sh', 'talk'])
    state = run()
    assert state['wired'] == 2, 'An already installed store app must still converge its Talk configuration'
    assert sum(call[:4] == ['php', '/var/www/html/occ', 'app:install', 'spreed'] for call in state['calls']) == 1, 'A repeated phase must preserve the installed app'
    for failure in ('install', 'config', 'wire'):
        state_path.write_text(json.dumps({'enabled':False, 'wired':0, 'calls':[], 'fail':failure}))
        state = run(success=False)
        assert state['wired'] == (1 if failure == 'wire' else 0)
    (root / 'apps.json').write_text(json.dumps([
        {'id':'spreed', 'source':'store', 'optional':'off', 'containers':[]}]))
    home = root / 'home'
    (home / 'aio').mkdir(parents=True)
    (home / 'aio/opciones').write_text('spreed=1\n')
    env['APS_HOME'] = str(home)
    env.pop('AIO_STATE', None)
    env.pop('APS_APPS_OPCIONES', None)
    state_path.write_text(json.dumps({'enabled':False, 'wired':0, 'calls':[]}))
    state = run()
    assert state['wired'] == 1, 'Phase 12 must install an optional app selected under APS_HOME'
    alternate = root / 'alternate'
    alternate.mkdir()
    (alternate / 'opciones').write_text('spreed=0\n')
    env['AIO_STATE'] = str(alternate)
    state_path.write_text(json.dumps({'enabled':False, 'wired':0, 'calls':[]}))
    assert run()['wired'] == 0, 'AIO_STATE must retain precedence over APS_HOME'
    env['APS_APPS_OPCIONES'] = str(home / 'aio/opciones')
    state_path.write_text(json.dumps({'enabled':False, 'wired':0, 'calls':[]}))
    assert run()['wired'] == 1, 'APS_APPS_OPCIONES must retain precedence over AIO_STATE'
print('Phase 12 wires fresh and existing official Talk installs and propagates installation/configuration failures')
PY
}
check phase12_talk_cases

# Janus uses its co-located TURN server before a public domain exists. Exercise
# the real startup writer; only container paths and external discovery are fixtures.
talk_bootstrap_cases() {
  python3 - <<'PY'
import os, pathlib, re, subprocess, tempfile
source = pathlib.Path('Containers/talk/start.sh').read_text()
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    conf, sample, commands = root / 'conf', root / 'janus', root / 'bin'
    for folder in (conf, sample, commands):
        folder.mkdir()
    (sample / 'janus.jcfg.sample').write_text('nat: {\n turn_server = "old"\n}\n')
    script = root / 'start.sh'
    script.write_text(source.replace('/conf/', str(conf) + '/').replace('/etc/janus/', str(sample) + '/'))
    for name, body in {
        'mountpoint': 'exit 1',
        'hostname': 'echo 172.25.0.7',
        'dig': 'case "$*" in *" AAAA "*) ;; *) echo 172.25.0.7 ;; esac',
        'erl': 'printf "%s\\n" fixture-derived-turn-password',
    }.items():
        command = commands / name
        command.write_text('#!/bin/bash\n' + body + '\n')
        command.chmod(0o755)
    env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'],
               NC_DOMAIN='aio-test.invalid', TALK_HOST='aps-conecta-talk', TALK_PORT='3478',
               TURN_SECRET='synthetic-turn-secret', SIGNALING_SECRET='synthetic-signaling-secret',
               INTERNAL_SECRET='synthetic-internal-secret', AIO_LOG_LEVEL='warn')
    for override, expected in ((None, '127.0.0.1'), ('turn.example.test', 'turn.example.test')):
        env.pop('TURN_DOMAIN', None)
        if override is not None:
            env['TURN_DOMAIN'] = override
        result = subprocess.run(['bash', str(script), '/bin/true'], env=env,
                                capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, 'Talk startup fixture failed before configuration'
        config = (conf / 'janus.jcfg').read_text()
        server = re.search(r'turn_server\s*=\s*"([^"]+)"', config)
        assert server and server[1] == expected, f'Janus TURN endpoint is {server[1] if server else "absent"}; expected {expected}'
PY
}
check talk_bootstrap_cases

# --- gate (#176): no account cap — what builds the images sets none of the one-click-instance keys -
# Upstream enforces one-click-instance.user-limit inside createUser (web, OCS and occ alike), so the
# key set anywhere in the images caps the staff an establishment can have. The keys may appear only
# where a boot deletes them from an instance that still carries them; the row proves it can red.
one_click_rows() {  # git-grep lines in, every line that is not a boot's delete out
  grep -vE '^[^:]+:[0-9]+:php /var/www/html/occ config:system:delete one-click-instance(\.user-limit|\.link)?$' || true
}
one_click_cap_cases() {
  local rows
  rows="$(git grep -n one-click-instance -- Containers php | one_click_rows)"
  [ -z "$rows" ] || { printf 'the one-click-instance cap is in the image sources:\n%s\n' "$rows" >&2; return 1; }
  rows="$(printf '%s\n' "Containers/nextcloud/config/aio.config.php:3:  'one-click-instance' => true," \
    "Containers/nextcloud/entrypoint.sh:9:php /var/www/html/occ config:system:set one-click-instance.user-limit --value=100 --type=int" \
    "Containers/nextcloud/entrypoint.sh:10:php /var/www/html/occ config:system:delete one-click-instance.user-limit" | one_click_rows)"
  [ "$(printf '%s\n' "$rows" | grep -c .)" = 2 ] \
    || { printf 'the row missed a planted cap or flagged the delete:\n%s\n' "$rows" >&2; return 1; }
}
check one_click_cap_cases

# --- gate (#202): a restore stops at its first error, and its failure marker stays ----------------
# The database image's real start.sh, its data and dump directories moved into a temp tree, replays
# a fixture dump through a stub psql that keeps psql's error contract: a failing statement prints
# an ERROR and the replay goes on (exit 0) unless ON_ERROR_STOP is set, which stops it (exit 3).
restore_start() {  # TREE — one start of the copied start.sh: its exit in rc, its output in out
  rc=0; out="$(PATH="$1/bin:$PATH" POSTGRES_USER=nextcloud POSTGRES_DB=nextcloud_database POSTGRES_PASSWORD=x \
    timeout 60 bash "$1/start.sh" 2>&1)" || rc=$?
}
restore_stop_cases() {
  local tmp rc out dump
  tmp="$(mktemp -d)"; mkdir -p "$tmp/bin" "$tmp/data" "$tmp/dump"; dump="$tmp/dump/database-dump.sql"
  sed "s|/var/lib/postgresql/data|$tmp/data|g; s|/mnt/data|$tmp/dump|g" Containers/postgresql/start.sh > "$tmp/start.sh"
  if grep -qE '/var/lib/postgresql|/mnt/data' "$tmp/start.sh"; then
    echo "restore: start.sh names a path the copy did not move" >&2; rm -rf "$tmp"; return 1
  fi
  printf '#!/usr/bin/env bash\necho "${PGPORT:-5432}" >> %q\n' "$tmp/started" > "$tmp/bin/docker-entrypoint.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/pg_ctl"
  cat > "$tmp/bin/psql" <<'STUB'
#!/usr/bin/env bash
case "$*" in *" -c "*) exit 0 ;; esac
stop=0; case "$*" in *ON_ERROR_STOP=1*) stop=1 ;; esac
n=0
while IFS= read -r line; do
  n=$((n + 1))
  case "$line" in *oc_missing*)
    echo "psql:<stdin>:$n: ERROR:  relation \"public.oc_missing\" does not exist" >&2
    [ "$stop" = 0 ] || exit 3 ;;
  esac
done
exit 0
STUB
  chmod +x "$tmp/bin/"*
  cat > "$dump" <<'DUMP'
--
-- Name: oc_appconfig; Type: TABLE; Schema: public; Owner: oc_nextcloud
--
CREATE TABLE public.oc_appconfig (appid character varying(32) NOT NULL);
ALTER TABLE public.oc_appconfig OWNER TO oc_nextcloud;
GRANT ALL ON SCHEMA public TO oc_nextcloud;
DUMP
  restore_start "$tmp"
  [ "$rc" = 0 ] && [ ! -e "$tmp/dump/import.failed" ] && grep -qx 5432 "$tmp/started" \
    || { echo "restore: a clean dump must restore and start the server (exit $rc): $out" >&2; rm -rf "$tmp"; return 1; }
  rm -rf "${tmp:?}/data/"* "$tmp/started"
  echo 'INSERT INTO public.oc_missing VALUES (1);' >> "$dump"
  restore_start "$tmp"
  [ "$rc" != 0 ] && [ -e "$tmp/dump/import.failed" ] && ! grep -qx 5432 "$tmp/started" \
    || { echo "restore: a failing statement must stop the replay, keep import.failed and start nothing (exit $rc): $out" >&2; rm -rf "$tmp"; return 1; }
  restore_start "$tmp"
  [ "$rc" = 1 ] && [[ "$out" == *"The database import failed"* ]] && ! grep -qx 5432 "$tmp/started" \
    || { echo "restore: the start after a failed replay must refuse (exit $rc): $out" >&2; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}
check restore_stop_cases

# --- gate: the anchors the wizard links into these docs still resolve ---------------------
# The wizard (patch 140's and 170's bytes, committed since the hard fork) links six sections of
# the runbooks by their GitHub anchors. A renamed or renumbered heading breaks those links in
# every published suite image without a word, so the six are a contract: a heading keeps its
# slug, or an explicit <a id=\"…\"></a> carries it. GitHub's slug: lower-case, every character but
# letters, digits, spaces, hyphens and underscores dropped, spaces to hyphens. Same validator on
# a fabricated doc.
check python3 -c '
import re, sys
ANCLAS = {"aps/INSTALLER.md": ["3-preflight", "7-dns-the-host-must-reach-its-own-domain-d10", "11-backups", "12-troubleshooting"],
          "aps/GUIA-CLINICA.md": ["3-el-asistente-8080", "7-tras-actualizar"]}
def slugs(text):
    text = re.sub(r"^[ \t]*```.*?^[ \t]*```[^\n]*", "", text, flags=re.M | re.S)   # a heading inside a code block is not one
    out = {re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-") for h in re.findall(r"^#{1,6} (.+)$", text, re.M)}
    return out | set(re.findall(r"<a (?:id|name)=\"([^\"]+)\"", text))
def missing(text, want):
    return [a for a in want if a not in slugs(text)]
for doc, want in ANCLAS.items():
    gone = missing(open(doc, encoding="utf-8").read(), want)
    if gone: print(doc + ": the wizard links #" + ", #".join(gone) + " — no heading or <a id> carries it"); sys.exit(1)
if missing("## 3. Preflight checks\n", ["3-preflight"]) != ["3-preflight"]: print("a renamed heading passed"); sys.exit(1)
if missing("```bash\n# 3. Preflight\n```\n", ["3-preflight"]) != ["3-preflight"]: print("a heading inside a code block passed"); sys.exit(1)
if missing("<a id=\"3-preflight\"></a>\n## 2. Preflight\n", ["3-preflight"]): print("an explicit anchor was not read"); sys.exit(1)
print("ok")'

# --- gate: the install by IP's CA guide (R22) — one walkthrough, pointed at where it is -------------
# The console's last lines and step 7 send staff to GUIA §10; the English twin is INSTALLER §13. The
# pointers name the headings that hold the guide, and the two sections carry the same commands, byte
# for byte, and as many bullets — the one walkthrough in two languages. Same validator on drifted pairs.
check python3 -c '
import re, sys
def section(text, head):
    if head not in text: return None
    s = text[text.index(head):]
    end = s.find("\n## ", 1)
    return s if end < 0 else s[:end]
def blocks(text):
    return re.findall(r"^ *```[a-z]*\n(.*?)^ *```", text, re.M | re.S)
def twins(en, es):
    return (en is not None and es is not None and blocks(en) and blocks(en) == blocks(es)
            and len(re.findall(r"^- \*\*", en, re.M)) == len(re.findall(r"^- \*\*", es, re.M)))
en = section(open("aps/INSTALLER.md", encoding="utf-8").read(), "\n## 13. Without a domain: this server\x27s IP\n")
es = section(open("aps/GUIA-CLINICA.md", encoding="utf-8").read(), "\n## 10. Sin dominio: la dirección IP del servidor\n")
if not twins(en, es): print("INSTALLER §13 and GUIA §10 are missing or carry different commands"); sys.exit(1)
if "aps/GUIA-CLINICA.md §10" not in open("host/aps-conecta", encoding="utf-8").read(): print("the console does not point at GUIA §10"); sys.exit(1)
if "(guía, §10)" not in open("scripts/provisionador.py", encoding="utf-8").read(): print("step 7 does not point at GUIA §10"); sys.exit(1)
if twins("## 14. x\n```\na\n```\n", "## 11. y\n```\nb\n```\n"): print("a drifted pair passed"); sys.exit(1)
if twins("## 14. x\n- **A**\n```\na\n```\n", "## 11. y\n```\na\n```\n"): print("a pair missing a bullet passed"); sys.exit(1)
print("ok")'

# --- org L5-11/L5-05/L5-12: the provisioning self-tests (hermetic) ----------------------------
# standings.sh: the one uid derivation's fixture parity; env.sh: the loader round-trip (its
# container arms run on a stub docker); usuarios.sh: the frame guards; apps.py: the suite manifest's shape and
# that every container it names is defined.
check bash provisioning/standings.sh --self-test
check python3 scripts/apps.py --self-test
# releases.py (#33): the app-release resolver — resolve/fetch/lock over a local fixture hub with
# a throwaway key, real redirects and real signify crypto. The signer rides along in the CI job
# already (package-release's self-test needs it); locally its absence is an honest skip, the
# same shape as package-release's arm below.
if command -v signify >/dev/null 2>&1; then
  check python3 scripts/releases.py --self-test
else
  echo "  skipped: releases --self-test (no signify — sudo apt-get install signify-openbsd)"
fi
# brand-tokens.py (#49): the wizard's brand-token projection — pure stdlib, runs everywhere.
check python3 scripts/brand-tokens.py --self-test
# vm-acceptance.sh (#54): the ticket's own acceptance, on a scratch Ubuntu 24.04 VM — the
# self-test pins the classification arms (bootstrap markers, the release five, the store rows,
# the OCS/status answers, the revisar posture) against PATH shims: no root, no docker, no
# network. The VM run itself is the release ritual's, not CI's (aps/RELEASING.md §7).
check bash scripts/vm-acceptance.sh --self-test
# wizard-fonts.py (#49): the wizard's font subsets' coverage — needs fontTools, which ci.yml's
# gate job installs for row 270; a box without it gets the honest skip (the gate row itself
# fails loudly there, never passes vacuously — the same stance as the tool's import exit).
if python3 -c "import fontTools, brotli" >/dev/null 2>&1; then
  check python3 scripts/wizard-fonts.py --self-test
else
  echo "  skipped: wizard-fonts --self-test (no fontTools — pip install fonttools brotli)"
fi
# #66: the manifest-read failure is said in ONE place — apps.py's own stderr line, which every
# reader already shows beside it (a command substitution captures stdout only). No reader may
# carry its own copy of the old narration again, and no reader gets a field it discards: `lines`
# (id, source, repo — its only reader dropped the source column) is retired for `repos`, whose
# output the self-test pins. This sweep skips its own needles (scripts/test.sh).
check python3 -c '
import pathlib, sys
NEEDLES = (
    ("apps.py lines", "still calls the retired subcommand (its only reader discarded the source column)"),
    ("could not read the suite manifest", "carries a copy of the manifest-failure narration"),
    ("(apps.json) is unreadable", "carries a copy of the manifest-failure narration"),
)
for path in sorted(p for p in pathlib.Path(".").rglob("*")
                   if p.is_file() and ".git" not in p.parts and "__pycache__" not in p.parts
                   and p != pathlib.Path("scripts/test.sh")                 # this sweep itself
                   and p.stat().st_size < 500_000):                           # skip large binaries
    text = path.read_text(encoding="utf-8", errors="ignore")
    for needle, why in NEEDLES:
        if needle in text:
            print(f"{path}: {why} — apps.py says the failure once, on stderr, beside every reader"); sys.exit(1)
print("ok")'
check bash scripts/env.sh --self-test
# #163: both gates curl the suite's public URL — by IP with the installer's CA — never .env's HTTP_PORT
# (set to the template's 8180 here). Each gate runs against a stub docker (apache on 443 by IP; checks
# 1-4 and the connector answer) and a stub curl that records its argv and answers nothing; the gate's
# FIRST curl is asserted, whatever its verdict.
public_url_cases() {
  local tmp gate first mode ca
  local -a state
  tmp="$(mktemp -d)"; mkdir "$tmp/bin"; : > "$tmp/ca.crt"
  cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  ps*) echo aps-conecta-nextcloud ;;
  inspect*aps-conecta-apache*) printf 'APACHE_PORT=443\nNC_DOMAIN=203.0.113.10\n' ;;
  *"occ status"*) echo '{"installed":true}' ;;
  *"config:app:get eurooffice enabled"*) echo yes ;;
  *redis-cli*) echo PONG ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CURL_LOG"\nexit 7\n' > "$tmp/bin/curl"
  chmod +x "$tmp/bin/docker" "$tmp/bin/curl"
  mkdir -p "$tmp/home/certificados/ca"
  : > "$tmp/home/certificados/ca/aps-conecta-ca.crt"
  for mode in explicit home; do
    ca="$tmp/ca.crt"; state=("SUITE_CA=$ca")
    if [ "$mode" = home ]; then
      ca="$tmp/home/certificados/ca/aps-conecta-ca.crt"; state=("APS_HOME=$tmp/home")
    fi
    for gate in smoke:/status.php office-smoke:/eurooffice/healthcheck; do
      : > "$tmp/curl.log"
      PATH="$tmp/bin:$PATH" CURL_LOG="$tmp/curl.log" HTTP_PORT=8180 env -u SUITE_CA "${state[@]}" \
        bash "scripts/${gate%%:*}.sh" >/dev/null 2>&1
      first="$(head -1 "$tmp/curl.log")"
      case " $first " in
        *" --cacert $ca "*" https://203.0.113.10${gate#*:} "*|*" https://203.0.113.10${gate#*:} "*" --cacert $ca "*) ;;
        *) echo "public URL: ${gate%%:*}'s first curl is «$first», not https://203.0.113.10${gate#*:} with the CA" >&2; rm -rf "$tmp"; return 1 ;;
      esac
    done
  done
  rm -rf "$tmp"
}
check public_url_cases
# #197: the template ships no Nextcloud container and no caller restates its default or guards it
# (`:-` `-` `:?` `?`) — env.sh section 3 is the one place it is decided. git grep exits 1 on no
# match and 128 on error, so only a real "none found" passes (a tree without git is red, not green).
check bash -c '! grep -q "^NC_CONTAINER=" .env.example && { git grep -qE "NC_CONTAINE[R]:?[?-]" -- . ":!scripts/env.sh"; [ $? -eq 1 ]; }'
check bash provisioning/usuarios.sh --self-test

echo "== self-tests (hermetic — no docker, no stack) =="
# The Provisionador's own --self-test (its stub oracle rides --self-test, so the runner needs no
# docker), the host bundle's, and the migration tool's run everywhere test.sh runs — every
# PR, any box — because none needs a stack. The bootstrap's joins them (fixture packages and PATH
# shims only), and so does the signer's — the one self-test that needs signify installed, because
# it is real crypto over a throwaway keypair; CI apt-installs the same package the clinic verifies
# with, and a box without it gets the honest skip. Output is captured, not drowned: a green arm
# prints its own last line, a red one its tail — the #96 lesson, a red log must carry its diagnosis.
# A waived run must SAY so in this log: the self-test prints "SKIPPED (waived …, NOT a pass)" once, but only its
# last line used to reach this output — so CI's log read "237 checks OK" and nothing of the browser arms that
# did not run. This echoes the waiver (with the count of arms) and nothing else of the self-test's output.
selftest_waivers() { printf '%s\n' "$1" | { grep -a "SKIPPED (waived" || true; } | sed 's/^ *//; s/^/  /'; }
selftest_waivers_cases() {
  local w
  w="$(selftest_waivers "$(printf '  ok:   1. x\n  SKIPPED (waived by X=1, NOT a pass): 16 browser arms did NOT run — y\nself-test: 237 checks OK\n')")"
  [ "$w" = "  SKIPPED (waived by X=1, NOT a pass): 16 browser arms did NOT run — y" ] || return 1
  [ -z "$(selftest_waivers "$(printf '  ok:   1. x\nself-test: 254 checks OK\n')")" ] || return 1
  selftest_waivers "$(printf 'self-test: 254 checks OK\n')" >/dev/null   # no waiver is not a failure: the caller chains on this status
}
check selftest_waivers_cases
st_out="$(python3 scripts/provisionador.py --self-test 2>&1)" \
  && { echo "  ok:   provisionador --self-test ($(printf '%s\n' "$st_out" | tail -1))"; selftest_waivers "$st_out"; } \
  || { echo "  FAIL: provisionador --self-test"; printf '%s\n' "$st_out" | tail -25; fail=1; }
hb_out="$(bash host/aps-conecta --self-test 2>&1)" \
  && echo "  ok:   host bundle --self-test ($(printf '%s\n' "$hb_out" | tail -1))" \
  || { echo "  FAIL: host bundle --self-test"; printf '%s\n' "$hb_out" | tail -25; fail=1; }
ib_out="$(bash install.sh --self-test 2>&1)" \
  && echo "  ok:   bootstrap --self-test ($(printf '%s\n' "$ib_out" | tail -1))" \
  || { echo "  FAIL: bootstrap --self-test"; printf '%s\n' "$ib_out" | tail -25; fail=1; }
if command -v signify >/dev/null 2>&1; then
  pr_out="$(bash scripts/package-release.sh --self-test 2>&1)" \
    && echo "  ok:   package-release --self-test ($(printf '%s\n' "$pr_out" | tail -1))" \
    || { echo "  FAIL: package-release --self-test"; printf '%s\n' "$pr_out" | tail -25; fail=1; }
else
  echo "  skipped: package-release --self-test (no signify — sudo apt-get install signify-openbsd)"
fi
# Hermetic image CLI checks use fixture inventories and read-only registry/GitHub shims.
im_out="$(python3 scripts/images.py --self-test 2>&1)" \
  && echo "  ok:   images --self-test ($(printf '%s\n' "$im_out" | tail -1))" \
  || { echo "  FAIL: images --self-test"; printf '%s\n' "$im_out" | tail -25; fail=1; }

echo "== smoke (only if a stack is running) =="
. scripts/env.sh
if is_aio; then
  if bash scripts/smoke.sh; then echo "  ok:   smoke"; else echo "  FAIL: smoke"; fail=1; fi
else
  echo "  skipped: no running AIO stack (static-only gate)"
fi

# Office uses the official connector and its native integrity and connectivity checks.
# Still guarded on the service, not assumed: this script runs in the static CI gate with no stack
# at all, and stopping the office backend is a documented way to reclaim the RAM. `--wait` is what
# makes this deterministic when the stack IS up — without it the gate raced the 120s start_period.
echo "== office smoke (only if the document server is running) =="
# The gate and office-smoke's own inspect match the SAME name — the AIO sibling AIO's own
# containers.json pins (aps-conecta-eurooffice), deterministic on every AIO host — so the two
# cannot drift. The skip is visible, never silent.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aps-conecta-eurooffice; then
  if bash scripts/office-smoke.sh; then echo "  ok:   office-smoke"; else echo "  FAIL: office-smoke"; fail=1; fi
else
  echo "  skipped: no AIO document server (aps-conecta-eurooffice)"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: local gate green"
  exit 0
else
  echo "FAIL: local gate has failures"
  exit 1
fi
