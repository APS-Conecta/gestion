# Phase 06 — background job scheduling mode.  OWNER: post-v1 hardening.
# Pairs with the `cron` service in compose.yaml. The container schedules the work; this tells
# Nextcloud to expect it. Both halves are required — either one alone is a silent half-fix.
phase_begin "06-jobs" "background jobs run from cron, not ajax"

# Nextcloud defaults to `ajax`: jobs run only when a user loads a page, one per request. On a dev
# box being clicked that looks fine — all 121 registered jobs had run — but it means housekeeping
# stops whenever nobody is browsing. Measured 2026-07-28: no cron service existed and the mode was
# unset, which is also why an armed `survey_client` monthly report had never fired.
#
# It matters beyond tidiness. PublicKeyTokenProvider::invalidateOldTokens() runs from cron (its own
# log context says `['app' => 'cron']`), so it is what actually deletes expired auth tokens
# server-side. Phase 05's session posture holds without it — the browser drops the cookie on its
# own — but the dead rows only get swept here. Roadmap items #26 (full-text indexing), #27
# (Paperless) and #28 (Analytics) all assume jobs fire on a schedule rather than on traffic.
#
# `occ background:cron` writes exactly this: core/Command/Background/Mode.php:43 calls
# appConfig->setValueString('core', 'backgroundjobs_mode', $mode). Going through app_config_set
# instead gets the query-before-set guard for free, so a re-seed logs "already" rather than
# rewriting the key every run.
app_config_set core backgroundjobs_mode cron

# WHEN the expensive daily jobs run. Unset means Nextcloud spreads them across the day, so a
# CESFAM's file scans and DB cleanups land in the middle of a working morning — and the admin
# Overview says so, permanently, which is how this was found (2026-07-30).
#
# The value is an HOUR IN UTC, and the window is four hours long. 5 UTC = 01:00 CLT (UTC-4), so
# the heavy work happens overnight local and is finished long before staff arrive. This is the one
# number here that is timezone-dependent: if the instance ever serves a different timezone, this
# moves with it and `default_locale`/`default_phone_region` in 10-locale do not.
config_system_set maintenance_window_start 5 integer

phase_end
