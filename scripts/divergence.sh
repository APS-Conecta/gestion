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
# the standing positions in phase 50 there is not one until the roster lands (#106). Reporting every
# hand-added personal account as divergence would be noise, and noise is how a report stops being
# read. Add users here when #106 gives them a declared set.
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

# --- apps unpacked into apps/ that no inventory names ---
# apps/ is gitignored and bind-mounted, so anything here arrived outside provisioning. Worth SAYING,
# so a clean reinstall does not surprise anyone by not reproducing it.
# THREE inventories: APPS is vendored, OWN_APPS is ours and shipped (ADR-0003), LAB_APPS is ours and
# under development (ADR-0005). The last two carry a clone URL after an `=`; strip it to the app id.
# LAB_APPS is SOURCED, not sed'd: dev/lab-apps.sh is a shell file, and a parser that reads it as text
# would silently report every lab app the day its formatting changes.
# shellcheck source=../dev/lab-apps.sh
[ -f dev/lab-apps.sh ] && . dev/lab-apps.sh
apps_list="$( { sed -n 's/^APPS="\(.*\)"/\1/p' "$PHASE12"
                sed -n 's/^OWN_APPS="\(.*\)"/\1/p' "$PHASE12"
                printf '%s\n' "${LAB_APPS:-}"; } | tr ' ' '\n' | sed 's/=.*//')"
declared_apps="$(printf '%s\n' "$apps_list" | grep -c . || true)"
if [ "$declared_apps" -eq 0 ]; then
  note "cannot check apps: no APPS= line parsed out of $PHASE12"
else
  for d in apps/*/; do
    [ -d "$d" ] || continue
    a="$(basename "$d")"
    printf '%s\n' "$apps_list" | grep -qxF -- "$a" && continue
    note "app '$a' is unpacked in apps/ but not in APPS — provisioning will not reproduce it on a clean install"
  done
fi

# --- territorio's comuna keys: identity in app config, checked against the site file ---
# App-config keys are not a folder/group/app inventory; these two are checked alone because
# they are identity-bearing: an empty or wrong comuna_cut silently disarms the
# refuseAnotherComuna import door (apps/territorio ImportService::refuseAnotherComuna) while imports
# keep working. tile_url is deliberately absent — it carries the per-install TILES_PUBLIC_URL
# posture and phase 16 converges it on every seed. The territorio admin UI is a second writer
# of these rows (ComunaConfig::set), so a deliberate re-choice appears here exactly like a
# hand-edited site file does.
if [ -z "${SITE_COMUNA_CUT:-}" ]; then
  note "sites/$SITE/site.sh carries no SITE_COMUNA_CUT — phase 16 fails loudly until the file is regenerated (scripts/deis.py <codigo> --new <slug>)"
elif ! occ status >/dev/null 2>&1; then
  # "could not ask" is not "not present" (#143): config:app:get also exits 1 for an ABSENT
  # key (measured on the live stack), so the reads below must not read its exit code as
  # failure. occ answering is established here once with a key-independent probe; after it,
  # an absent key lands as the empty string — which is exactly the drift this section
  # exists to name, and a section that cannot tell an absent key from a broken occ is a
  # section that reports nothing on the install that needs it most.
  note "cannot read territorio's comuna keys — occ did not answer; nothing was checked"
else
  have="$(occ config:app:get territorio comuna_cut 2>/dev/null || true)"
  [ "$have" = "$SITE_COMUNA_CUT" ] || note "territorio comuna_cut is '${have:-<unset>}' but sites/$SITE/site.sh says '$SITE_COMUNA_CUT' — make install re-converges it, or the admin UI re-chooses the comuna deliberately"
  have="$(occ config:app:get territorio comuna_name 2>/dev/null || true)"
  [ "$have" = "${SITE_COMUNA:-}" ] || note "territorio comuna_name is '${have:-<unset>}' but sites/$SITE/site.sh says '${SITE_COMUNA:-}' — make install re-converges it"
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
