# Phase 05 — session and outbound-privacy defaults.  OWNER: post-v1 hardening.
# Runs first: the instance should never be reachable in a weaker posture than this, not even for the
# seconds between phases on a fresh bring-up.
phase_begin "05-security" "session hardening + outbound defaults"

# Browser sessions end with the browser window. The shipped default was 15 DAYS with "Recordarme"
# pre-checked — on a shared clinical workstation the next person to sit down is the previous user.
# 0 does three things: LoginController.php:153 stops RENDERING the checkbox,
# CreateSessionTokenCommand.php:30 forces DO_NOT_REMEMBER even if the flag is posted anyway, and the
# session cookie already carries no `expires`. Desktop/mobile CLIENTS are untouched — their tokens
# are PERMANENT_TOKEN, swept by token_auth_token_retention.
#
# HONEST LIMIT: not a guarantee. Chrome's "Continue where you left off" and Firefox's session
# restore keep session cookies across a browser restart; closing that needs a workstation policy.
config_system_set remember_login_cookie_lifetime 0 integer

# Automatic logoff: a browser session ends after 900 seconds (15 minutes) of inactivity. The
# background keepalive ping is switched off because it would renew the session while an idle
# clinical workstation sits on an open tab, so the logoff would never arrive.
config_system_set session_lifetime 900 integer
config_system_set session_keepalive false boolean

# Audit log of administrative actions: admin_audit is shipped with the server but not enabled by
# default.
app_enable admin_audit

# Make the lookup-server opt-out explicit. Changes no behaviour today — lookup_server_connector's
# RetryJob deletes itself while `gs.enabled` is false, which is the default — so this exists to make
# the opt-out a stated decision rather than an accident of nobody ever flipping that key.
config_system_set lookup_server ""

phase_end
