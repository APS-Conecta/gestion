# Phase 16 — which apps staff actually see.  OWNER: post-v1 hardening.
# Runs after 15-branding: branding decides how the instance looks, this decides what is in it.
#
# THE MODEL: admin keeps every app; every non-admin account gets the reduced set.
# LEVER PRECEDENCE: config switch -> group restriction -> disable. Restriction is preferred because
# a restricted app is still installed for the Layer-2 apps on the roadmap to build on; disable is
# reserved for the two cases where restriction cannot work, each explained at its call site.
#
# Audited 2026-07-28 against the 53 apps then enabled. Apps required by roadmap items are
# deliberately untouched: app_api (#29), webhook_listeners (#27/#28), systemtags (#26/#27),
# notifications + dashboard + activity (#25/#28), circles (#25).
phase_begin "16-app-policy" "admin keeps everything; staff get the reduced set"

# Nextcloud's product surface: real to an admin, noise to everyone else. All stay installed and
# fully usable by admin.
#   support             — a panel about your NEXTCLOUD subscription, and subscription-gated via
#                         IRegistry, so it cannot be repurposed as a staff-reporting channel.
#   updatenotification  — advertises updates that cannot be applied: the image is pinned.
#   serverinfo          — server monitoring; admin tooling by nature.
#   recommendations     — "recommended files" dashboard widget.
#   related_resources   — related-items panel in the files sidebar.
#   weather_status      — calls an EXTERNAL weather API from staff dashboards. Restricting keeps
#                         that egress off staff accounts; admin still has it, hence not a disable.
for app in support updatenotification serverinfo recommendations related_resources weather_status; do
  app_restrict_to_groups "$app" admin
done

# NOT restricted pending verification: `office`, a SEPARATE app from `eurooffice` that registers its
# own "Office" navigation entry. Whether that duplicates the Euro-Office entry has to be seen in the
# app menu, not guessed from appinfo. Left enabled deliberately, not by omission.

# firstrunwizard: a config switch beats restriction. The tour is the first thing a new staff member
# sees and is entirely Nextcloud's product voice, but the app also owns a personal-settings section,
# so disabling it is the wrong lever. Both listeners gate on this key, so the tour dies while the app
# stays installed — leaving the hook available for an APS Conecta onboarding later.
app_config_set firstrunwizard wizard_enabled false

# survey_client sends usage data TO Nextcloud. Restriction would be theatre: MonthlyReport::run()
# calls sendReport() every 28 days server-side unless `never_again` is set, regardless of who can see
# the settings panel. Set the app's own kill switch first (run() then removes its own job), then
# disable.
app_config_set survey_client never_again true
app_disable survey_client

# nextcloud_announcements pushes Nextcloud's marketing into every user's notification bell. It
# declares type `logging`, which Nextcloud refuses to group-restrict, so it is all-or-nothing.
app_disable nextcloud_announcements

phase_end
