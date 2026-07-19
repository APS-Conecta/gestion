#!/usr/bin/env bash
# provisioning/lib.sh — shared idempotency-guard helpers for the phase files (Story 0.5, AD-2).
# Sourced by seed.sh, which then sources each phase; every mutating helper is QUERY-BEFORE-CREATE:
# it inspects current state and skips/patches rather than blind-creating, so `make seed` is safe to
# re-run. Source this file; do not execute it. Host has python3 (no jq assumed) for JSON parsing.

# occ inside the running nextcloud container.
occ() { docker compose exec -T --user www-data nextcloud php occ "$@"; }

# --- logging ---
log()         { printf '    %s\n' "$*"; }
phase_begin() { CURRENT_PHASE="$1"; printf '▶ phase %s — %s\n' "$1" "${2:-}"; }
phase_end()   { printf '✓ phase %s\n' "${CURRENT_PHASE:-?}"; }

# --- preconditions ---
require_installed() {
  occ status --output=json 2>/dev/null | grep -q '"installed":true' \
    || { echo "FATAL: Nextcloud is not installed/reachable — run 'make up' first." >&2; exit 1; }
}

# --- idempotent config: set only if the current value differs ---
config_system_set() {  # KEY VALUE
  local key="$1" val="$2" cur
  cur="$(occ config:system:get "$key" 2>/dev/null | tr -d '\r')"
  if [ "$cur" = "$val" ]; then log "system:$key already = $val"; else
    occ config:system:set "$key" --value="$val" >/dev/null && log "system:$key -> $val"; fi
}
config_app_set() {  # APP KEY VALUE
  local app="$1" key="$2" val="$3" cur
  cur="$(occ config:app:get "$app" "$key" 2>/dev/null | tr -d '\r')"
  if [ "$cur" = "$val" ]; then log "app:$app:$key already = $val"; else
    occ config:app:set "$app" "$key" --value="$val" >/dev/null && log "app:$app:$key -> $val"; fi
}

# --- theming (idempotent set-if-different; NC34 CLI supports text/color keys, NOT image keys) ---
_norm() { case "$1" in yes|true|1|on) echo 1;; no|false|0|off|"") echo 0;; *) echo "$1";; esac; }
theming_set() {  # KEY VALUE
  local key="$1" val="$2" raw cur
  # `occ theming:config <key>` returns a sentence ("<key> is currently set to <value>"), not the bare value.
  raw="$(occ theming:config "$key" 2>/dev/null | tr -d '\r')"
  case "$raw" in *"is currently set to "*) cur="${raw#*is currently set to }";; *) cur="";; esac
  if [ "$(_norm "$cur")" = "$(_norm "$val")" ]; then log "theming:$key already = $val"; else
    occ theming:config "$key" "$val" >/dev/null && log "theming:$key -> $val"; fi
}

# --- groups (query-before-create) ---
group_exists() {  # GID
  occ group:list --output=json 2>/dev/null | python3 -c \
    'import sys,json;d=json.load(sys.stdin);k=d if isinstance(d,list) else list(d);sys.exit(0 if sys.argv[1] in k else 1)' \
    "$1" 2>/dev/null
}
ensure_group() {  # GID [DISPLAY]
  local gid="$1" display="${2:-}"
  if group_exists "$gid"; then log "group $gid exists"; return 0; fi
  if [ -n "$display" ]; then
    occ group:add --display-name="$display" "$gid" >/dev/null && log "group $gid created ($display)"
  else
    occ group:add "$gid" >/dev/null && log "group $gid created"
  fi
}

# --- users (fixtures; query-before-create) ---
user_exists() { occ user:info "$1" >/dev/null 2>&1; }  # UID
ensure_user() {  # UID DISPLAY PASSWORD
  local uid="$1" display="$2" pass="$3"
  if user_exists "$uid"; then log "user $uid exists"; return 0; fi
  # OC_PASS must reach the php process INSIDE the container — `docker compose exec` does not forward
  # host env, so pass it explicitly with -e (never on the command line; --password-from-env reads it).
  if docker compose exec -T --user www-data -e OC_PASS="$pass" nextcloud \
       php occ user:add --password-from-env --display-name="$display" "$uid" >/dev/null; then
    log "user $uid created"
  else
    log "FAILED to create user $uid"; return 1
  fi
}
user_in_group() {  # UID GID
  occ user:info "$1" --output=json 2>/dev/null | python3 -c \
    'import sys,json;g=json.load(sys.stdin).get("groups",[]);sys.exit(0 if sys.argv[1] in g else 1)' "$2" 2>/dev/null
}
add_user_to_group() {  # UID GID  (query-before-add: accurate + idempotent)
  if user_in_group "$1" "$2"; then log "user $1 already in group $2"; else
    occ group:adduser "$2" "$1" >/dev/null 2>&1 && log "user $1 added to group $2"; fi
}

# --- group folders: groupfolders:create is NOT idempotent by name, so ALWAYS query first ---
groupfolder_id() {  # MOUNT -> prints the folder id, or empty
  occ groupfolders:list --output=json 2>/dev/null | python3 -c \
    'import sys,json
d=json.load(sys.stdin)
for r in (d.values() if isinstance(d,dict) else d):
    if r.get("mount_point")==sys.argv[1]:
        print(r.get("id")); break' "$1" 2>/dev/null
}
ensure_groupfolder() {  # MOUNT -> ensures it exists, prints its id
  local mount="$1" id
  id="$(groupfolder_id "$mount")"
  if [ -n "$id" ]; then log "groupfolder '$mount' exists (id $id)"; else
    id="$(occ groupfolders:create "$mount" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    log "groupfolder '$mount' created (id $id)"; fi
  printf '%s\n' "$id"
}

# --- content fixtures (query-before-create): put a file in a user's Files, then index it ---
ensure_sample_file() {  # UID RELPATH CONTENT
  local uid="$1" rel="$2" content="$3" base="data/$1/files"
  if docker compose exec -T --user www-data nextcloud test -f "/var/www/html/$base/$rel" 2>/dev/null; then
    log "file $uid:$rel exists"; return 0
  fi
  docker compose exec -T --user www-data -e SAMPLE="$content" nextcloud \
    sh -c "mkdir -p '/var/www/html/$base' && printf '%s' \"\$SAMPLE\" > '/var/www/html/$base/$rel'"
  occ files:scan "$uid" >/dev/null 2>&1 || true
  log "file $uid:$rel created + indexed"
}
