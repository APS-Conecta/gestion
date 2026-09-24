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
# This is instance configuration, never a repository fact. The archive is served by the `tiles`
# service on this stack, but the address STAFF BROWSERS use to reach it is a per-install answer —
# the browser is not in the compose network and cannot resolve a service name.
#
# The default is the loopback one on purpose. It works for a developer on this box and for nobody
# else, which is the honest failure: a browser on another machine cannot reach it, and Territorio
# says «No se pudo cargar el fondo de mapa» rather than showing a map that is quietly wrong. A
# wrong-but-plausible public URL would fail silently instead.
app_config_set territorio tile_url "${TILES_PUBLIC_URL:-http://localhost:${TILES_PORT:-8084}/chile.pmtiles}"

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

for app in ${POLICY_DISABLED:-}; do
  app_disable "$app"
done

phase_end
