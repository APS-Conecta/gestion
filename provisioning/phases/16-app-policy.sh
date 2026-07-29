# Phase 16 — which apps staff actually see.  OWNER: post-v1 hardening.
# Runs after 15-branding: branding decides how the instance looks, this decides what is in it.
phase_begin "16-app-policy" "admin keeps everything; staff get the reduced set"

# THE MODEL: the admin account keeps every app. Every non-admin account gets the reduced set.
# `admin` is Nextcloud's built-in group and holds exactly one member here; staff live in `all-staff`
# and the 21 role groups from Epic 2.
#
# LEVER PRECEDENCE: config switch -> group restriction -> disable. Restriction is preferred over
# removal because an app kept installed is still available to the Layer-2 apps on the roadmap; a
# disabled one is a decision to re-litigate later. Disable is reserved for the two cases where
# restriction cannot work, each explained at its call site.
#
# Audited 2026-07-28 against the 53 apps enabled at the time. Apps required by roadmap items are
# deliberately untouched: app_api (#29 local AI ships as ExApps), webhook_listeners (#27/#28),
# systemtags (#26/#27), notifications + dashboard + activity (#25/#28), circles (#25).

# --- Nextcloud product surface: real to an admin, noise to everyone else -------------------
#
# None of these serve a clinical workflow. They stay installed and fully usable by admin.
#   support             — a panel about your NEXTCLOUD subscription. Note it cannot be repurposed
#                         into an APS Conecta staff-reporting channel: it is subscription-gated via
#                         IRegistry (lib/Settings/Admin.php). That capability belongs to
#                         notifications + the Provisioning API, or a Layer-2 app.
#   updatenotification  — advertises Nextcloud updates. Actively misleading here: the image is
#                         pinned in compose.yaml, so an update it announces cannot be applied that
#                         way at all.
#   serverinfo          — server monitoring. Admin tooling by nature.
#   recommendations     — "recommended files" dashboard widget.
#   related_resources   — related-items panel in the files sidebar.
#   weather_status      — calls an EXTERNAL weather API from staff dashboards. Restricting it keeps
#                         that egress off 4 staff accounts; it is not a full stop (admin still has
#                         it), which is why it is listed here and not under disable.
for app in support updatenotification serverinfo recommendations related_resources weather_status; do
  app_restrict_to_groups "$app" admin
done

# NOT restricted pending verification: `office`. It is a SEPARATE app from `eurooffice` and
# registers its own navigation entry named "Office" (office.page.index) rendering a document
# overview page. Whether that duplicates the Euro-Office entry has to be seen in the app menu, not
# guessed from appinfo. Left fully enabled until then — deliberately, not by omission.

# --- firstrunwizard: a config switch beats restriction here --------------------------------
#
# The "welcome to Nextcloud" tour is the FIRST thing a new staff member sees, and it is entirely
# Nextcloud's product voice. But disabling or restricting the app is the wrong lever: it owns a
# personal-settings section too, and the tour itself has a dedicated switch.
# Both listeners gate on it — lib/Listener/UserLoggedInListener.php:44 and
# BeforeTemplateRenderedListener.php:57 — so the tour dies while the app stays installed, leaving
# the door open for an APS Conecta onboarding built on the same hook later.
app_config_set firstrunwizard wizard_enabled false

# --- The two that must be disabled, and why restriction cannot do the job -------------------

# survey_client sends usage data TO Nextcloud. Group restriction would be theatre: MonthlyReport::
# run() calls Collector::sendReport() unconditionally every 28 days unless `never_again` is set,
# server-side, entirely independent of who can see the settings panel. `never_again` was NOT set
# here, so it was armed and simply had not fired yet — see phase 06-jobs for why.
# Set the app's own kill switch first (run() removes its own job when it sees this), then disable.
app_config_set survey_client never_again true
app_disable survey_client

# nextcloud_announcements pushes Nextcloud's marketing news into every user's notification bell.
# It declares type `logging`, which Nextcloud refuses to group-restrict, so hiding it from staff
# while keeping it for admin is not possible — it is all-or-nothing. Admin loses nothing of value.
app_disable nextcloud_announcements

phase_end
