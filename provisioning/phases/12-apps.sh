# Phase 12 — the apps this instance runs, and the edits we make inside them.  OWNER: ADR-0002.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# apps.json (the suite manifest) is the inventory; provisioning/apps/<appid>/ holds the vendored
# tarball, its VENDOR provenance file, and the *.patch edits applied in name order after unpacking.
# So the manifest says WHICH apps we run and that directory says which bytes and which edits.
#
# NOTHING HERE CONTACTS THE APP STORE (#98) — the reasoning lives on ensure_vendored_app in lib.sh.
# Only FILE edits belong here — `occ config:app:set` lives in the database, so it survives an app
# update, and stays in 15-branding, 16-app-policy and 14-office.
# Converges on the VENDORED version, never "whatever is newest" (#117): the same seed produces the
# same instance. Bumping an app is an edit, not a command — new tarball, new VENDOR lines, re-seed.
# eurooffice is installed here and configured in 14-office: this phase owns which apps exist and
# what is patched inside them. Removing an app from the manifest does NOT uninstall it — nothing
# here deletes — so a live instance also needs `occ app:remove <id>` once, by hand.
phase_begin "12-apps" "apps this instance runs, plus the edits inside them"

manifest="$(python3 "$HERE/../scripts/apps.py" lines)" \
  || { echo "FATAL: could not read the suite manifest (apps.json) — scripts/apps.py says why above" >&2; exit 1; }

# Talk is the suite's option under AIO: off unless the wizard turns it on (the fork's patch 210), and
# with it off the entrypoint removes spreed on every boot (REMOVE_DISABLED_APPS) — installed here, it
# would be undone at the next restart and leave Talk without its signalling server. The suite's own
# switch decides, the one the entrypoint reads; compose has no such switch and always runs Talk.
talk=yes
if is_aio; then
  talk="$(nc_exec -- printenv TALK_ENABLED 2>/dev/null)" \
    || { echo "FATAL: could not read the suite's Talk switch (TALK_ENABLED) from the Nextcloud container — is it running?" >&2; exit 1; }
fi

# fd 3, not stdin: occ_sh runs `docker exec -i`, which would swallow the rest of the manifest.
while IFS=$'\t' read -r -u 3 app _source repo; do
  # notify_push is vendored for the bake only: the AIO entrypoint installs it on every start.
  [ "$app" = notify_push ] && continue
  if [ "$app" = spreed ] && [ "$talk" != yes ]; then
    log "spreed skipped: the suite runs without Talk (the wizard's option; AIO removes the app when it is off)"
    continue
  fi
  # Own and fork apps (a repo of ours) may be a live clone on a development machine, which
  # ensure_own_app leaves alone (ADR-0003); everything else is the vendored tarball.
  if [ -n "$repo" ]; then
    ensure_own_app "$app" "https://github.com/$repo.git"
  else
    ensure_vendored_app "$app"
  fi
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
done 3<<< "$manifest"

# Lab apps: ours, under development, NEVER shipped (ADR-0005). Inventory in dev/lab-apps.sh, which
# is tracked but inert — a clinic reads it and falls through here.
#
# THE .git TEST IS THE WHOLE MECHANISM, not a nicety. ensure_own_app hands a directory with no .git
# to ensure_vendored_app, and a lab app has no tarball to unpack: dropping this line was run on
# 2026-08-08 and phase 12 died with "FAILED territorio — no vendored tarball", i.e. every clinic
# install. Guard here rather than inside ensure_own_app, which is right to keep that fallthrough for
# the apps we DO ship.
if [ -f dev/lab-apps.sh ]; then
  . dev/lab-apps.sh
  for entry in ${LAB_APPS:-}; do
    app="${entry%%=*}"
    [ -d "apps/$app/.git" ] || continue
    ensure_own_app "$app" "${entry#*=}"
  done
fi

phase_end
