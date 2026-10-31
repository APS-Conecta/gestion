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
# Database configuration survives app updates. Its owners remain the policy phases and
# the shared startup module, called here as soon as the signed Talk app is available.
# Converges on WHAT THE SERVER RECORDS — the lock's tag for release rows (ADR-0017), presence
# and enabled state for store rows (#42): the same seed produces the same instance. A store
# app never moves after its install (nothing here updates); a release app moves only through
# `aps-conecta actualizar` (#46), which is the only thing that moves the lock.
# Nothing here deletes: `aps-conecta actualizar` uninstalls a release app whose row left the
# manifest (its lock row drops, #172); a store app that leaves it needs `occ app:remove <id>`
# once, by hand.
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
  # Two channels (ADR-0017 + #42):
  #   RELEASE — a repo row the server's lock names: the fetched, verified tarball
  #     (ensure_release_app). The lock is the pin; the seed downloads nothing.
  #   STORE — a store-source row: the scoped one-command install (ensure_store_app).
  # A repo row the lock does not name is a FATAL: every install path runs the download step
  # before the seed, so its absence is a stopped install to re-run, and the seed is not the
  # door that improvises an app from a channel nobody verified.
  row=""
  [ -z "$repo" ] || row="$(lock_row "$app")"
  if [ -n "$row" ]; then
    ensure_release_app "$app" "$row" || exit 1
    if [ "$app" = spreed ]; then
      nc_exec --user www-data -- bash /configure-apps.sh talk || exit 1
    fi
  elif [ -n "$repo" ]; then
    log "FAILED $app — its release was never resolved on this server (no lock row). Re-run the install so its download step resolves the release."
    exit 1
  else
    ensure_store_app "$app"
  fi
done 3<<< "$manifest"

phase_end
