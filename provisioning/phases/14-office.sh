# Phase 14 — Euro-Office connector configuration.  OWNER: AD-5.
# Runs after 12-apps (which installs the `eurooffice` connector) and before 15-branding.
#
# These keys used to live in `make office-eurooffice` as eight bare `occ config:app:set` calls:
# config-as-code sitting outside the config-as-code pipeline, with no query-before-set, writing on
# every invocation and invisible to scripts/seed-idempotent.sh. Here they get the guards for free.
#
# What stays in the Makefile is what this phase cannot do: starting the ~2 GB documentserver
# container (`--profile eurooffice`), the install-time trusted_domains repair, and the smoke.
# That target owns the BACKEND; this phase owns the CONNECTOR's configuration.
#
# Setting these without the backend running is harmless and deliberate: the connector is a PHP app
# that does nothing until a document server answers at DocumentServerUrl. AD-5 makes the ~2 GB
# container opt-in, not the connector's config.
phase_begin "14-office" "Euro-Office connector configuration (AD-5)"

# No default. This used to fall back to 9980 while the two office scripts fell back to 80, so a
# .env missing the key produced three different answers and wrote a silently-wrong browser URL.
# .env.example ships it and compose.yaml requires it, so absence means a broken .env — say so.
: "${OFFICE_PORT:?set OFFICE_PORT in .env}"

# Where the BROWSER reaches the document server, and where the two containers reach each other
# (AD-8: container-to-container by service name, never localhost).
app_config_set eurooffice DocumentServerUrl         "http://localhost:$OFFICE_PORT/"
app_config_set eurooffice DocumentServerInternalUrl "http://eurooffice/"
app_config_set eurooffice StorageUrl                "http://nextcloud/"

# Force the editor light (#52). The connector's customizationTheme defaults to "theme-system",
# which follows the USER'S OPERATING SYSTEM — so the same instance rendered a light editor on a
# light-mode machine and a dark one on a dark-mode machine. That is precisely what this instance
# decided against: enforce_theme=light + disable-user-theming=yes exist so a personal OS setting
# cannot change what staff see. The editor was the last surface opting out of that decision.
# Accepted values are theme-system | default-light | default-dark (AppConfig.php:894).
app_config_set eurooffice customizationTheme default-light

# ODF editing, lossy via OOXML conversion (#45). Both keys, different jobs: editFormats sets the
# `edit` flag, defFormats makes a click in Files open here at all (crossed in AppConfig.php:1209).
# Only the ODF names: formatsSetting() overrides just the keys present, so OOXML keeps its defaults.
app_config_set eurooffice editFormats '{"odt":true,"ods":true,"odp":true}'
app_config_set eurooffice defFormats  '{"odt":true,"ods":true,"odp":true}'

# The only secret this pipeline writes. Query-before-set still works — comparing a value is not
# printing it — so the guard is inline here rather than through app_config_set, whose log line
# would put the secret on stdout (NFR-2/AD-3). The log still carries the ` -> ` write marker so
# scripts/seed-idempotent.sh can see a rewrite; it just never carries the value.
#
# Absent rather than fatal when unset: AD-5 makes the office backend opt-in, so a seed must not die
# because someone has not set up an optional component. `make office-smoke` is where that failure
# belongs, and it is loud there.
if [ -z "${OFFICE_JWT_SECRET:-}" ]; then
  log "app:eurooffice:jwt_secret skipped — set OFFICE_JWT_SECRET in .env before using the office backend"
elif [ "$(conf_get app eurooffice jwt_secret 2>/dev/null || true)" = "$OFFICE_JWT_SECRET" ]; then
  log "app:eurooffice:jwt_secret already set (value not printed)"
else
  occ config:app:set eurooffice jwt_secret --value="$OFFICE_JWT_SECRET" >/dev/null \
    && log "app:eurooffice:jwt_secret -> (value not printed)"
fi

phase_end
