#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Keep-list check: this repo may differ from Upstream only where aps/keep-list.txt says so.

The Keep-list's header names the Upstream commit and its tag (`# base: <sha> ... <tag>`); the check
asks Upstream itself that the tag points at that commit, so a PR cannot move the base. Every other
line is `<path> <reason>`; a path ending in `/` covers everything under it.
"""

import argparse
import subprocess
import sys
from pathlib import Path

KEEP_LIST = "aps/keep-list.txt"
UPSTREAM = "https://github.com/nextcloud/all-in-one.git"


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def read_keep_list(repo):
    """Return (base, tag, entries, problems)."""
    base, tag, entries, problems = None, None, [], []
    for n, line in enumerate((Path(repo) / KEEP_LIST).read_text().splitlines(), 1):
        if line.startswith("# base:") and len(line.split()) > 3:
            base, tag = line.split()[2], line.split()[-1]
        elif line.strip() and not line.startswith("#"):
            fields = line.split(None, 1)
            entries.append(fields[0])
            if len(fields) < 2:
                problems.append(f"line {n}: {fields[0]} has no reason")
    if not base:
        problems.append("no '# base: <Upstream commit> ... <tag>' header")
    return base, tag, entries, problems


def is_upstream_tag(upstream, tag, base):
    out = git("ls-remote", upstream, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    return base in (line.split("\t")[0] for line in out.splitlines())


def covers(entry, path):
    return path == entry or (entry.endswith("/") and path.startswith(entry))


def problems_in(repo, upstream):
    base, tag, entries, problems = read_keep_list(repo)
    problems = [f"{KEEP_LIST}: {p}" for p in problems]
    if not base:
        return problems
    if not is_upstream_tag(upstream, tag, base):
        return problems + [f"{KEEP_LIST}: base {base} is not Upstream tag {tag} at {upstream}"]
    out = git("-C", repo, "diff", "--name-status", "--no-renames", base, "HEAD")
    changed = [line.split("\t", 1) for line in out.splitlines()]
    undeclared = [f"{status} {path}" for status, path in changed if not any(covers(e, path) for e in entries)]
    stale = [e for e in entries if not any(covers(e, path) for _, path in changed)]
    if undeclared:
        problems.append("differs from Upstream outside the Keep-list:\n  " + "\n  ".join(undeclared))
    if stale:
        problems.append("stale Keep-list entries (no difference from Upstream):\n  " + "\n  ".join(stale))
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--upstream", default=UPSTREAM)
    args = parser.parse_args()
    problems = problems_in(args.repo, args.upstream)
    for problem in problems:
        print("keep-list: " + problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
