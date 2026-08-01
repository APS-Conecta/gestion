# Phase 12 — the apps this instance runs, and the edits we make inside them.  OWNER: ADR-0002.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# APPS is the inventory; provisioning/apps/<appid>/ holds the vendored tarball, its VENDOR
# provenance file, and the *.patch edits applied in name order after unpacking. So this file says
# WHICH apps we run and that directory says which bytes and which edits.
#
# NOTHING HERE CONTACTS THE APP STORE (#98). The store was the only dependency whose failure left
# the instance half-built — an app missing, its folders absent, its patches unapplied — where a
# failed image pull merely stops. ~12 MB of committed tarballs buys that away. The cost is recorded
# rather than hidden: the repo went from 7.3 MB to ~19 MB and git keeps every future version
# forever, so each bump adds another full copy for every clone.
# Only FILE edits belong here — `occ config:app:set` lives in the database, survives an app update,
# and stays in 15-branding / 16-app-policy / 14-office.
#
# This phase converges apps ON THE VENDORED VERSION and never on "whatever is newest" (#117). It
# re-imposes the committed tarball when the instance is running something else, which is
# deterministic — two identical seeds produce identical instances. `occ app:update` is the opposite
# and stays a deliberate separate act: it asks the store what is newest today, so running it here
# would make the same seed produce different instances depending on the day.
#
# Bumping a vendored app is therefore an edit, not a command: new tarball, new VENDOR lines, then
# `make seed` re-imposes it everywhere. The patches are the gate either way — one that no longer
# applies stops the phase and names itself.
#
# eurooffice is installed here; 14-office configures it. That split predates #81 and outlived the
# reason for it — AD-5's opt-in was the ~2 GB documentserver, which is now an ordinary service — but
# the split is still right: this phase owns which apps exist and what is patched inside them, and
# having the connector installed on every seed is what lets its patches be re-applied every seed.
phase_begin "12-apps" "apps this instance runs, plus the edits inside them"

APPS="groupfolders side_menu eurooffice"

for app in $APPS; do
  ensure_vendored_app "$app"
  patched=
  for patch in "$HERE"/apps/"$app"/*.patch; do
    [ -e "$patch" ] || continue
    apply_patch "$app" "$patch"
    patched=1
  done

  # appinfo/signature.json is a vendor claim that the files are as shipped; our patches make it
  # false, so the integrity check fails and admin > Overview goes permanently red (#71). Nextcloud
  # verifies a non-shipped app only if that file is present (Checker.php:546), so deleting the claim
  # we just invalidated is both the fix and an honest description of what we did. Core and every
  # unpatched app keep their check. Query-before-set: the second seed finds nothing to drop.
  sig="custom_apps/$app/appinfo/signature.json"
  if [ -n "$patched" ] && occ_sh "test -e $sig"; then
    occ_sh "rm -f $sig" && log "signature dropped for $app (patched, so it no longer describes the files)"
  fi
done

phase_end
