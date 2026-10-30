#!/usr/bin/env bash
# The validator — upstream's own three (codespell, docker-lint/hadolint, json-spec against
# containers-schema.json), hermetic venv, against ANY tree directory. The sole survivor of
# the replay engine (its cmd_validate), re-homed with the hard fork (D-rev 2026-10-19,
# Stage 3): upstream's own validator workflows never fire on tag pushes, so the release
# chain's inline gates arm (release.yml) runs this against the tag tree — ci.yml's gates
# job and upstream's own workflows cover push/PR. twig-lint is not here: it needs PHP
# 8.5 + apcu, so it rides the workflow's own setup-php step beside this script.
#
# Usage: scripts/validate.sh [--docker-lint] TREE     (TREE = the tree to validate, e.g. . — the checkout)
set -uo pipefail

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

die() { echo "FATAL: $*" >&2; exit 1; }

docker_only=0
if [ "${1:-}" = --docker-lint ]; then docker_only=1; shift; fi
tree="${1:?usage: scripts/validate.sh [--docker-lint] TREE (the tree to validate, e.g. .)}"
[ -d "$tree" ] || die "no tree at '$tree'"
if [ "$docker_only" -eq 0 ]; then
  venv="$TMPD/venv"
  python3 -m venv "$venv" || die "cannot create the validator venv (PEP 668 — everything installs in here, never the system python)"
  "$venv/bin/pip" install --quiet codespell json-spec || die "cannot install codespell+json-spec"

  echo "== codespell (upstream's own flags — the es-CL strings of patch 060 ride this gate too) =="
  "$venv/bin/codespell" --check-filenames --check-hidden "$tree" \
    || { echo "VALIDATE: codespell FAIL — a misspelling entered the tree (upstream's own tree passes this)" >&2; exit 1; }
fi

echo "== docker-lint (hadolint, upstream's own ignores — patches 020/030 edit this Dockerfile) =="
bash "$(dirname "$0")/ci-tool.sh" hadolint "$TMPD/hadolint" || die "cannot acquire the pinned Dockerfile linter"
: > "$TMPD/hadolint.log"
find "$tree/Containers" -name "*Dockerfile" -print > "$TMPD/dockerfiles" || die "cannot enumerate Dockerfiles"
[ -s "$TMPD/dockerfiles" ] || die "no Dockerfiles to validate"
while IFS= read -r f; do
  if ! "$TMPD/hadolint" "$f" --ignore DL3018 --ignore DL3041 --ignore DL3066 | tee -a "$TMPD/hadolint.log"; then
    die "hadolint could not validate $f"
  fi
done < "$TMPD/dockerfiles"
if [ -s "$TMPD/hadolint.log" ]; then
  echo "VALIDATE: docker-lint FAIL — hadolint findings above (upstream's own tree passes this)" >&2
  exit 1
fi

if [ "$docker_only" -eq 1 ]; then
  echo "VALIDATE: PASS — Dockerfile lint green against $tree"
  exit 0
fi

echo "== json-validator (json-spec, upstream's exact commands — 010 edits containers.json) =="
if ! "$venv/bin/json" validate --schema-file="$tree/php/containers-schema.json" --document-file="$tree/php/containers.json"; then
  echo "VALIDATE: json FAIL — containers.json no longer validates against upstream's schema" >&2
  exit 1
fi
echo "VALIDATE: PASS — codespell, docker-lint, json-validator green against $tree (twig-lint rides the workflow's PHP step)"
