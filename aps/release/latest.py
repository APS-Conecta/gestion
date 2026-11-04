#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The "Latest" rules, checked against what GitHub shows once <tag> is published.

A tag with a suffix (v1.0.0-rc.1, v0.0.0-ci.7) is a pre-release and never becomes "Latest". A final version
(v1.0.0) becomes "Latest" only when no published final version is higher, so an older final never replaces a
newer one. Otherwise "Latest" stays where it was. Fails unless <latest after> is the tag these rules give.

Usage: latest.py <tag> <latest before> <latest after> [<published tag>...]
  <latest before>, <latest after>: the tag "Latest" named before and after publishing (empty: none)
  <published tag>: the tags of the other published releases
"""

import re
import sys

VERSION = re.compile(r"v(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?")


def version(tag):
    """(major, minor, patch) and whether the tag has a suffix."""
    match = VERSION.fullmatch(tag)
    if not match:
        raise ValueError(f"{tag!r} is not a vX.Y.Z tag")
    return tuple(int(part) for part in match.group(1, 2, 3)), match.group(4) is not None


def expected_latest(tag, before, published):
    number, suffixed = version(tag)
    if suffixed:
        return before
    finals = [version(other)[0] for other in published if other != tag and not version(other)[1]]
    return tag if all(number > final for final in finals) else before


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    tag, before, after, *published = argv
    try:
        expected = expected_latest(tag, before, published)
    except ValueError as error:
        print(f"latest: {error}")
        return 2
    if after != expected:
        print(f"latest: after publishing {tag}, \"Latest\" is {after or 'no release'}, not {expected or 'no release'}")
        return 1
    print(f"latest: \"Latest\" is {after or 'no release'}, as the rules give after publishing {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
