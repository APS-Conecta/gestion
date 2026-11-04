#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Keep-list check's self-test: its command line against throwaway repos that plant differences."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).resolve().parent / "keep-list.py"


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class Repo:
    """A throwaway repo: an Upstream commit tagged v0.0.1, then this repo's changes on top."""

    def __init__(self, files):
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name)
        git(self.path, "init", "-q")
        git(self.path, "config", "user.email", "test@example.invalid")
        git(self.path, "config", "user.name", "test")
        self.write(files)
        self.base = self.commit()
        git(self.path, "tag", "v0.0.1")

    def write(self, files):
        for name, text in files.items():
            path = self.path / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def delete(self, name):
        git(self.path, "rm", "-q", name)

    def commit(self):
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", "x")
        return git(self.path, "rev-parse", "HEAD")

    def keep_list(self, *entries, base=None):
        lines = [f"# base: {base or self.base} upstream fixture v0.0.1", *entries, "aps/ our layer"]
        self.write({"aps/keep-list.txt": "\n".join(lines) + "\n"})

    def check(self):
        run = subprocess.run([sys.executable, "-I", str(CHECK), "--repo", str(self.path), "--upstream", str(self.path)],
                             capture_output=True, text=True)
        return run.returncode, run.stdout + run.stderr

    def close(self):
        self._tmp.cleanup()


class KeepListCheck(unittest.TestCase):
    def setUp(self):
        self.repo = Repo({"php/a.php": "a\n", "php/b.php": "b\n", "readme.md": "r\n"})
        self.addCleanup(self.repo.close)

    def test_undeclared_change_to_an_upstream_file_goes_red_naming_it(self):
        self.repo.write({"php/a.php": "changed\n"})
        self.repo.keep_list()
        self.repo.commit()
        code, out = self.repo.check()
        self.assertEqual(code, 1, out)
        self.assertIn("M php/a.php", out)

    def test_upstream_path_absent_here_goes_red_naming_it(self):
        self.repo.delete("php/b.php")
        self.repo.keep_list()
        self.repo.commit()
        code, out = self.repo.check()
        self.assertEqual(code, 1, out)
        self.assertIn("D php/b.php", out)

    def test_differences_declared_by_file_or_directory_entries_pass(self):
        self.repo.write({"php/a.php": "changed\n", "readme.md": "ours\n", "aps/tool.py": "x\n"})
        self.repo.delete("php/b.php")
        self.repo.keep_list("php/ our PHP", "readme.md our front page")
        self.repo.commit()
        code, out = self.repo.check()
        self.assertEqual(code, 0, out)

    def test_entry_that_no_longer_differs_goes_red_as_stale(self):
        self.repo.keep_list("readme.md our front page")
        self.repo.commit()
        code, out = self.repo.check()
        self.assertEqual(code, 1, out)
        self.assertIn("stale Keep-list entries", out)
        self.assertIn("readme.md", out)

    def test_entry_without_a_reason_goes_red(self):
        self.repo.write({"readme.md": "ours\n"})
        self.repo.keep_list("readme.md")
        self.repo.commit()
        code, out = self.repo.check()
        self.assertEqual(code, 1, out)
        self.assertIn("readme.md has no reason", out)

    def test_base_that_is_not_the_named_upstream_tag_goes_red(self):
        self.repo.write({"php/a.php": "changed\n"})
        ours = self.repo.commit()
        self.repo.keep_list("php/a.php our change", base=ours)
        self.repo.commit()
        code, out = self.repo.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"base {ours} is not Upstream tag v0.0.1", out)

    def test_keep_list_without_its_base_header_goes_red(self):
        self.repo.write({"aps/keep-list.txt": "aps/ our layer\n"})
        self.repo.commit()
        code, out = self.repo.check()
        self.assertEqual(code, 1, out)
        self.assertIn("no '# base: <Upstream commit> ... <tag>' header", out)
        self.assertNotIn("Traceback", out)


if __name__ == "__main__":
    unittest.main()
