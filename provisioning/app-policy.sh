# Which apps staff actually see — the inventory, separated from the phase that applies it.
#
# SOURCED, NEVER EXECUTED. `provisioning/phases/16-app-policy.sh` sources this and applies it;
# `scripts/smoke.sh` sources it to assert the instance still matches. Two readers of one
# declaration, which is the point: the ids used to be typed out in both places, and a policy you
# can only read by RUNNING a phase is a policy nobody reviews.
#
# THE MODEL: admin keeps every app; every non-admin account gets the reduced set.
# LEVER PRECEDENCE: config switch -> group restriction -> disable. Restriction is preferred because
# a restricted app is still installed for the Layer-2 apps on the roadmap to build on; disable is
# reserved for the two cases where restriction cannot work, each explained below.
#
# Audited 2026-07-28 against the 53 apps then enabled. Apps required by roadmap items are
# deliberately untouched: app_api (#29), webhook_listeners (#27/#28), systemtags (#26/#27),
# notifications + dashboard + activity (#25/#28), circles (#25).

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
POLICY_ADMIN_ONLY="support updatenotification serverinfo recommendations related_resources weather_status"

# APP:KEY:VALUE. Applied BEFORE the disables below, and the order is load-bearing for
# survey_client — see its note there.
#
#   firstrunwizard:wizard_enabled:false — a config switch beats restriction. The tour is the first
#     thing a new staff member sees and is entirely Nextcloud's product voice, but the app also owns
#     a personal-settings section, so disabling it is the wrong lever. Both listeners gate on this
#     key, so the tour dies while the app stays installed — leaving the hook available for an
#     APS Conecta onboarding later.
#   survey_client:never_again:true — the app's own kill switch. See below.
POLICY_CONFIG="firstrunwizard:wizard_enabled:false survey_client:never_again:true"

# Disabled, because restriction cannot work for either.
#   survey_client            — sends usage data TO Nextcloud. Restriction would be theatre:
#                              MonthlyReport::run() calls sendReport() every 28 days server-side
#                              unless `never_again` is set, regardless of who can see the settings
#                              panel. Hence the config switch first (run() then removes its own
#                              job), then the disable.
#   nextcloud_announcements  — pushes Nextcloud's marketing into every user's notification bell. It
#                              declares type `logging`, which Nextcloud refuses to group-restrict,
#                              so it is all-or-nothing.
POLICY_DISABLED="survey_client nextcloud_announcements"

# NOT restricted, verified 2026-07-31: `office` is a SEPARATE app from `eurooffice` and the only one
# of the two that registers a navigation entry (`eurooffice`'s info.xml declares none), so the single
# "Office" tile in the app menu is not a duplicate. Left enabled deliberately, not by omission.
