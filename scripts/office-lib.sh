#!/usr/bin/env bash
# Shared helpers for the office scripts — the ACTIVE-backend detection both office-smoke.sh and
# office-formats.sh need (AD-5/AD-11). Source this; do not execute it.

OCC="docker compose exec -T --user www-data nextcloud php occ"
OFFICE_PORT="${OFFICE_PORT:-9980}"

# An app is enabled iff its appconfig `enabled` value is "yes".
enabled() { [ "$($OCC config:app:get "$1" enabled 2>/dev/null || true)" = "yes" ]; }

# Detect the active office connector: sets $rich/$euro to on/off and enforces AD-11 (exactly one active),
# exiting non-zero with a clear message when zero or both are enabled. Callers dispatch on $rich/$euro.
office_detect() {
  rich=off; euro=off
  enabled richdocuments && rich=on
  enabled eurooffice     && euro=on
  if ! { { [ "$rich" = on ] && [ "$euro" = off ]; } || { [ "$euro" = on ] && [ "$rich" = off ]; }; }; then
    echo "FAIL: expected exactly ONE office connector enabled (AD-11); got richdocuments=${rich}, eurooffice=${euro}"
    exit 1
  fi
}
