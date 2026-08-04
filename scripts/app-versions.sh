#!/usr/bin/env bash
# Has any vendored app released a newer version? (#117)
#
# It asks the app store, and that is fine: #98 kept the store out of the INSTALL path, where a failure
# leaves an instance half-built. Reading a version number in CI risks nothing.
#
# REPORTS ONLY. Bumping is an edit — new tarball, new VENDOR lines — and deliberately not automated:
# a tarball swap changes what every clinic runs, and it goes through a PR where `cleanboot` boots it.
# See provisioning/lib.sh (`ensure_vendored_app`) for what an install then does with it.
set -uo pipefail
cd "$(dirname "$0")/.."

# Platform-scoped, so "newest" already means "newest that runs on NC34" — the unscoped index would
# happily report a release that requires NC35 and send someone chasing an upgrade that cannot apply.
INDEX="https://apps.nextcloud.com/api/v1/platform/34.0.0/apps.json"

# OUR OWN APPS ARE NOT IN THE STORE AND NEVER WILL BE (ADR-0003). They are vendored the same way
# and so they have a VENDOR file, but asking the store about `epidemiologia` gets "not in the NC34
# store index at all" and this script exits 1 — which it did, on every run, from the moment the app
# was vendored. The list is READ OUT OF PHASE 12 rather than restated here, the same way
# scripts/divergence.sh reads both inventories, so declaring a second app of ours needs no edit
# to this file.
own="$(sed -n 's/^OWN_APPS="\(.*\)"/\1/p' provisioning/phases/12-apps.sh | tr ' ' '\n' | sed 's/=.*//' | grep -v '^$' || true)"

vendored="$(for v in provisioning/apps/*/VENDOR; do
  [ -f "$v" ] || continue
  id="$(basename "$(dirname "$v")")"
  # grep -x against a possibly-empty list: -q with an empty pattern file matches nothing, which is
  # the behaviour we want before the first own app is declared.
  printf '%s\n' "$own" | grep -qxF -- "$id" && continue
  printf '%s\t%s\n' "$id" "$(sed -n 's/^version=//p' "$v")"
done)"
[ -n "$vendored" ] || { echo "FATAL: no provisioning/apps/*/VENDOR files found" >&2; exit 1; }

# ~5.4 MB and slow (~60 s here) because the store publishes NO per-app endpoint — /api/v1/apps/<id>
# returns 500. Weekly in CI, so the cost is paid once a week by a robot.
json="$(curl -sS --max-time 300 "$INDEX")" \
  || { echo "FATAL: could not fetch the app store index" >&2; exit 1; }

printf '%s' "$json" | python3 -c '
import sys, json
from itertools import zip_longest

want = dict(line.split("\t") for line in sys.argv[1].splitlines() if line)
try:
    apps = json.load(sys.stdin)
except Exception:
    print("FATAL: app store index was not JSON", file=sys.stderr); raise SystemExit(1)

def key(v):
    # Numeric compare, so 6.0.10 sorts above 6.0.9 where a string compare would not. Non-numeric
    # pre-release suffixes sort below any release of the same number, which is what we want.
    out = []
    for part in v.split("."):
        num = "".join(c for c in part if c.isdigit())
        out.append((int(num) if num else 0, part[len(num):] == ""))
    return out

seen, behind = set(), 0
for a in apps:
    if a["id"] not in want:
        continue
    seen.add(a["id"])
    have = want[a["id"]]
    releases = [r["version"] for r in a.get("releases", []) if not r.get("isNightly") and "-" not in r["version"]]
    newest = max(releases, key=key) if releases else have
    aid = a["id"]
    if key(newest) > key(have):
        behind += 1
        print(f"  ~ {aid}  vendored {have}  ->  {newest} available")
    else:
        print(f"  = {aid}  {have}")

for missing in sorted(set(want) - seen):
    behind += 1
    print(f"  ? {missing}  vendored {want[missing]} — not in the NC34 store index at all; "
          f"has it been renamed, unpublished, or dropped NC34 support?")

if behind:
    print(f"""
{behind} vendored app(s) are behind the store. Nothing was changed, and no clinic is affected —
an install only ever unpacks what is committed here.

  To take a new version:
    1. download the release from the url= line in provisioning/apps/<id>/VENDOR
    2. replace the tarball, update version= and sha256=
    3. make seed        — the patches either still apply or the phase says which one moved
    4. open a PR; cleanboot boots it before it can merge""", file=sys.stderr)
    raise SystemExit(1)
print("every vendored app is the newest the NC34 store offers")
' "$vendored"
