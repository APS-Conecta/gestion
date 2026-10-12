# Phase 16 — which apps staff actually see.  OWNER: post-v1 hardening.
# Runs after 15-branding: branding decides how the instance looks, this decides what is in it.
#
# The inventory and every per-app reason live in provisioning/app-policy.sh, sourced here and by
# scripts/smoke.sh. This file is now only the ORDER the levers are pulled in, which is the part
# that is genuinely phase logic rather than declaration.
phase_begin "16-app-policy" "admin keeps everything; staff get the reduced set"

. provisioning/app-policy.sh

for app in ${POLICY_ADMIN_ONLY:-}; do
  app_restrict_to_groups "$app" admin
done

# Config switches BEFORE disables, and not as a style choice: survey_client's own kill switch has
# to be written while the app is still enabled, or MonthlyReport::run() never runs to remove its
# own job. app-policy.sh says so at both entries; this loop is where the ordering is enforced.
# The intravox triple rides the same list as a LITERAL (free-tier-always): the value is a
# repository constant, not a per-install answer, so nothing here expands a variable into it.
# Writing it before the app exists anywhere is harmless — occ config:app:set stores the row
# whatever the inventory says — and it means the pin is already in place the day the app ships.
for entry in ${POLICY_CONFIG:-}; do
  _app="${entry%%:*}"; _rest="${entry#*:}"
  app_config_set "$_app" "${_rest%%:*}" "${_rest#*:}"
done

# Territorio's basemap (ADR-0019 in that repo). NOT in POLICY_CONFIG above, and the reason is
# mechanical: that list is space-separated `app:key:value` triples, so it cannot carry a value that
# needs a variable expanded into it. Same shape and same reason as 14-office's DocumentServerUrl.
#
# The suite serves the archive same-origin at /tiles/ (L5: apache binds the host's map folder
# read-only at /aps-tiles, the AIO fork's own route), so the URL is whatever address this
# instance is already reached by — the value the wizard's entrypoint writes into
# overwrite.cli.url, derived exactly the way 14-office derives the office's internal URLs. One
# source of truth and no knob: TILES_PUBLIC_URL/B-033 was a hand-set copy of a fact the instance
# already knew, and it drifted. Territorio rejects a relative URL, so the absolute form is
# written. A value that cannot be read is said and the key left as it is, never guessed
# (B-014, 14-office's own rule). Not under AIO (the dev stack) no suite serves it: blank falls
# territorio back to the OSM raster (Basemap::resolve), which still draws a map. Detection is
# env.sh's is_aio, computed here as 14-office computes it (seed.sh sources env.sh first).
# --- territorio's tile_url (L5-S3): stable markers for test.sh's extracted-block branch tests
# (the 14-office `# --- by IP (R22)` precedent — comments delimit, nothing behavioral moves) ---
if is_aio; then aio=1; else aio=0; fi
if [ "$aio" = 1 ]; then
  conf_load
  ocu="$(conf_get system overwrite.cli.url || true)"
  if [ -n "$ocu" ]; then
    app_config_set territorio tile_url "${ocu%/}/tiles/chile.pmtiles"
  else
    # Q9 (org review L5-S3): say the VALUE being left, not only the reason for leaving it — an
    # operator reading this log must tell "stale but the suite's own route" from "something
    # older pointing elsewhere" without opening occ. conf_get already reads the app config
    # (app_config_set reads through the same cache), so the stale value costs one lookup.
    stale="$(conf_get app territorio tile_url || true)"
    log "AIO: overwrite.cli.url could not be read — territorio's tile_url left as it is («${stale:-sin valor}»)"
  fi
else
  app_config_set territorio tile_url ""
fi
# --- end territorio's tile_url ---

# Territorio's comuna — the register's own five-digit CUT and the comuna's name, the second
# per-consumer seam ADR-0013 named: the import door refuses another comuna's file against this
# value (apps/territorio ImportService::refuseAnotherComuna). Same shape and same mechanical reason as
# tile_url above: not in POLICY_CONFIG, because the value is variable-expanded out of the
# generated site file.
#
# Writing the pair is what ARMS the door. An empty comuna_cut is not neutral — ComunaConfig reads
# it as "not chosen" (ComunaConfig.php:25-28) and refuseAnotherComuna then waves every file
# through. So a site file written before this emission is a hard stop, not a default: an empty
# write is exactly the silent disarm this line exists to prevent.
#
# The APCu trap is web-process-cosmetic only (apps/territorio README, "Two traps worth knowing"):
# occ reads fresh config, so provisioning and territorio:import see the pair immediately — only
# the web process may keep serving the stale "not chosen" view until its container restarts. A
# fresh install boots with the keys already in place; a live install picks them up on the next
# restart, and a choice made through the admin UI (the second writer, ComunaConfig::set) carries
# no lag of its own — its write lands in the web process itself.
[ -n "${SITE_COMUNA_CUT:-}" ] || { echo "FATAL: sites/$SITE/site.sh carries no SITE_COMUNA_CUT. Regenerate the site file (scripts/deis.py <codigo> --new <slug>), or add the line by hand: the register row for this DEIS code names the comuna's five-digit CUT." >&2; exit 1; }
app_config_set territorio comuna_cut "$SITE_COMUNA_CUT"
app_config_set territorio comuna_name "$SITE_COMUNA"

# Estadística's establishment — the DEIS code, the register's tipo and the comuna's CUT: the
# identity ADR-0013 says an app reads from config and never chooses. The app has no setter
# (apps/estadistica EstablishmentConfig), so this is the only writer, and divergence.sh reads the
# three back. Written whether the app is installed or not, like the POLICY_CONFIG rows above: a
# lab install has them the day the app is cloned.
#
# The guard is the app's own rule, not a style check. Establishment::of reads anything but six
# digits as "no establishment", and the app then shows the country and the peers with no local
# series and no error — the same silent disarm as an empty comuna_cut. The CUT is guarded above;
# the tipo only labels the admin section's notice.
case "${SITE_DEIS:-}" in
  [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "FATAL: sites/$SITE/site.sh carries SITE_DEIS='${SITE_DEIS:-}', not a six-digit DEIS code. Regenerate the site file (scripts/deis.py <codigo> --new <slug>): Estadística reads anything else as no establishment, and says nothing." >&2; exit 1 ;;
esac
app_config_set estadistica deis_code "$SITE_DEIS"
app_config_set estadistica establishment_type "${SITE_TIPO:-}"
app_config_set estadistica comuna_cut "$SITE_COMUNA_CUT"

for app in ${POLICY_DISABLED:-}; do
  app_disable "$app"
done

phase_end
