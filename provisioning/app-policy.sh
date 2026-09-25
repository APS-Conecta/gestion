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
#   intravox:telemetry_enabled:false — free-tier-always posture, written before the app ships
#     anywhere: TelemetryService::isEnabled() defaults ON and compares === 'true', so the literal
#     'false' is the pin (exact string, repository constant — never a per-site lever).
#     license_key needs no lever: absence IS the free tier, and it is never written.
POLICY_CONFIG="firstrunwizard:wizard_enabled:false survey_client:never_again:true intravox:telemetry_enabled:false"

# Disabled, because restriction cannot work for either.
#   survey_client            — sends usage data TO Nextcloud. Restriction would be theatre:
#                              MonthlyReport::run() calls sendReport() every 28 days server-side
#                              unless `never_again` is set, regardless of who can see the settings
#                              panel. Hence the config switch first (run() then removes its own
#                              job), then the disable.
#   nextcloud_announcements  — pushes Nextcloud's marketing into every user's notification bell. It
#                              declares type `logging`, which Nextcloud refuses to group-restrict,
#                              so it is all-or-nothing.
#   office                  — Nextcloud 34's first-party "Office overview" app, enabled by default
#                              from the image. NOT the suite's editor (that is `eurooffice`, which
#                              has no nav entry and engages when a document is opened from Files)
#                              and not wired to it either — no editor-url state is ever injected,
#                              so its "Office" tile is an overview that bounces to /f/{fileid}.
#                              Restriction is the wrong lever for the same reason as announcements:
#                              it is Nextcloud's product surface, not a suite feature staff lose.
#                              Decision flipped 2026-09-23 by the owner (the 2026-07-31 audit below
#                              had left it enabled as "not a duplicate" — true, but a dead surface
#                              with a confusing name is worse than no surface).
POLICY_DISABLED="survey_client nextcloud_announcements office"
