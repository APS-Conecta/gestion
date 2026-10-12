#!/usr/bin/env bash
# The machine-readable union of everything a gestion release pins (D12).
#
#   scripts/release-manifest.sh --validate  offline form check — runs from test.sh on every PR
#   scripts/release-manifest.sh --check      live drift report — weekly, reports, never bumps
#   scripts/release-manifest.sh --self-test  red-test the detector shapes — runs from test.sh too
#
# The GitHub Release asset is the home; the tree keeps only the tag. WHY A FILE AT ALL: the
# operator's docker run names a suite tag, and "which bytes does that tag mean?" deserves a
# machine-checkable answer — one JSON that unions the VENDOR triples, the register's date, the
# image pins, the data masters, so a future diff answers "what moved between v0.2.0 and v0.3.0"
# without archaeology.
#
# The same doctrine as image-digests, said once more: --validate must be true of every commit;
# --check must NOT gate a PR (a tag moving upstream has nothing to do with the branch); and the
# tag-time emit is RETIRED with gestion's release workflow (D4: instalador's tag is the only
# release identity) — the publish record instalador attaches to its Release (scripts/retag.sh
# manifest, same digest doctrine and format) is where suite_tag consumers read the channel from
# now. gestion keeps exactly what this script still owns: the offline form checker and the live
# drift report. And every category is COUNTED before it is checked — an empty glob is the
# silent-green class, not a pass.
set -uo pipefail
cd "$(dirname "$0")/.."

# --- the detector shapes, single-sourced so --self-test red-tests the bytes --validate runs ------
SHA_PLACEHOLDER_RE='^sha256=<(measured|resolved)'
SHA_HEX_RE='^sha256=[0-9a-f]{64}$'
MIN_VENDOR=10

if [ "${1:-}" = "--self-test" ]; then
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  printf 'sha256=<measured at implement>\n' > "$tmp"
  grep -qE "$SHA_PLACEHOLDER_RE" "$tmp" || { echo "self-test: a placeholder sha256 went undetected" >&2; exit 1; }
  printf 'sha256=%s\n' "$(printf '0%.0s' $(seq 1 64))" > "$tmp"
  grep -qE "$SHA_HEX_RE" "$tmp" || { echo "self-test: a well-formed digest failed the hex shape" >&2; exit 1; }
  printf 'sha256=deadbeef\n' > "$tmp"
  grep -qE "$SHA_HEX_RE" "$tmp" && { echo "self-test: a short sha passed the 64-hex shape" >&2; exit 1; }
  echo "release-manifest self-test: the placeholder and hex detectors both detect"; exit 0
fi

mode="${1:-}"
case "$mode" in
  --validate|--check) ;;
  *) echo "usage: $0 --validate|--check" >&2; exit 2 ;;
esac

# --- the union sources, each counted before checked ---------------------------------------
vendor_files=$(ls provisioning/apps/*/VENDOR 2>/dev/null || true)
n_vendor=$(printf '%s\n' "$vendor_files" | grep -c . || true)
[ "$n_vendor" -ge "$MIN_VENDOR" ] \
  || { echo "FATAL: $n_vendor VENDOR files under provisioning/apps/ — expected at least $MIN_VENDOR; a dir went missing" >&2; exit 1; }
register=$(ls sites/establecimientos-deis-*.csv 2>/dev/null || true)
[ "$(printf '%s\n' "$register" | grep -c .)" -eq 1 ] \
  || { echo "FATAL: expected exactly one sites/establecimientos-deis-*.csv, got: $register" >&2; exit 1; }
register_rows=$(python3 -c 'import csv,sys; print(sum(1 for _ in csv.DictReader(open(sys.argv[1], encoding="utf-8"))))' "$register")
[ "$register_rows" -ge 100 ] \
  || { echo "FATAL: $register holds $register_rows rows — a truncated register is not a register" >&2; exit 1; }

bad_vendor=0
for v in $vendor_files; do
  for k in version sha256 url; do
    grep -q "^$k=." "$v" || { echo "$v: no $k=" >&2; bad_vendor=1; }
  done
  grep -qE "$SHA_HEX_RE" "$v" || { echo "$v: sha256= is not a 64-hex digest" >&2; bad_vendor=1; }
  grep -qE "$SHA_PLACEHOLDER_RE" "$v" && { echo "$v: a placeholder sha256 — UNPINNED is a bug, not a state" >&2; bad_vendor=1; }
done
[ "$bad_vendor" -eq 0 ] || exit 1

masters=$(python3 -c '
import json
m = json.load(open("provisioning/data/packages.json"))["masters"]
assert m, "no masters"
for x in m:
    for k in ("id", "origin", "sha256", "records"):
        assert x.get(k) and not str(x.get(k)).startswith("<"), x.get("id") + ": " + k + " unpinned"
print(len(m))') \
  || { echo "FATAL: the data manifest's masters are not all pinned" >&2; exit 1; }

bash scripts/image-digests.sh --validate >/dev/null \
  || { echo "FATAL: image-digests --validate failed — the manifest unions those pins" >&2; exit 1; }

# --- --validate stops here -----------------------------------------------------------------
[ "$mode" = "--validate" ] && { echo "release-manifest: form ok — $n_vendor apps, $register_rows register rows, $masters masters, images pinned"; exit 0; }

# --- --check: live drift, moved vs unreachable distinguished, never a bump --------------------
# Standalone, --check delegates to image-digests --check and app-versions (the whole drift report
# in one place). From the weekly workflow it runs with --no-delegate, because that workflow ALREADY
# runs those two as its own steps — re-running them here would double the registry inspects (the
# documented rate-limit failure) and re-fetch the ~5.4 MB store index. The masters note is the
# half only this script adds: upstream refresh is the re-record edit, not any check's job.
if [ "$mode" = "--check" ]; then
  if [ "${2:-}" != "--no-delegate" ]; then
    bash scripts/image-digests.sh --check || echo "release-manifest --check: image drift above (reported, not bumped)"
    bash scripts/app-versions.sh || echo "release-manifest --check: app drift above (reported, not bumped)"
  fi
  echo "masters: pinned as recorded — an upstream master that moved is the re-record edit, not this check"
  exit 0
fi
