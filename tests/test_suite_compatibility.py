"""Exercise compatibility diagnostics through the command-line Docker boundary."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "VERSION").write_text("v9.9.9\n")
        self.docker = self.root / "docker"
        self.docker.write_text("#!" + sys.executable + "\n" + '''
import json, os, sys, time
args = sys.argv[1:]
if args[0] == 'inspect':
    print(json.dumps('ghcr.io/aps-conecta/all-in-one:v0.6.0') + '\\t' + os.environ.get('RUNNING', 'true'))
    sys.exit(int(os.environ.get('INSPECT_EXIT', '0')))
assert args[0] == 'exec', 'Compatibility must not mutate Docker state'
time.sleep(float(os.environ.get('PROBE_SLEEP', '0')))
print('synthetic confidential Docker detail', file=sys.stderr)
if os.environ.get('PROBE_EXIT') == '42':
    print('aps-incompatible')
sys.exit(int(os.environ.get('PROBE_EXIT', '0')))
''')
        self.docker.chmod(0o755)

    def run_check(self, capability="wizard", **settings):
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/suite_compatibility.py"), capability, "--root", str(self.root)],
            env=dict(os.environ, PATH=str(self.root) + ":" + os.environ["PATH"], **settings),
            capture_output=True, text=True, timeout=20,
        )

    def test_supported_capability_accepts_different_version_labels(self):
        result = self.run_check()
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_proven_missing_capability_names_both_versions_and_preserves_data(self):
        for capability in ("wizard", "provision"):
            result = self.run_check(capability, PROBE_EXIT="42")
            self.assertEqual(result.returncode, 1)
            for text in ("no corresponde a este instalador", "v0.6.0", "v9.9.9", "conserve los datos"):
                self.assertIn(text, result.stdout)
            self.assertNotIn("confidential", result.stdout + result.stderr)

    def test_unknown_evidence_does_not_claim_incompatibility(self):
        for settings in ({"INSPECT_EXIT": "1"}, {"PROBE_EXIT": "1"}, {"PROBE_EXIT": "126"},
                         {"PROBE_EXIT": "2"}, {"RUNNING": "false"}, {"RUNNING": "invalid"}):
            with self.subTest(settings=settings):
                result = self.run_check(**settings)
                self.assertEqual(result.returncode, 2)
                self.assertIn("no se pudo comprobar", result.stdout)
                self.assertNotIn("no corresponde a este instalador", result.stdout)
                self.assertNotIn("confidential", result.stdout + result.stderr)

    def test_hung_execution_is_bounded_and_unverifiable(self):
        result = self.run_check(PROBE_SLEEP="30")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no se pudo comprobar", result.stdout)


if __name__ == "__main__":
    unittest.main()
