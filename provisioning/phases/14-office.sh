# Phase 14 — Euro-Office connector configuration.  OWNER: AD-5.
# Runs after 12-apps (which installs the `eurooffice` connector) and before 15-branding.
#
# This phase owns EVERYTHING the connector needs, including the trusted_domains repair that used to
# live in a make target (#81) — see the note on it below.
phase_begin "14-office" "Euro-Office connector configuration (AD-5)"

# No default. This used to fall back to 9980 while the two office scripts fell back to 80, so a
# .env missing the key produced three different answers and wrote a silently-wrong browser URL.
# .env.example ships it and compose.yaml requires it, so absence means a broken .env — say so.
: "${OFFICE_PORT:?set OFFICE_PORT in .env}"

# Where the BROWSER reaches the document server, and where the two containers reach each other
# (AD-8: container-to-container by service name, never localhost).
# Unset = localhost, right for every posture this repo ships: compose.yaml publishes both ports on
# 127.0.0.1. Set it when something proxies them outward, so the seed converges instead of clobbering.
app_config_set eurooffice DocumentServerUrl         "${OFFICE_PUBLIC_URL:-http://localhost:$OFFICE_PORT/}"
app_config_set eurooffice DocumentServerInternalUrl "http://eurooffice/"
app_config_set eurooffice StorageUrl                "http://nextcloud/"

# The other half of StorageUrl, and the one piece of this that is not appconfig. The document server
# fetches documents FROM Nextcloud at the service name `nextcloud`, which Nextcloud rejects with
# HTTP 400 unless it is a trusted domain.
#
# It lived in `make office-eurooffice` and was AD-2's one documented exception until #81 dropped the
# eurooffice profile and retired it — docs/adr/0000-inherited-decisions.md §AD-2 owns that history.
#
# Not through config_system_set: that helper compares a scalar, and this is an ARRAY where the key
# to write is the next free INDEX. Query-before-set is done directly instead — `occ` prints one
# domain per line, so a fixed-string whole-line match is the membership test and the line count is
# the index. Reading through conf_get would return the whole array as JSON and still need parsing.
if occ config:system:get trusted_domains 2>/dev/null | grep -qxF nextcloud; then
  log "system:trusted_domains already carries nextcloud"
else
  _td_idx=$(occ config:system:get trusted_domains 2>/dev/null | grep -c . || true)
  occ config:system:set trusted_domains "${_td_idx:-0}" --value=nextcloud >/dev/null \
    && log "system:trusted_domains[${_td_idx:-0}] -> nextcloud"
fi

# Open documents in a NEW window (#81). AppConfig.php:642 reads this with a default of "true", so
# without this key an editor replaces whatever the user was looking at — including the folder they
# opened it from. Stored as a JSON string by setSameTab(), which is why the value is the word and
# not a bool.
app_config_set eurooffice sameTab false

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
# REQUIRED, not skipped-when-absent (#81). It used to log a skip, because a seed must not die over
# an optional component. The component is not optional any more, and the skip branch had become
# unreachable in any case: compose.yaml guards this key with ${OFFICE_JWT_SECRET:?}, so an unset
# value stops the stack from starting long before a phase could run against it.
: "${OFFICE_JWT_SECRET:?set OFFICE_JWT_SECRET in .env}"
if [ "$(conf_get app eurooffice jwt_secret 2>/dev/null || true)" = "$OFFICE_JWT_SECRET" ]; then
  log "app:eurooffice:jwt_secret already set (value not printed)"
else
  occ config:app:set eurooffice jwt_secret --value="$OFFICE_JWT_SECRET" >/dev/null \
    && log "app:eurooffice:jwt_secret -> (value not printed)"
fi

phase_end
