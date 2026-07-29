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

phase_end
