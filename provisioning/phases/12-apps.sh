# Phase 12 — the apps this instance runs, and the edits we make inside them.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# apps.json (the suite manifest) is the inventory; provisioning/apps/<appid>/ holds the vendored
# tarball, its VENDOR provenance file, and the *.patch edits applied in name order after unpacking.
# So the manifest says WHICH apps we run and that directory says which bytes and which edits —
# except the rows the manifest marks release (ADR-0017): those arrive from the app's own signed
# GitHub Release, resolved and verified at install time by the wizard's download step, and this
# phase installs them from the server's lock (the vendored bake is their interim fallback, #42).
#
# NOTHING HERE CONTACTS THE APP STORE (#98) — the reasoning lives on ensure_vendored_app in lib.sh.
# NOTHING HERE DOWNLOADS EITHER: acquisition is the wizard's fetch leg (releases.py); the seed
# only installs what that leg already verified and stored beside the lock.
# Only FILE edits belong here — `occ config:app:set` lives in the database, so it survives an app
# update, and stays in 15-branding, 16-app-policy and 14-office.
# Converges on the PINNED version — the lock's tag for release rows (ADR-0017), the VENDOR pin
# for baked rows — never "whatever is newest" (#117): the same seed produces the same instance.
# Bumping a baked app is an edit, not a command — new tarball, new VENDOR lines, re-seed; bumping
# a release app is `aps-conecta actualizar` (#46), which is the only thing that moves the lock.
# eurooffice is installed here and configured in 14-office: this phase owns which apps exist and
# what is patched inside them. Removing an app from the manifest does NOT uninstall it — nothing
# here deletes — so a live instance also needs `occ app:remove <id>` once, by hand.
phase_begin "12-apps" "apps this instance runs, plus the edits inside them"

# An unreadable manifest is reported by apps.py itself — its one Spanish line is already on
# stderr — and the seed's errexit stops the phase here. `repos` carries the only two fields this
# phase reads (the retired `lines` also carried source, which every reader dropped).
manifest="$(python3 "$HERE/../scripts/apps.py" repos)"

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
while IFS=$'\t' read -r -u 3 app repo; do
  # notify_push is vendored for the bake only: the AIO entrypoint installs it on every start.
  [ "$app" = notify_push ] && continue
  if [ "$app" = spreed ] && [ "$talk" != yes ]; then
    log "spreed skipped: the suite runs without Talk (the wizard's option; AIO removes the app when it is off)"
    continue
  fi
  # Three ways an app arrives (ADR-0017, until #42 removes the bake):
  #   RELEASE — the manifest says so and the server's lock names it: the fetched, verified
  #     tarball (ensure_release_app). The lock is the pin; the seed downloads nothing.
  #   OWN — a repo of ours without a lock row: a live clone on a development machine, or the
  #     interim bake on a server whose wizard step has not run (a lock row arrives with the
  #     first ejecutar, and every install path runs it).
  #   VENDORED — a store-source tarball from the bake.
  # A dev clone still wins over the lock: someone is editing apps/<id>, and the seed leaves it
  # alone exactly as before.
  row=""
  [ -z "$repo" ] || [ -d "apps/$app/.git" ] || row="$(lock_row "$app")"
  if [ -n "$row" ]; then
    ensure_release_app "$app" "$row"
    # A release carries its final bytes: no patches (edits belong in the app's repo now) and
    # no signature to drop (the fetch refuses a release that still carries one — #27's pack
    # decision, so the integrity check stays whole and green by construction).
    continue
  elif [ -n "$repo" ]; then
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

phase_end
