#!/usr/bin/env bash
# What exists on the instance that the repo no longer declares (#85).
#
# WHY THIS REPORTS INSTEAD OF DELETING. Usage is one install on a clean machine, then updates —
# nothing drifts on its own. A folder or group is "live but undeclared" only because a human
# deliberately edited sites/<slug>/site.sh. So divergence is rare, always intentional, and the
# person who caused it is right there. Against that: deleting automatically means a typo in a data
# file silently destroys a clinic's documents, and there is no backup story in this repo to fall
# back on (parked in #75 until a target host exists). Reporting costs one command run by hand;
# deleting costs documents.
#
# EXIT 0, ALWAYS. A non-zero exit would fail `make install` for the rest of time after a deliberate
# removal, which teaches people either to ignore the check or to stop running updates. Neither is a
# state worth having.
#
# NO WRITE VERBS IN THE OUTPUT. scripts/seed-idempotent.sh greps a seed's log for them, so a report
# line matching one would redden the idempotency gate on an instance that is behaving correctly:
# things are "live but not declared", never "created".
#
# NOT COVERED: users. Deleting one deletes their files, so the classification in #85 makes it
# never-automatic like the rest — but a report needs a DECLARED set to compare against, and beyond
# the standing positions in phase 50 there is not one until the roster lands (#86). Reporting every
# hand-added personal account as divergence would be noise, and noise is how a report stops being
# read. Add users here when #86 gives them a declared set.
set -uo pipefail

# shellcheck source=env.sh
. "$(dirname "$0")/env.sh"
require_site || exit 1
# shellcheck disable=SC1090  # the path is SITE, resolved at run time
. "sites/$SITE/site.sh"

PHASE20=provisioning/phases/20-groups.sh
PHASE12=provisioning/phases/12-apps.sh

# --quiet says nothing at all when there is nothing to say. `make install` uses it so a clean
# install ends clean; `make divergence`, which a person ran ON PURPOSE to ask the question, prints
# the all-clear because silence there is indistinguishable from a broken script.
quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

# Findings are collected, not printed as they are found: the header should not appear above an
# empty list, and every loop here runs in the current shell precisely so this array survives.
notes=()
note() { notes+=("$1"); }

# --- group folders: SITE_FOLDERS is the whole declared set ---
# Deleting one deletes every file inside it, which is why this is the report's headline case and why
# the suggested command is printed for a human to run rather than run here.
live_folders="$(occ groupfolders:list --output=json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in (d.values() if isinstance(d, dict) else d):
    m = r.get("mountPoint") or r.get("mount_point")
    fid = r.get("id")
    if m: print(str(fid) + "\t" + m)
')"
declared_folders="$(printf '%s\n' "${SITE_FOLDERS[@]}")"
while IFS=$'\t' read -r fid mount; do
  [ -n "${mount:-}" ] || continue
  printf '%s\n' "$declared_folders" | grep -qxF -- "$mount" && continue
  note "group folder '$mount' is live but not in SITE_FOLDERS — it still holds its files; remove it deliberately with 'occ groupfolders:delete $fid' if that is intended"
done <<< "$live_folders"

# --- groups ---
# The shared registry is READ OUT OF PHASE 20 rather than restated here, so there is one list and it
# is the one that runs. The coupling is to that file's shape: `ensure_group <id>` lines and
# "id|display" array entries. If the shape changes, the count guard below turns a silent
# every-role-is-undeclared report into a loud one — which is the failure mode worth designing for,
# since a report that cries wolf is a report nobody reads.
declared_shared="$( { sed -n 's/^ *"\(\(role\|cat\)-[a-z0-9-]*\)|.*/\1/p' "$PHASE20"
                     sed -n 's/^ensure_group \([a-z0-9-]*\).*/\1/p' "$PHASE20"; } | sort -u )"
shared_count="$(printf '%s\n' "$declared_shared" | grep -c . || true)"
if [ "$shared_count" -lt 20 ]; then
  note "cannot check groups: only $shared_count declared groups parsed out of $PHASE20 (expected 27+). Its shape changed — fix the two sed expressions in $0 before trusting this report"
else
  declared_groups="$(printf '%s\n%s\n' "$declared_shared" "admin"
                     for e in "${SITE_TEAMS[@]}"; do printf '%s\n' "${e%%|*}"; done
                     declare -p SITE_ROLES >/dev/null 2>&1 || SITE_ROLES=()
                     for e in "${SITE_ROLES[@]}"; do printf '%s\n' "${e%%|*}"; done)"
  # `admin` is Nextcloud's own and no phase declares it, hence its place in the declared list above.
  #
  # The difference is taken ONCE into a variable, then looped over with a here-string. Piping `occ`
  # straight into the `while` would put the loop in a subshell, where every `note` appends to a copy
  # of the array that dies with it — the report would find things and then print the all-clear.
  extra_groups="$(occ group:list --output=json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for g in (d.keys() if isinstance(d, dict) else d): print(g)
' | grep -vxF -f <(printf '%s\n' "$declared_groups") || true)"
  while read -r gid; do
    [ -n "$gid" ] || continue
    # Named, not deleted: a group that is a group folder's only grantee strands that folder when
    # removed, which is the one way "delete a group" reaches files without touching them.
    note "group '$gid' is live but not declared in SITE_TEAMS, SITE_ROLES or $PHASE20 — check it is not a group folder's only grantee before 'occ group:delete $gid'"
  done <<< "$extra_groups"
fi

# --- apps unpacked into apps/ that the inventory does not name ---
# apps/ is gitignored and bind-mounted, so anything here arrived outside provisioning. Not an error:
# a custom app in development lives here legitimately (AD-9). It is worth SAYING so that a clean
# reinstall does not surprise anyone by not reproducing it.
declared_apps="$(sed -n 's/^APPS="\(.*\)"/\1/p' "$PHASE12" | tr ' ' '\n' | grep -c . || true)"
if [ "$declared_apps" -eq 0 ]; then
  note "cannot check apps: no APPS= line parsed out of $PHASE12"
else
  apps_list="$(sed -n 's/^APPS="\(.*\)"/\1/p' "$PHASE12" | tr ' ' '\n')"
  for d in apps/*/; do
    [ -d "$d" ] || continue
    a="$(basename "$d")"
    printf '%s\n' "$apps_list" | grep -qxF -- "$a" && continue
    note "app '$a' is unpacked in apps/ but not in APPS — provisioning will not reproduce it on a clean install"
  done
fi

if [ "${#notes[@]}" -eq 0 ]; then
  [ "$quiet" -eq 1 ] || echo "  nothing live that the repo does not declare"
  exit 0
fi

# Deliberately not a warning banner. These are things a person decided to do; the report exists so
# the decision is visible on the next install, not so anyone feels told off.
printf '\n  live on this instance, not declared in the repo:\n'
printf '    %s\n' "${notes[@]}"
exit 0
