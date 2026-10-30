#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build and verify the suite image set from one source tree."""

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = "ghcr.io/aps-conecta"
REPOSITORY = "APS-Conecta/gestion"
SOURCE_URL = "https://github.com/" + REPOSITORY


class ImageError(Exception):
    """A refused image operation, reported once by the command-line boundary."""


@dataclass(frozen=True)
class Image:
    image: str
    dockerfile: str
    context: str
    database_test: bool
    cache: bool


def runtime_services():
    """The fixed running sibling set; backup, domain checking and recording are separate."""
    try:
        rows = json.loads((ROOT / "php/containers.json").read_text())["aio_services_v1"]
        names = [row["container_name"] for row in rows if row["container_name"] not in {
            "aps-conecta-borgbackup", "aps-conecta-domaincheck", "aps-conecta-talk-recording"}]
        if not names or len(names) != len(set(names)) or "aps-conecta-nextcloud" not in names or any(
            not re.fullmatch(r"aps-conecta-[a-z0-9-]+", name) for name in names
        ):
            raise ValueError("invalid running service set")
        return names
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ImageError(f"cannot read the running service inventory: {exc}") from exc


def inventory():
    try:
        services = json.loads((ROOT / "php/containers.json").read_text())["aio_services_v1"]
        if not isinstance(services, list) or not services:
            raise ImageError("the suite container inventory is empty or invalid")
        names = []
        for service in services:
            ref = service["image"]
            if not isinstance(ref, str) or not re.fullmatch(
                re.escape(REGISTRY) + r"/aio-[a-z0-9]+(?:-[a-z0-9]+)*", ref
            ):
                raise ImageError(f"unsupported suite image: {ref!r}")
            names.append(ref.rsplit("/", 1)[-1])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ImageError(f"cannot read the suite container inventory: {exc}") from exc
    names.append("all-in-one")
    if len(names) != len(set(names)):
        raise ImageError("duplicate images in the suite container inventory")

    images = []
    for name in names:
        directory = "mastercontainer" if name == "all-in-one" else name.removeprefix("aio-")
        dockerfile = f"Containers/{directory}/Dockerfile"
        if not (ROOT / dockerfile).is_file():
            raise ImageError(f"missing Dockerfile for {name}: {dockerfile}")
        context = "." if name in {"all-in-one", "aio-nextcloud", "aio-apache"} else f"Containers/{directory}"
        images.append(Image(name, dockerfile, context, name == "aio-postgresql", name != "aio-eurooffice"))

    found = {str(path.relative_to(ROOT)) for path in (ROOT / "Containers").glob("*/Dockerfile")}
    extra = found - {image.dockerfile for image in images}
    if extra:
        raise ImageError("Dockerfiles without a suite image: " + ", ".join(sorted(extra)))
    return images


def validate_tag(tag):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", tag) or tag.lower().startswith("latest"):
        raise ImageError(f"not a versioned suite image tag: {tag!r}")


def command(args, timeout=60):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ImageError(f"cannot run {args[0]}: {exc}") from exc


def github_get(route):
    result = command(["gh", "api", "--include", route], timeout=30)
    headers, separator, body = result.stdout.partition("\n\n")
    status = re.match(r"HTTP/\S+\s+(\d{3})(?:\s|$)", headers)
    if not separator or status is None:
        raise ImageError(f"GitHub returned no usable HTTP response for {route}")
    try:
        data = json.loads(body)
    except ValueError as exc:
        raise ImageError(f"GitHub returned invalid JSON for {route}") from exc
    if not isinstance(data, dict):
        raise ImageError(f"GitHub returned an invalid response for {route}")
    code = int(status.group(1))
    if code == 404 and result.returncode == 1 and data.get("message") == "Not Found":
        return code, data
    if code != 200 or result.returncode != 0:
        raise ImageError(f"GitHub refused {route} (HTTP {code}); publication is not permitted")
    return code, data


def image_digest(image, tag, allow_missing=False):
    ref = f"{REGISTRY}/{image.image}:{tag}"
    result = command(["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .Manifest}}"])
    if result.returncode != 0:
        if allow_missing and result.stderr.strip().endswith((": not found", ": manifest unknown")):
            return None
        raise ImageError(f"cannot inspect {ref}: {result.stderr.strip()}")
    try:
        digest = json.loads(result.stdout)["digest"]
    except (ValueError, KeyError, TypeError) as exc:
        raise ImageError(f"registry returned no image digest for {ref}") from exc
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        raise ImageError(f"registry returned an invalid digest for {ref}")
    return digest


