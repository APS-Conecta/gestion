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

for app in ${POLICY_DISABLED:-}; do
  app_disable "$app"
done

phase_end
