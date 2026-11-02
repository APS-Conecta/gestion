"""Exercise routing reconciliation through its Docker and timer boundaries."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
CLIENTS = ("aps-conecta-nextcloud", "aps-conecta-talk", "aps-conecta-harp")


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.configuration = self.root / "configuration.json"
        self.configuration.write_text(json.dumps({"domain": "198.18.0.1"}))
        self.state = self.root / "state.json"
        self.calls = self.root / "calls.jsonl"
        self.state.write_text(json.dumps({"round": 0, "stop": 1, "actions": {}, "fail": False,
            "proxy": "172.30.11.2", "started": "2026-11-02T00:00:00Z", "id": "a" * 64}))
        stub = '''
import json, os, pathlib, sys
path = pathlib.Path(os.environ['ROUTING_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
if pathlib.Path(sys.argv[0]).name == 'sleep':
    state['round'] += 1
    state.update(state['actions'].get(str(state['round']), {}))
    path.write_text(json.dumps(state))
    sys.exit(99 if state['round'] >= state['stop'] else 0)
if args[0] == 'inspect':
    if args[-1] == 'nextcloud-aio-mastercontainer':
        print('sha256:' + 'e' * 64)
    else:
        name = args[-1]
        ids = {'aps-conecta-nextcloud': state['id'], 'aps-conecta-talk': 'b' * 64,
               'aps-conecta-harp': 'c' * 64, 'aps-conecta-apache': 'd' * 64}
        started = state['started'] if name == 'aps-conecta-nextcloud' else 'initial'
        address = state['proxy'] if name == 'aps-conecta-apache' else '172.30.11.3'
        print(ids[name] + '|true|' + started + '|' + address)
    sys.exit(0)
assert args[0] == 'run'
with open(os.environ['ROUTING_CALLS'], 'a') as log:
    log.write(json.dumps({'round': state['round'], 'argv': args}) + '\\n')
if state['fail']:
    state['fail'] = False
    path.write_text(json.dumps(state))
    sys.exit(1)
'''
        for name in ("docker", "sleep"):
            executable = self.root / name
            executable.write_text("#!" + sys.executable + "\n" + stub)
            executable.chmod(0o755)

    def run_routing(self, mode="once", **state):
        current = json.loads(self.state.read_text())
        current.update(state)
        self.state.write_text(json.dumps(current))
        result = subprocess.run(["bash", str(ROOT / "Containers/mastercontainer/ip-routing.sh"),
                                 mode, str(self.configuration)], capture_output=True, text=True,
                                timeout=10, env=dict(os.environ,
                                    PATH=str(self.root) + ":" + os.environ["PATH"],
                                    ROUTING_STATE=str(self.state), ROUTING_CALLS=str(self.calls)))
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, calls

    def test_domain_installation_launches_no_routing_helper(self):
        self.configuration.write_text('{"domain":"suite.example.org"}')
        result, calls = self.run_routing()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_helpers_are_confined_to_client_namespaces_and_installed_image(self):
        result, calls = self.run_routing()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 3)
        for call, letter in zip(calls, "abc"):
            args = call["argv"]
            self.assertEqual(args[args.index("--network") + 1], "container:" + letter * 64)
            self.assertEqual(args[args.index("--cap-drop") + 1], "ALL")
            self.assertEqual(args[args.index("--cap-add") + 1], "NET_ADMIN")
            self.assertIn("--read-only", args)
            self.assertIn("no-new-privileges", args)
            self.assertIn("--pull=never", args)
            self.assertIn("sha256:" + "e" * 64, args)
            self.assertEqual(args[-3:], ["apply", "198.18.0.1", "172.30.11.2"])
            self.assertFalse(any(a.startswith(("--privileged", "--volume", "--mount")) for a in args))

    def test_restart_recreation_and_proxy_address_changes_reconcile(self):
        result, calls = self.run_routing("watch", stop=5, actions={
            "2": {"started": "restarted"}, "3": {"proxy": "172.30.11.9"}, "4": {"id": "f" * 64}})
        self.assertEqual(result.returncode, 99)
        self.assertEqual([sum(call["round"] == n for call in calls) for n in range(5)], [3, 0, 1, 3, 1])
        self.assertEqual(calls[-1]["argv"][-1], "172.30.11.9")

    def test_failed_helper_is_retried_without_recording_success(self):
        result, calls = self.run_routing("watch", stop=2, fail=True)
        self.assertEqual(result.returncode, 99)
        self.assertEqual([call["round"] for call in calls], [0, 1, 1, 1])
        self.assertIn("se reintentará", result.stderr)


if __name__ == "__main__":
    unittest.main()
