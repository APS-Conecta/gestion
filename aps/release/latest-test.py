#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The "Latest" rules' self-test: latest.py's command line against what GitHub shows after a publish."""

import subprocess
import sys
import unittest
from pathlib import Path

CHECK = Path(__file__).resolve().parent / "latest.py"
# Today's releases: a legacy "Latest" with a suffix, two finals and a test build.
PUBLISHED = ["v0.6.0-ci.2032", "v0.0.0-ci.2031", "v0.5.0", "v0.4.0"]


def check(tag, before, after, published):
    """latest.py's verdict on "Latest" naming <after> once <tag> is published; it named <before>."""
    run = subprocess.run([sys.executable, "-I", str(CHECK), tag, before, after, *published],
                         capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


class LatestRules(unittest.TestCase):
    def test_a_suffixed_tag_offered_as_latest_goes_red(self):
        for tag in ("v1.0.0-rc.1", "v0.0.0-ci.2035"):
            with self.subTest(tag=tag):
                code, out = check(tag, "v0.6.0-ci.2032", tag, PUBLISHED)
                self.assertEqual(code, 1, out)
                self.assertIn(tag, out)

    def test_an_older_final_release_replacing_a_newer_one_goes_red(self):
        code, out = check("v1.0.1", "v1.1.0", "v1.0.1", ["v1.1.0", "v1.0.0", *PUBLISHED])
        self.assertEqual(code, 1, out)
        self.assertIn("v1.0.1", out)

    def test_a_pre_release_leaves_latest_where_it_was(self):
        for tag in ("v1.0.0-rc.1", "v0.0.0-ci.2035"):
            with self.subTest(tag=tag):
                code, out = check(tag, "v0.6.0-ci.2032", "v0.6.0-ci.2032", PUBLISHED)
                self.assertEqual(code, 0, out)

    def test_an_older_final_release_leaves_latest_where_it_was(self):
        code, out = check("v1.0.1", "v1.1.0", "v1.1.0", ["v1.1.0", "v1.0.0", *PUBLISHED])
        self.assertEqual(code, 0, out)

    def test_the_highest_final_version_becomes_latest(self):
        code, out = check("v1.0.0", "v0.6.0-ci.2032", "v1.0.0", PUBLISHED)
        self.assertEqual(code, 0, out)

    def test_the_highest_final_version_left_out_of_latest_goes_red(self):
        code, out = check("v1.0.0", "v0.6.0-ci.2032", "v0.6.0-ci.2032", PUBLISHED)
        self.assertEqual(code, 1, out)
        self.assertIn("v1.0.0", out)

    def test_a_tag_that_is_not_a_version_goes_red_without_a_traceback(self):
        code, out = check("1.0.0", "v0.6.0-ci.2032", "v0.6.0-ci.2032", PUBLISHED)
        self.assertNotEqual(code, 0, out)
        self.assertIn("1.0.0", out)
        self.assertNotIn("Traceback", out)


if __name__ == "__main__":
    unittest.main()