def preflight(tag, force):
    validate_tag(tag)
    images = inventory()
    # A successful authenticated repository lookup distinguishes a missing release
    # from a repository/authentication failure masked as 404.
    status, repo = github_get(f"repos/{REPOSITORY}")
    repo_name = repo.get("full_name")
    if status != 200 or not isinstance(repo_name, str) or repo_name.lower() != REPOSITORY.lower():
        raise ImageError("cannot establish access to the suite repository")
    status, release = github_get(f"repos/{REPOSITORY}/releases/tags/{tag}")
    if status == 200:
        if not isinstance(release.get("draft"), bool):
            raise ImageError("GitHub returned no valid Release publication state")
        if not release["draft"]:
            raise ImageError(f"{tag} has a published Release; rebuilding is refused, including with force")
    present = sum(image_digest(image, tag, allow_missing=True) is not None for image in images)
    if present == len(images) and not force:
        raise ImageError(f"all {present} images already exist at {tag}; use force only for an unpublished rehearsal or repair")
    print(f"preflight: {tag} is unpublished; {present}/{len(images)} images present; source builds permitted")


def published_images(tag, sha):
    validate_tag(tag)
    if not re.fullmatch(r"[a-f0-9]{40}", sha):
        raise ImageError("the source revision must be one full Git commit SHA")
    digests = {}
    for image in inventory():
        digest = image_digest(image, tag)
        ref = f"{REGISTRY}/{image.image}@{digest}"
        result = command(["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .Image}}"])
        if result.returncode != 0:
            raise ImageError(f"cannot inspect the published config for {ref}: {result.stderr.strip()}")
        try:
            labels = json.loads(result.stdout)["config"]["Labels"]
        except (ValueError, KeyError, TypeError) as exc:
            raise ImageError(f"registry returned no source labels for {ref}") from exc
        if not isinstance(labels, dict):
            raise ImageError(f"registry returned invalid source labels for {ref}")
        for key, expected in [("org.opencontainers.image.source", SOURCE_URL), ("org.opencontainers.image.revision", sha)]:
            if labels.get(key) != expected:
                raise ImageError(f"{image.image} has the wrong {key}; the published set is not the requested source tree")
        digests[image.image] = digest
    return digests


def rewrite_registry(filename):
    path = Path(filename)
    try:
        text = path.read_text().replace("ghcr.io/nextcloud-releases/", REGISTRY + "/")
        if "ghcr.io/nextcloud-releases" in text:
            raise ImageError(f"{path} contains an unsupported upstream registry reference")
        path.write_text(text)
    except OSError as exc:
        raise ImageError(f"cannot rewrite {path}: {exc}") from exc
    expected = len(inventory()) - 1  # The mastercontainer is not a containers.json sibling.
    if text.count(REGISTRY + "/") != expected:
        raise ImageError(f"{path} does not carry the suite's {expected} sibling image references")
    print(f"registry rewritten: {expected} sibling image references; channel placeholders preserved")


def self_test():
    checks = 0
    with tempfile.TemporaryDirectory(prefix="suite-images-") as tmp:
        root = Path(tmp)
        (root / "scripts").mkdir()
        script = root / "scripts/images.py"
        shutil.copyfile(__file__, script)
        (root / "php").mkdir()
        names = ["aio-postgresql", "aio-eurooffice", "aio-nextcloud", "aio-apache"]
        definition = root / "php/containers.json"
        data = {"aio_services_v1": [{"image": f"{REGISTRY}/{name}", "image_tag": "%AIO_CHANNEL%",
                                  "container_name": "aps-conecta-" + ("database" if name == "aio-postgresql" else name.removeprefix("aio-"))} for name in names]}
        definition.write_text(json.dumps(data))
        for directory in ["postgresql", "eurooffice", "nextcloud", "apache", "mastercontainer"]:
            path = root / "Containers" / directory
            path.mkdir(parents=True)
            (path / "Dockerfile").write_text("FROM scratch\n")
        bin_dir = root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
route = sys.argv[-1]
case = os.environ.get("IMAGE_TEST_GITHUB", "absent")
if case == "network":
    print("connection failed", file=sys.stderr)
    sys.exit(1)
status = 200
if route == "repos/APS-Conecta/gestion":
    body = {"full_name": [] if case == "bad-repository" else "APS-Conecta/gestion"}
    if case == "repository-404":
        status, body = 404, {"message": "Not Found"}
elif case in {"forbidden", "rate-limit"}:
    status, body = 403, {"message": "access refused"}
elif case == "server-error":
    status, body = 500, {"message": "server error"}
elif case == "absent":
    status, body = 404, {"message": "Not Found"}
elif case == "bad-404":
    status, body = 404, {"message": "unknown refusal"}
elif case == "missing-state":
    body = {"tag_name": "v0.5.0"}
