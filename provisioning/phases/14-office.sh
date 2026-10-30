# Phase 14 — Euro-Office connector configuration.  OWNER: AD-5 + the installer suite (slice 16's AIO arm).
# Runs after 12-apps (which installs the `eurooffice` connector) and before 15-branding.
#
# Share identity and public URL configuration with normal container startup. Phase 12
# installs the signed connector after the first boot, so presence-gated startup alone
# cannot configure a fresh install. No restart or second JWT/URL implementation.
phase_begin "14-office" "Euro-Office connector configuration (AD-5)"
nc_exec --user www-data -- bash /configure-apps.sh eurooffice

# --- by IP (R22): the server-to-server legs inside the wizard's network ---
# An install by IP publishes https://<ip>/ under the installer's own CA, which the document server
# does not trust, at a private address it refuses to fetch from. So both server-to-server legs go
# inside the wizard's network: the document server by its container name, Nextcloud by
# apache's plain internal listener. The browser's leg, DocumentServerUrl, stays the entrypoint's
# https://<ip>/eurooffice. A domain install keeps its public legs (B-019). The address is the one
# the entrypoint writes into overwrite.cli.url on every boot; a value that cannot be read is said,
# never taken for a domain (B-014).
conf_load
pub="$(conf_get system overwrite.cli.url || true)"; pub="${pub#https://}"; pub="${pub%/}"
if [ -z "$pub" ]; then
  log "AIO: overwrite.cli.url could not be read — the office's internal URLs left as they are"
elif [[ "$pub" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  app_config_set eurooffice DocumentServerInternalUrl "http://aps-conecta-eurooffice/"
  app_config_set eurooffice StorageUrl                "http://aps-conecta-apache.nextcloud-aio:23973/"
fi
# --- end by IP ---

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
# Only the ODF names: formatsSetting() overrides just the keys present, so OOXML keeps its
# defaults.
app_config_set eurooffice editFormats '{"odt":true,"ods":true,"odp":true}'
app_config_set eurooffice defFormats  '{"odt":true,"ods":true,"odp":true}'

phase_end
