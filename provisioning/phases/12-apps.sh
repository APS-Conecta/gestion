# Phase 12 — the apps this instance runs.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# apps.json (the suite manifest) is the inventory, and every row names its own channel: a
# release row (own or fork, ADR-0017) arrives from the app's own signed GitHub Release,
# resolved and verified at install time by the wizard's download step, and this phase installs
# it from the server's lock; a store row arrives from the Nextcloud app store through
# ensure_store_app — the scoped, one-command open (#42; no image carries an app, and the store
# is closed to everything else, the acquisition gate's 042 rows pin it).
#
# NOTHING HERE DOWNLOADS A RELEASE: acquisition is the wizard's fetch leg (releases.py); the
# seed only installs what that leg already verified and stored beside the lock. The store rows
# are the one deliberate exception — their scoped install IS their acquisition moment (#42) —
# and it opens the store for that single command, never longer.
# Only FILE edits belong in phases — `occ config:app:set` lives in the database, so it survives
# an app update, and stays in 15-branding, 16-app-policy and 14-office.
# Converges on WHAT THE SERVER RECORDS — the lock's tag for release rows (ADR-0017), presence
# and enabled state for store rows (#42): the same seed produces the same instance. A store
# app never moves after its install (nothing here updates); a release app moves only through
# `aps-conecta actualizar` (#46), which is the only thing that moves the lock.
# Removing an app from the manifest does NOT uninstall it — nothing here deletes — so a live
# instance also needs `occ app:remove <id>` once, by hand.
phase_begin "12-apps" "apps this instance runs"

# An unreadable manifest is reported by apps.py itself — its one Spanish line is already on
# stderr — and the seed's errexit stops the phase here. `repos` carries the fields this phase's
# walk reads; `opcionales` names the rows the wizard offers (#39), so the choice gate below has
# the manifest's own list — never a second one.
manifest="$(python3 "$HERE/../scripts/apps.py" repos)"
manifest_opcionales="$(python3 "$HERE/../scripts/apps.py" opcionales)"
# the optional ids once, cut ahead of the walk — the per-row question is then one grep, not a
# pipeline per row over the same list
opcionales_ids="$(printf '%s\n' "$manifest_opcionales" | cut -f1)"

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
  # notify_push is the entrypoint's own: it installs the app scoped when the binary is absent
  # (a first boot's push sibling needs it before provisioning has run, entrypoint.sh), so this
  # walk never touches an app the entrypoint owns.
  [ "$app" = notify_push ] && continue
  # An optional app (#39) installs only by the operator's choice — app_elegida reads the wizard's
  # record, the one the host CLI writes at step 6 — and an unchosen optional row is never
  # INSTALLED: no lock row honoured, no release fetched (the fetch leg asks the same record),
  # no store install. Un-choosing on a warm server keeps what runs — nothing here deletes;
  # `occ app:remove <id>`, by hand.
  if printf '%s\n' "$opcionales_ids" | grep -qx -- "$app" && ! app_elegida "$app"; then
    log "$app skipped: la aplicación opcional no fue elegida (el registro del asistente)"
    continue
  fi
  if [ "$app" = spreed ] && [ "$talk" != yes ]; then
    log "spreed skipped: the suite runs without Talk (the wizard's option; AIO removes the app when it is off)"
    continue
  fi
  # Two channels (ADR-0017 + #42), one dev escape:
  #   RELEASE — a repo row the server's lock names: the fetched, verified tarball
  #     (ensure_release_app). The lock is the pin; the seed downloads nothing.
  #   STORE — a store-source row: the scoped one-command install (ensure_store_app).
  #   A DEV CHECKOUT — apps/<id>/.git exists: someone is editing the app, and the seed
  #     leaves it alone (ensure_own_app's dev half).
  # A repo row with neither a lock row nor a checkout is a FATAL (ensure_own_app names the
  # repair) — the bake that once fed that branch is gone (#42), and the seed is not the door
  # that improvises an app from a channel nobody verified.
  row=""
  [ -z "$repo" ] || [ -d "apps/$app/.git" ] || row="$(lock_row "$app")"
  if [ -n "$row" ]; then
    ensure_release_app "$app" "$row"
  elif [ -n "$repo" ]; then
    ensure_own_app "$app" "https://github.com/$repo.git"
  else
    ensure_store_app "$app"
  fi
done 3<<< "$manifest"

phase_end