else:
    body = {"draft": case == "draft", "prerelease": case == "prerelease"}
text = "{" if case == "bad-json" and route != "repos/APS-Conecta/gestion" else json.dumps(body)
print(f"HTTP/2.0 {status} response\\nContent-Type: application/json\\n\\n" + text)
sys.exit(0 if status == 200 else 1)
''')
        gh.chmod(0o700)
        docker = bin_dir / "docker"
        docker.write_text('''#!/usr/bin/env python3
import hashlib, json, os, sys
with open(os.environ["IMAGE_TEST_CALLS"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:4] != ["buildx", "imagetools", "inspect"]:
    print("registry mutation attempted", file=sys.stderr)
    sys.exit(91)
ref, fmt = sys.argv[4], sys.argv[-1]
case = os.environ.get("IMAGE_TEST_REGISTRY", "absent")
name = ref.rsplit("/", 1)[-1].split("@")[0].split(":")[0]
if case == "network":
    print("registry connection failed", file=sys.stderr)
    sys.exit(1)
if case == "absent" or (case == "missing-one" and name == "aio-eurooffice"):
    print(f"ERROR: {ref}: not found", file=sys.stderr)
    sys.exit(1)
if "Manifest" in fmt:
    digest = "invalid" if case == "bad-digest" else "sha256:" + hashlib.sha256(name.encode()).hexdigest()
    print(json.dumps({"digest": digest}))
elif case == "bad-config":
    print("{")
else:
    labels = {"org.opencontainers.image.source": "https://github.com/APS-Conecta/gestion",
              "org.opencontainers.image.revision": "a" * 40}
    if case == "wrong-source": labels["org.opencontainers.image.source"] = "https://example.invalid/other"
    if case == "wrong-revision": labels["org.opencontainers.image.revision"] = "b" * 40
    if case == "missing-labels": labels = None
    print(json.dumps({"config": {"Labels": labels}}))
''')
        docker.chmod(0o700)
        calls = root / "registry-calls"
        def invoke(name, *args, success=True, github="absent", registry="absent", needle=None):
            nonlocal checks
            calls.unlink(missing_ok=True)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       IMAGE_TEST_CALLS=str(calls), IMAGE_TEST_GITHUB=github,
                       IMAGE_TEST_REGISTRY=registry)
            result = subprocess.run([sys.executable, str(script), *args], env=env,
                                    capture_output=True, text=True, timeout=10)
            assert (result.returncode == 0) == success, f"{name}: {result.stdout}{result.stderr}"
            if not success:
                assert "FATAL:" in result.stderr, f"{name}: refusal was not reported: {result.stderr}"
            if needle:
                assert needle in result.stderr, f"{name}: {result.stderr}"
            checks += 1
            return result

        matrix = json.loads(invoke("matrix", "build-matrix").stdout)["include"]
        assert {row["image"] for row in matrix} == {*names, "all-in-one"} and len(matrix) == 5
        assert {row["image"] for row in matrix if row["context"] == "."} == {"aio-nextcloud", "aio-apache", "all-in-one"}
        assert {row["image"] for row in matrix if row["database_test"]} == {"aio-postgresql"}
        assert {row["image"] for row in matrix if not row["cache"]} == {"aio-eurooffice"}
        assert set(invoke("list", "list").stdout.splitlines()) == {*names, "all-in-one"}
        definition.write_text(json.dumps({"aio_services_v1": data["aio_services_v1"] * 2}))
        invoke("duplicate inventory", "build-matrix", success=False)
        definition.write_text(json.dumps(data))
        missing = root / "Containers/postgresql/Dockerfile"
        missing.rename(missing.with_suffix(".saved"))
        invoke("missing Dockerfile", "build-matrix", success=False)
        missing.with_suffix(".saved").rename(missing)
        extra = root / "Containers/unregistered"
        extra.mkdir()
        (extra / "Dockerfile").write_text("FROM scratch\n")
        invoke("unregistered Dockerfile", "build-matrix", success=False)
        shutil.rmtree(extra)
        definition.write_text('{"aio_services_v1":[{"image":"ghcr.io/other/aio-example"}]}')
        invoke("foreign image namespace", "build-matrix", success=False)
        definition.write_text(json.dumps(data))

        for github in ["published", "prerelease"]:
            for flags in [[], ["--force"]]:
                invoke("published Release refusal", "preflight", "v0.5.0", *flags,
                       success=False, github=github, registry="present", needle="published Release")
                assert not calls.exists(), "published-tag refusal touched the registry"
        for github in ["network", "forbidden", "rate-limit", "server-error", "bad-json",
                       "missing-state", "repository-404", "bad-repository", "bad-404"]:
            invoke("GitHub failure refuses publication", "preflight", "v0.5.0", "--force",
                   success=False, github=github)
            assert not calls.exists(), "failed publication permission touched the registry"
        for github in ["absent", "draft"]:
            invoke("unpublished target", "preflight", "v0.5.0", github=github)
        invoke("existing complete set", "preflight", "v0.5.0", success=False, registry="present")
        invoke("force unpublished complete set", "preflight", "v0.5.0", "--force", registry="present")
        invoke("partial set repair", "preflight", "v0.5.0", registry="missing-one")
        for registry in ["network", "bad-digest"]:
            invoke("unreadable target", "preflight", "v0.5.0", "--force", success=False, registry=registry)
        for tag in ["latest", "latest-aio", "LATEST-test", "x:y", "../bad", "bad tag"]:
            invoke("invalid image tag", "preflight", tag, success=False)
            assert not calls.exists(), "invalid tag touched the registry"

        selected = invoke("fixed services", "runtime-services").stdout.split()
        assert selected == ["aps-conecta-database", "aps-conecta-eurooffice", "aps-conecta-nextcloud"]
        with_exclusions = {"aio_services_v1": data["aio_services_v1"] + [
            {"container_name": "aps-conecta-" + name} for name in ("borgbackup", "domaincheck", "talk-recording")]}
        definition.write_text(json.dumps(with_exclusions))
        assert invoke("non-running services excluded", "runtime-services").stdout.split() == selected
        definition.write_text(json.dumps({"aio_services_v1": data["aio_services_v1"] * 2}))
        invoke("duplicate running service", "runtime-services", success=False)
        definition.write_text('{"aio_services_v1":[{"container_name":"aps-conecta-talk"}]}')
        invoke("missing Nextcloud service", "runtime-services", success=False)
        definition.write_text(json.dumps(data))
        sha = "a" * 40
        invoke("published source verification", "verify", "v0.5.0", "--sha", sha, registry="present")
        for registry in ["missing-one", "network", "bad-digest", "bad-config", "wrong-source", "wrong-revision", "missing-labels"]:
            invoke("invalid published set", "verify", "v0.5.0", "--sha", sha, success=False, registry=registry)
        invoke("invalid source SHA", "verify", "v0.5.0", "--sha", "main", success=False)
        record = json.loads(invoke("manifest", "manifest", "v0.5.0", "--sha", sha,
                                   "--ref", "v0.5.0", registry="present").stdout)
        assert record["built_from"] == {"ref": "v0.5.0", "sha": sha}
        assert record["suite_tag"] == "v0.5.0" and set(record["images"]) == {*names, "all-in-one"}
        assert "retag_source" not in record

        definition.write_text(json.dumps(data).replace(REGISTRY + "/", "ghcr.io/nextcloud-releases/"))
        invoke("registry rewrite", "rewrite-registry", str(definition))
        rewritten = definition.read_text()
        assert "%AIO_CHANNEL%" in rewritten and "nextcloud-releases" not in rewritten
        invoke("idempotent registry rewrite", "rewrite-registry", str(definition))
        assert definition.read_text() == rewritten
    print(f"self-test: {checks} image checks OK")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("list")
    commands.add_parser("build-matrix")
    publish = commands.add_parser("preflight")
    publish.add_argument("tag")
    publish.add_argument("--force", action="store_true")
    for name in ["verify", "manifest"]:
        sub = commands.add_parser(name)
        sub.add_argument("tag")
        sub.add_argument("--sha", required=True)
        if name == "manifest":
            sub.add_argument("--ref", required=True)
    commands.add_parser("runtime-services")
    rewrite = commands.add_parser("rewrite-registry")
    rewrite.add_argument("file")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.command == "runtime-services":
        print(" ".join(runtime_services()))
        return
    if args.command == "preflight":
        preflight(args.tag, args.force)
        return
    if args.command == "rewrite-registry":
        rewrite_registry(args.file)
        return
    if args.command in {"verify", "manifest"}:
        digests = published_images(args.tag, args.sha)
        if args.command == "verify":
            print(f"verified: {len(digests)} images built from {args.sha}")
        else:
            if not args.ref:
                raise ImageError("the source ref must be recorded in the manifest")
            print(json.dumps({"suite_tag": args.tag, "built_from": {"ref": args.ref, "sha": args.sha},
                              "images": digests}, indent=2))
        return
    if args.command is None:
        parser.error("choose a command or --self-test")
    images = inventory()
    if args.command == "list":
        print("\n".join(image.image for image in images))
    else:
        print(json.dumps({"include": [asdict(image) for image in images]}, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except ImageError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        sys.exit(1)
