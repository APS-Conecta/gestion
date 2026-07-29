#!/usr/bin/env bash
# Shared helpers for the office scripts — asserts the Euro-Office backend is wired (AD-5).
# Source this; do not execute it.

NCEXEC="docker compose exec -T --user www-data nextcloud"
OCC="$NCEXEC php occ"
OFFICE_PORT="${OFFICE_PORT:-80}"

# An app is enabled iff its appconfig `enabled` value is "yes".
enabled() { [ "$($OCC config:app:get "$1" enabled 2>/dev/null || true)" = "yes" ]; }

# Require the eurooffice connector — the sole office backend (AD-5). Exit with a clear message if absent.
office_detect() {
  enabled eurooffice || { echo "FAIL: eurooffice connector not enabled — run: make office-eurooffice"; exit 1; }
}
