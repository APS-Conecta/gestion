# Phase 12 — the apps this instance runs, and the edits we make inside them.  OWNER: ADR-0002.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# APPS is the inventory; provisioning/apps/<appid>/*.patch are the edits, applied in name order
# after install. So this file says what we install, `ls provisioning/apps/` says what we edit.
# Only FILE edits belong here — `occ config:app:set` lives in the database, survives an app update,
# and stays in 15-branding / 16-app-policy / 14-office.
#
# This phase does NOT update apps: `occ app:update` is a deliberate act, and updating here would
# make two identical seeds produce different instances depending on the day. Run it, then
# `make seed`, which re-applies the patches or fails loudly if upstream moved.
#
# eurooffice is installed here; 14-office configures it. That split predates #81 and outlived the
# reason for it — AD-5's opt-in was the ~2 GB documentserver, which is now an ordinary service — but
# the split is still right: this phase owns which apps exist and what is patched inside them, and
# having the connector installed on every seed is what lets its patches be re-applied every seed.
phase_begin "12-apps" "apps this instance runs, plus the edits inside them"

APPS="groupfolders side_menu eurooffice"

for app in $APPS; do
  ensure_app "$app"
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
