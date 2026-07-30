# Phase 12 — the apps this instance runs, and the edits we make inside them.  OWNER: ADR-0002.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# APPS below is the inventory. An app needing file edits also gets provisioning/apps/<appid>/,
# whose *.patch files are applied in name order after it is installed; apps with nothing to patch
# have no directory. So: this line says what we install, `ls provisioning/apps/` says what we edit.
#
# Installing is not configuring: `occ config:app:set` lives in the database and survives an app
# update, so it stays where it belongs (15-branding, 16-app-policy, `make office-eurooffice`).
# Only file edits — which an update wipes, because apps/ is gitignored — belong here.
#
# This phase does NOT update apps. `occ app:update` is a deliberate act; run it, then `make seed`,
# which re-applies the patches or fails loudly if upstream moved. Updating here would make two
# identical seeds produce different instances depending on the day.
#
# eurooffice is installed here, not by `make office-eurooffice`. AD-5 makes the office backend
# opt-in, and it still is: what is optional is the ~2 GB documentserver container behind
# `--profile eurooffice`. The connector is a PHP app that does nothing until that target gives it
# a URL and a secret, and having it installed is what lets its patches be re-applied every seed.
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

  # A store app ships appinfo/signature.json, a vendor claim that its files are as shipped. Our
  # patches make that claim false, so the integrity check fails and admin > Overview shows a
  # permanent red warning (#71). Nextcloud verifies a NON-shipped app only if that file is present
  # (lib/private/IntegrityCheck/Checker.php:546 in the pinned image), so deleting the claim we just
  # invalidated is both the fix and the honest description of what we did. Core and every unpatched
  # app keep their check. Query-before-set: the second seed finds nothing to drop.
  sig="custom_apps/$app/appinfo/signature.json"
  if [ -n "$patched" ] && occ_sh "test -e $sig"; then
    occ_sh "rm -f $sig" && log "signature dropped for $app (patched, so it no longer describes the files)"
  fi
done

phase_end
