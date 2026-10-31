#!/usr/bin/env python3
"""The container-name re-swap: nextcloud-aio-<x> -> aps-conecta-<x> across the suite (D9).

The rename is committed bytes. An upstream merge that re-introduces a nextcloud-aio-* name
in the swept files re-swaps it here (run from the repo root). Fresh installs only: an existing
instance keeps its nextcloud-aio-* containers and is reinstalled, never migrated.

The names come from the data: every container_name in php/containers.json (14, the floor),
never from a list typed here. Kept by design, so never in the data swept: the
mastercontainer (the host CLI's docker run names it), the nextcloud-aio network and compose
project, the nextcloud_aio_* volumes, the nextcloud-aio app id, the -nextcloud-aio borg archive suffix.

Its verify is the outcome: an old name left in the swept files, or a pattern rewrite that did not land
exactly as counted, exits 1. Idempotent: a run over the committed tree renames nothing and verifies.
"""

import json
import pathlib
import re
import sys

OLD, NEW = "nextcloud-aio-", "aps-conecta-"
MIN_SUITE = 14
# the shipped and tested surfaces (#48 removed the helm chart, manual-install and the upstream docs)
SWEEP = (
    "php/containers.json",
    "php/src",
    "php/public",
    "php/templates",
    "php/tests",
    "Containers",
)
# nextcloud-aio-<...> tokens that stay: anything else left in the sweep is a miss
KEPT = {
    "nextcloud-aio-harp",  # bundled AppAPI's network alias, never the container name
    "nextcloud-aio-mastercontainer",  # the wizard itself (the host CLI's docker run, self-update)
    "nextcloud-aio-mastercontainer-tests",  # php/tests/package.json's npm name
    "nextcloud-aio-test",  # php/tests/compose.yaml's project name
    "nextcloud-aio-rundeps",  # the mastercontainer Dockerfile's apk virtual package
}
# what matches containers by pattern, not by name: (file, before, after, occurrences)
PATTERNS = (
    (
        "Containers/nextcloud/entrypoint.sh",
        'grep -q "nextcloud-.*-eurooffice"',
        'grep -q "aps-conecta-eurooffice"',
        2,
    ),
    (
        "Containers/nextcloud/entrypoint.sh",
        'grep -q "nextcloud-.*-talk"',
        'grep -q "aps-conecta-talk"',
        1,
    ),
    (
        "php/containers-schema.json",
        '"pattern": "^nextcloud-aio-[a-z-]+$"',
        '"pattern": "^aps-conecta-[a-z-]+$"',
        1,
    ),
    (
        "php/containers-schema.json",
        '"pattern": "^nextcloud-aio-[a-z0-9-]+$"',
        '"pattern": "^aps-conecta-[a-z0-9-]+$"',
        1,
    ),
    (
        "php/public/index.php",
        "if (!str_starts_with($id, 'nextcloud-aio-')) {",
        "if (!str_starts_with($id, 'aps-conecta-') && $id !== 'nextcloud-aio-mastercontainer') {",
        1,
    ),
    (
        "php/public/log-load.js",
        "!id.startsWith('nextcloud-aio-')",
        "!(id.startsWith('aps-conecta-') || id === 'nextcloud-aio-mastercontainer')",
        1,
    ),
    (
        "php/src/Controller/DockerController.php",
        "if (str_starts_with($id, 'nextcloud-aio-')) {",
        "if (str_starts_with($id, 'aps-conecta-') || $id === 'nextcloud-aio-mastercontainer') {",
        1,
    ),
    (
        "php/tests/run.sh",
        "nextcloud-aio-{mastercontainer,apache,",
        "nextcloud-aio-mastercontainer aps-conecta-{apache,",
        1,
    ),
    (
        "php/tests/run.sh",
        "for container in nextcloud-aio-{mastercontainer,borgbackup}; do",
        "for container in nextcloud-aio-mastercontainer aps-conecta-borgbackup; do",
        1,
    ),
)


def die(msg):
    sys.exit(f"FATAL: {msg}")


def container_names(path):
    try:
        return [
            c["container_name"]
            for c in json.load(open(path, encoding="utf-8"))["aio_services_v1"]
        ]
    except (OSError, ValueError, KeyError, TypeError) as e:
        die(
            f"{path}: no aio_services_v1 container names ({e}) — the data the names come from moved"
        )


def swept_files():
    for root in SWEEP:
        p = pathlib.Path(root)
        if not p.exists():
            die(
                f"{root} is gone — the sweep would pass over nothing there; fix the generator"
            )
        for f in [p] if p.is_file() else sorted(x for x in p.rglob("*") if x.is_file()):
            if f.suffix == ".md":
                continue  # docs, not runtime: upstream's prose and examples
            try:
                yield f, f.read_text(encoding="utf-8")
            except UnicodeDecodeError:  # binaries (icons, fonts): skipped, so none may name a container
                if OLD.encode() in f.read_bytes():
                    die(f"{f} is not UTF-8 yet carries «{OLD}» — the sweep cannot rewrite it; fix the generator")


def main():
    suite = container_names("php/containers.json")
    names = {n[len(OLD) :] for n in suite if n.startswith(OLD)}
    done = sum(n.startswith(NEW) for n in suite)
    if len(suite) < MIN_SUITE or len(names) + done < MIN_SUITE:
        die(
            f"{len(suite)} container names in php/containers.json, {len(names)} still old — expected at least "
            f"{MIN_SUITE}; a sweep over a shrunken list would be green without looking"
        )

    for path, before, after, count in PATTERNS:
        p = pathlib.Path(path)
        t = p.read_text(encoding="utf-8")
        if t.count(before) == count and t.count(after) == 0:
            p.write_text(t.replace(before, after), encoding="utf-8")
        elif not (t.count(before) == 0 and t.count(after) == count):
            die(
                f"{path}: {t.count(before)}× «{before}», {t.count(after)}× «{after}» — expected {count} of one "
                "and none of the other; the pattern moved, fix the generator"
            )

    renamed = 0
    # longest first, and never a prefix of a longer name: talk is not talk-recording
    if names:
        old = re.compile(
            re.escape(OLD)
            + "("
            + "|".join(sorted(map(re.escape, names), key=len, reverse=True))
            + r")(?![A-Za-z0-9_-])"
        )
        for f, t in swept_files():
            new, n = old.subn(lambda m: NEW + m.group(1), t)
            if n:
                f.write_text(new, encoding="utf-8")
                renamed += n

    left = sorted(
        {
            tok
            for _f, t in swept_files()
            for tok in re.findall(r"nextcloud-aio-[a-z0-9-]*", t)  # a bare prefix counts
        }
        - KEPT
    )
    if left:
        die(
            f"old names left in the swept files: {', '.join(left)} — fix the generator, never the tree"
        )
    final = container_names("php/containers.json")
    if any(not n.startswith(NEW) for n in final) or len(final) < MIN_SUITE:
        die(
            f"php/containers.json: {sum(not n.startswith(NEW) for n in final)} container names not {NEW}*"
        )
    print(
        f"  renamed {renamed} occurrence(s); {len(final)} suite containers are {NEW}*; "
        f"{len(PATTERNS)} name patterns follow; kept: {', '.join(sorted(KEPT))}"
    )


if __name__ == "__main__":
    main()
