# Phase 12 — the apps this instance runs, and the edits we make inside them.  OWNER: ADR-0002.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# APPS is the inventory; provisioning/apps/<appid>/ holds the vendored tarball, its VENDOR
# provenance file, and the *.patch edits applied in name order after unpacking. So this file says
# WHICH apps we run and that directory says which bytes and which edits.
#
# NOTHING HERE CONTACTS THE APP STORE (#98) — the reasoning lives on ensure_vendored_app in lib.sh.
# Cost recorded, not hidden: ~12 MB of tarballs (repo 7.3 -> ~19 MB), plus a full copy per bump.
# Only FILE edits belong here — `occ config:app:set` lives in the database, so it survives an app
# update, and stays in 15-branding, 16-app-policy and 14-office.
# Converges on the VENDORED version, never "whatever is newest" (#117): the same seed produces the
# same instance. Bumping an app is an edit, not a command — new tarball, new VENDOR lines, re-seed.
# eurooffice is installed here and configured in 14-office: this phase owns which apps exist and
# what is patched inside them.
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
