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
#
# Every helper below reads the current value first. `occ config:*:get` exits 1 when the key is
# UNSET, and seed.sh runs with `pipefail` while each phase adds `set -e` — so the read of a
# not-yet-configured key would abort the whole phase, silently, because stderr is discarded.
# That is why each read ends in `|| cur=""`: an unset key is a legitimate answer ("no value"),
# not an error. Do not remove it — the failure mode is a phase that dies with no message.
# An UNSET key and a key set to "" both read back as the empty string, so a plain
# `[ "$cur" = "$val" ]` treats "set this to empty" as already-done and never writes. That is
# not hypothetical: `customclient_ios_appid ""` (the iOS banner kill) logged "already = " on a
# fresh instance and the banner stayed up — caught in the browser on 2026-07-27, not by a gate.
# So capture whether the READ succeeded: occ config:*:get exits non-zero when the key is unset.
# Keep the `|| rc=1` — it is what stops the read from killing the phase under pipefail + set -e
# when the key does not exist yet (see BUGS.md, fixed in 26dd40f).
# Optional TYPE (string|integer|double|boolean) is passed through to occ. occ defaults to
# "string", and Nextcloud's getSystemValueInt()/Bool() cast on read, so omitting it is harmless
# for behaviour — but a numeric key then sits in config.php quoted, which misreports its own type
# to the next reader. Pass it where the documented type is not a string.
config_system_set() {  # KEY VALUE [TYPE]
  local key="$1" val="$2" type="${3:-}" cur rc
  cur="$(occ config:system:get "$key" 2>/dev/null | tr -d '\r')" && rc=0 || rc=1
  if [ "$rc" -eq 0 ] && [ "$cur" = "$val" ]; then
    log "system:$key already = $val"
  elif [ -n "$type" ]; then
    occ config:system:set "$key" --type="$type" --value="$val" >/dev/null && log "system:$key -> $val ($type)"
  else
    occ config:system:set "$key" --value="$val" >/dev/null && log "system:$key -> $val"
  fi
}

app_config_set() {  # APP KEY VALUE
  local app="$1" key="$2" val="$3" cur rc
  cur="$(occ config:app:get "$app" "$key" 2>/dev/null | tr -d '\r')" && rc=0 || rc=1
  if [ "$rc" -eq 0 ] && [ "$cur" = "$val" ]; then log "app:$app:$key already = $val"; else
    occ config:app:set "$app" "$key" --value="$val" >/dev/null && log "app:$app:$key -> $val"; fi
}

# Reads through config:app:get (where theming:config stores) but WRITES through
# theming:config, so any side effects of the theming command still happen.
#
# STORED_FORM exists because for boolean keys the value you must WRITE differs from the value
# Nextcloud STORES: `disable-user-theming` only accepts 'yes'/'true' (ThemingController tests
# `$value === 'yes' || $value === 'true'`) but persists it as `1` via setAppValueBool. Without
# this, the comparison never matches and the key is rewritten on every seed. Defaults to VALUE.
theming_set() {  # KEY VALUE [STORED_FORM]
  local key="$1" val="$2" stored="${3:-$2}" cur
  cur="$(occ config:app:get theming "$key" 2>/dev/null | tr -d '\r')" || cur=""
  if [ "$cur" = "$stored" ]; then log "theming:$key already = $val"; else
    occ theming:config "$key" "$val" >/dev/null && log "theming:$key -> $val"; fi
}

