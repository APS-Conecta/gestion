# Phase 06 — background job scheduling mode.  OWNER: post-v1 hardening.
# Pairs with the `cron` service in compose.yaml: the container schedules the work, this tells
# Nextcloud to expect it. Both halves are required — either alone is a silent half-fix.
phase_begin "06-jobs" "background jobs run from cron, not ajax"

# Nextcloud defaults to `ajax`: jobs run only when a user loads a page, so housekeeping stops
# whenever nobody is browsing. Invisible on a dev box someone is clicking, which is how an armed
# `survey_client` monthly report sat unfired. It is also what sweeps expired auth tokens
# server-side (PublicKeyTokenProvider::invalidateOldTokens runs from cron), so phase 05's posture
# leaves dead rows behind without it.
#
# Set through app_config_set rather than `occ background:cron` — same write
# (Mode.php:43 setValueString core/backgroundjobs_mode), plus the query-before-set guard.
app_config_set core backgroundjobs_mode cron

# WHEN the expensive daily jobs run. Unset, Nextcloud spreads them across the day and lands file
# scans and DB cleanups mid-morning. The value is an HOUR IN UTC opening a four-hour window:
# 5 UTC = 01:00 CLT, finished long before staff arrive. The one timezone-dependent number in
# provisioning — it moves with the instance's timezone, `default_locale` in 10-locale does not.
config_system_set maintenance_window_start 5 integer

phase_end
