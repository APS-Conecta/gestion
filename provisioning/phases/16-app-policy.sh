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

for app in ${POLICY_DISABLED:-}; do
  app_disable "$app"
done

phase_end