# Brand images. Deliberately NOT query-before-set: theming:config stores <key>Mime,
# not the path, so a changed file with an unchanged mime is undetectable — comparing
# would make `make seed` silently ignore an edited SVG. Re-registering every run is
# cheap (four small files) and is what makes editing an asset actually propagate.
# PATH must be absolute and resolvable INSIDE the container; themes/ is bind-mounted.
# Writes UNCONDITIONALLY, and that is deliberate — do not "fix" it into query-before-set.
# theming:config stores the image bytes in appdata plus a <key>Mime entry; it does not store the
# source path, so there is nothing to compare against that would notice the FILE changed. A
# query-before-set here would mean edits to the SVGs never reach the instance. Cost of the
# unconditional write: every `make seed` bumps the theming cachebuster. That is the cheaper bug.
theming_image_set() {  # KEY ABSOLUTE_PATH
  local key="$1" path="$2"
  occ theming:config "$key" "$path" >/dev/null && log "theming:$key <- $path"
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

# --- apps (install-or-enable; idempotent) ---
ensure_app() {  # APPID
  local app="$1" err
  [ "$(occ config:app:get "$app" enabled 2>/dev/null | tr -d '\r')" = "yes" ] && { log "app $app enabled"; return 0; }
  # Keep occ's own error: it is the only thing that says WHY. Guessing a cause here once sent an
  # operator hunting file permissions when the real failure was an app store timeout (#41).
  if err="$(occ app:install "$app" 2>&1)" || err="$(occ app:enable "$app" 2>&1)"; then
    log "app $app installed/enabled"
  else
    log "FAILED to install/enable app $app — occ said: $(printf '%s' "$err" | tr '\n' ' ' | tail -c 300)"
    return 1
  fi
}

# Re-apply a file edit inside an app's code (ADR-0002). apps/ is gitignored, so these edits cannot
# be committed and an app update wipes them; running on every seed is what restores them.
#
# THREE outcomes, not two. `patch --dry-run` forward says it applies; in reverse it says it is
# ALREADY applied. Neither means upstream moved and the patch must be regenerated — that aborts
# the phase. The usual `--forward --dry-run && patch` idiom collapses that third case into the
# second, which is the silent no-op this repo has already paid for five times (see BUGS.md B-001
# and the sed it replaces here).
apply_patch() {  # APPID PATCHFILE
  local app="$1" p="$2" name; name="$(basename "$p")"
  local in="cd custom_apps/$app && patch -p1 --silent"
  if occ_sh "$in --dry-run" < "$p"; then
    occ_sh "$in" < "$p" && log "patch $app/$name applied"
  elif occ_sh "$in --dry-run --reverse" < "$p"; then
    log "patch $app/$name already applied"
  else
    log "FAILED patch $app/$name — no longer applies; upstream moved, regenerate it"; return 1
  fi
}
# Shell inside the nextcloud container, stdin forwarded (apply_patch pipes the .patch in).
occ_sh() { docker compose exec -T --user www-data nextcloud sh -c "$1" >/dev/null 2>&1; }

# Restrict an app to one or more groups: installed and available to those groups only, invisible
# to everyone else. The lever of choice over disabling, because a restricted app is still present
# for the custom apps on the roadmap to build on.
#
# AppManager::enableAppForGroups() stores json_encode($groupIds) in appconfig `enabled`
# (lib/private/App/AppManager.php:673), where a globally-enabled app stores the string "yes". So
# the current value IS the comparison — no separate state to track — and query-before-set is exact.
#
# NOT every app can be restricted. Apps declaring types filesystem / authentication / logging /
# prelogin / prevent_group_restriction are refused by Nextcloud, and `occ` fails with a clear
# message rather than silently enabling globally. Verified on 2026-07-28: nextcloud_announcements
# (logging), photos + federation (authentication), sharebymail + circles (filesystem) and logreader
# (logging) all refuse. For those the only levers are an app config switch or a full disable.
app_restrict_to_groups() {  # APP GROUP [GROUP...]
  local app="$1"; shift
  local want cur; local -a gargs=()
  local g; for g in "$@"; do gargs+=(--groups="$g"); done
  want="$(printf '%s' "$*" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read().split()))')"
  cur="$(occ config:app:get "$app" enabled 2>/dev/null | tr -d '\r')" || cur=""
  if [ "$cur" = "$want" ]; then log "app $app already restricted to $want"; return 0; fi
  if occ app:enable "${gargs[@]}" "$app" >/dev/null 2>&1; then
    log "app $app -> restricted to $want"
  else
    log "FAILED to restrict $app to $want — does it declare a blocking type?"; return 1
  fi
}

# Disable an app outright. Reserved for apps that cannot be restricted or whose behaviour is
# server-side and therefore unaffected by who can see them (see survey_client in 16-app-policy).
app_disable() {  # APPID
  local app="$1" cur
  cur="$(occ config:app:get "$app" enabled 2>/dev/null | tr -d '\r')" || cur=""
  # Nextcloud represents "not enabled" in TWO ways, and both are correct: the literal "no" (an app
  # that was enabled and then disabled) and an ABSENT key (an app never enabled on this instance).
  # `occ app:disable` on an app whose key is already absent is a no-op — it does NOT write "no" —
  # so anything asserting the literal "no" will fail forever on a fresh instance. Measured
  # 2026-07-29 by deleting the key and re-seeding: the phase logged success and the value stayed
  # unset. Treat both as disabled here, and make any gate accept both too.
  if [ "$cur" = "no" ] || [ -z "$cur" ]; then log "app $app already disabled"; return 0; fi
  occ app:disable "$app" >/dev/null 2>&1 && log "app $app -> disabled"
}

# --- group folders: groupfolders:create is NOT idempotent by name, so ALWAYS query first ---
# NB: the groupfolders app (v22+) uses the JSON key `mountPoint` (camelCase). Accept the older
# `mount_point` too for safety.
groupfolder_id() {  # MOUNT -> prints the folder id, or empty
  occ groupfolders:list --output=json 2>/dev/null | python3 -c \
    'import sys,json
d=json.load(sys.stdin)
for r in (d.values() if isinstance(d,dict) else d):
    if (r.get("mountPoint") or r.get("mount_point"))==sys.argv[1]:
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
# Grant a group access to a group folder (allow-only; empty perms = read-only). Idempotent.
gf_grant() {  # MOUNT GROUP [read] [write] ...
  local mount="$1" group="$2"; shift 2
  local id; id="$(groupfolder_id "$mount")"
  [ -n "$id" ] || { log "groupfolder '$mount' not found — cannot grant $group"; return 1; }
  occ groupfolders:group "$id" "$group" "$@" >/dev/null 2>&1 && log "grant '$mount' -> $group [${*:-read}]"
}
# Create a text file inside a group folder's storage, then index it. Idempotent (test -f).
ensure_gf_file() {  # MOUNT RELPATH CONTENT
  local mount="$1" rel="$2" content="$3" id; id="$(groupfolder_id "$mount")"
  [ -n "$id" ] || { log "groupfolder '$mount' not found — cannot write $rel"; return 1; }
  local path="/var/www/html/data/__groupfolders/$id/$rel"
  if docker compose exec -T --user www-data nextcloud test -f "$path" 2>/dev/null; then
    log "  file $mount/$rel exists"; return 0; fi
  docker compose exec -T --user www-data -e GFC="$content" nextcloud sh -c "printf '%s' \"\$GFC\" > '$path'"
  occ groupfolders:scan "$id" >/dev/null 2>&1 || true
  log "  file $mount/$rel created"
}
# Create a regular subfolder inside a group folder's storage, then index it. Idempotent (test -d).
ensure_gf_subfolder() {  # MOUNT SUBFOLDER
  local mount="$1" sub="$2" id; id="$(groupfolder_id "$mount")"
  [ -n "$id" ] || { log "groupfolder '$mount' not found — cannot add $sub"; return 1; }
  local path="/var/www/html/data/__groupfolders/$id/$sub"
  if docker compose exec -T --user www-data nextcloud test -d "$path" 2>/dev/null; then
    log "  subfolder $mount/$sub exists"; return 0; fi
  docker compose exec -T --user www-data nextcloud mkdir -p "$path"
  occ groupfolders:scan "$id" >/dev/null 2>&1 || true
  log "  subfolder $mount/$sub created"
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
