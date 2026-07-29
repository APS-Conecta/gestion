# Phase 05 — session and outbound-privacy defaults.  OWNER: post-v1 hardening.
# Runs before every other phase: the instance should never be reachable in a weaker posture than
# this, not even for the seconds between phases on a fresh bring-up.
phase_begin "05-security" "session hardening + outbound defaults"

# --- Browser sessions end with the browser window; nothing is remembered. -------------------
#
# Shipped defaults were: remember_login_cookie_lifetime 15 DAYS, and "Recordarme" CHECKED by
# default on the login form. On a shared clinical workstation that means the next person to sit
# down is still the previous user, for up to a fortnight. Nobody chose that — it is just the
# Nextcloud default, and it survived v1 unexamined.
#
# Setting this to 0 does three things at once. All three were read out of the NC34 source, not
# assumed:
#   1. core/Controller/LoginController.php:153 provides `<value> > 0` as initial state, so the
#      "Recordarme" checkbox is NOT RENDERED. The UI stops offering an option that cannot work.
#   2. lib/private/Authentication/Login/CreateSessionTokenCommand.php:30 calls
#      setRememberLogin(false) when the value is 0, so the token is DO_NOT_REMEMBER even if the
#      flag is submitted anyway.
#   3. The session cookie already carries no `expires` (session.cookie_lifetime=0, confirmed in
#      the live Set-Cookie headers), so the browser discards it when the window closes.
#
# Desktop and mobile CLIENTS are deliberately unaffected: their tokens are PERMANENT_TOKEN and
# are swept by a different key entirely (token_auth_token_retention, default 365 days) — see
# PublicKeyTokenProvider::invalidateOldTokens(), which sweeps four independent buckets. Tightening
# the browser costs the phone app nothing.
#
# HONEST LIMIT: this is not a hard guarantee. Chrome's "Continue where you left off" and Firefox's
# session restore preserve session cookies across a browser restart. That is client-side and
# unreachable from here; closing it needs a browser policy on managed workstations. Recorded rather
# than papered over, because "logout on close" reads like a promise and is not one.
config_system_set remember_login_cookie_lifetime 0 integer

# --- Outbound: make the lookup-server opt-out explicit. -------------------------------------
#
# lookup_server defaults to a live https://lookup.nextcloud.com. The connector is ALREADY inert:
# apps/lookup_server_connector RetryJob::shouldRemoveBackgroundJob() returns true while
# `gs.enabled` is false, and false is its default — so the job deletes itself and nothing is sent.
# This line therefore changes no behaviour today. It exists so the opt-out is a stated decision in
# config-as-code rather than an accident of `gs.enabled` never being flipped by someone later.
config_system_set lookup_server ""

phase_end
