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
# One `config:list` per phase feeds every read below, instead of one `config:*:get` per key.
#
# NOT `--private`: that flag adds the instance's crypto material — dbpassword, secret, passwordsalt
# — to a variable this process would then hold for the rest of the phase. Nothing here needs them.
#
# What it does NOT buy is a secret-free cache, and it is worth being exact about that rather than
# comfortable. Nextcloud's redaction follows its own sensitivity flags, which are narrower than
# intuition: `theming` slogan/url/imprintUrl/privacyUrl come back ***REMOVED SENSITIVE VALUE***,
# while `eurooffice jwt_secret` comes back in the clear. So this cache does hold one app secret.
# It is not a new exposure — seed.sh sources .env, so OFFICE_JWT_SECRET is already in this same
# process — but do not add `set -x` to a phase, and do not print CONF_CACHE.
#
# conf_get re-reads the redacted keys individually rather than trading the whole config for them.
#
# Unlike the group caches further down, this one is NOT written back after a set: no phase reads a
# key it just wrote. If one ever does, the stale read costs a redundant write of the SAME value —
# same final state, and scripts/seed-idempotent.sh reports it rather than hiding it.
# Per-phase, like every cache here: seed.sh's subshell-per-phase resets it (see below).
CONF_CACHE=""
conf_load() {
  [ -n "$CONF_CACHE" ] && return 0
  CONF_CACHE="$(occ config:list --output=json 2>/dev/null)"
}

# Prints a value from the cached listing, and EXITS 1 WHEN THE KEY IS ABSENT. That distinction is
# the reason this helper exists rather than a plain lookup.
#
# An unset key and a key set to "" both read back as the empty string, so a plain
# `[ "$cur" = "$val" ]` treats "set this to empty" as already-done and never writes. Not
# hypothetical: `customclient_ios_appid ""` (the iOS banner kill) logged "already = " on a fresh
# instance and the banner stayed up — caught in a browser on 2026-07-27, not by a gate. The old code
# recovered the distinction from occ's exit status, which also meant every read needed `|| rc=1` to
# stop an unset key from killing the phase under pipefail + set -e. Here it is structural: the key
# is either a member of the JSON object or it is not. Nothing to remember, nothing to forget.
#
# Values are rendered EXACTLY as `occ config:*:get` prints them, because that is what every
# comparison in this file was written against:
#   bool -> "1" / ""   int -> "0"   str -> verbatim, empty string included
# The bool case is load-bearing. `theming disable-user-theming` comes back from config:list as JSON
# `true`, while occ prints `1` — which is the STORED_FORM theming_set already passes. Render it
# "true" and that key rewrites itself on every single seed.
#
# CALL conf_load FROM THE CALLER, never from here — same subshell trap documented at groupfolder_id:
# every caller reads through `cur="$(conf_get …)"`, and a cache filled inside a command substitution
# dies with it.
conf_get() {  # system KEY | app APP KEY
  local out
  out="$(printf '%s' "$CONF_CACHE" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if sys.argv[1] == "system":
    node, key = d.get("system", {}), sys.argv[2]
else:
    node, key = d.get("apps", {}).get(sys.argv[2], {}), sys.argv[3]
if key not in node: sys.exit(1)
v = node[key]
print(("1" if v else "") if isinstance(v, bool) else v if isinstance(v, str) else json.dumps(v))
' "$@")" || return 1
  # A redacted value is not a value. Fall back to a direct read for just that key — which keeps this
  # correct for any key Nextcloud decides to flag in future, with no list here to maintain.
  if [ "$out" = "***REMOVED SENSITIVE VALUE***" ]; then
    case "$1" in
      system) out="$(occ config:system:get "$2" 2>/dev/null | tr -d '\r')" || return 1 ;;
      *)      out="$(occ config:app:get "$2" "$3" 2>/dev/null | tr -d '\r')" || return 1 ;;
    esac
  fi
  printf '%s\n' "$out"
}

# Optional TYPE (string|integer|double|boolean) is passed through to occ. occ defaults to
# "string", and Nextcloud's getSystemValueInt()/Bool() cast on read, so omitting it is harmless
# for behaviour — but a numeric key then sits in config.php quoted, which misreports its own type
# to the next reader. Pass it where the documented type is not a string.
config_system_set() {  # KEY VALUE [TYPE]
  local key="$1" val="$2" type="${3:-}" cur
  conf_load
  if cur="$(conf_get system "$key")" && [ "$cur" = "$val" ]; then
    log "system:$key already = $val"
  elif [ -n "$type" ]; then
    occ config:system:set "$key" --type="$type" --value="$val" >/dev/null && log "system:$key -> $val ($type)"
  else
    occ config:system:set "$key" --value="$val" >/dev/null && log "system:$key -> $val"
  fi
}

app_config_set() {  # APP KEY VALUE
  local app="$1" key="$2" val="$3" cur
  conf_load
  if cur="$(conf_get app "$app" "$key")" && [ "$cur" = "$val" ]; then log "app:$app:$key already = $val"; else
    occ config:app:set "$app" "$key" --value="$val" >/dev/null && log "app:$app:$key -> $val"; fi
}

# Reads through the cached app config (where theming:config stores) but WRITES through
# theming:config, so any side effects of the theming command still happen.
#
# STORED_FORM exists because for boolean keys the value you must WRITE differs from the value
# Nextcloud STORES: `disable-user-theming` only accepts 'yes'/'true' (ThemingController tests
# `$value === 'yes' || $value === 'true'`) but persists it as `1` via setAppValueBool. Without
# this, the comparison never matches and the key is rewritten on every seed. Defaults to VALUE.
theming_set() {  # KEY VALUE [STORED_FORM]
  local key="$1" val="$2" stored="${3:-$2}" cur
  conf_load
  cur="$(conf_get app theming "$key")" || cur=""
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

# --- per-phase query caches ---
#
# The guard helpers below used to ask the server once per ITEM: 27 `group:list` calls to create 27
# groups, another 25 `groupfolders:list` to place 25 ACLs. Every one of those is a
# `docker compose exec` at ~0.8 s, so most of `make seed`'s wall clock was spent re-reading a list
# that had not changed since the line above.
#
# Each cache fills on FIRST use and is updated in place on every write, so it cannot go stale
# within a phase. It cannot go stale ACROSS phases either, and that falls out of the runner rather
# than from care taken here: seed.sh runs each phase in its own subshell, so these variables revert
# to the parent's empty value at every phase boundary and the first helper to need one re-reads the
# server. A phase always sees what the phases before it did — which is AD-2's rule (cross-phase
# state goes through Nextcloud, never through shell vars) holding unchanged.
GROUPS_CACHE=""
GF_CACHE=""

# --- groups (query-before-create) ---
#
# `group:list --output=json` returns {gid: [members]}, so ONE call answers both questions the
# phases ask: does this group exist, and is this user in it. Cached as one line per gid plus one
# "gid<TAB>uid" line per membership — a bare gid line can never collide with a membership line,
# so `grep -qxF` is an exact test for either.
groups_load() {
  [ -n "$GROUPS_CACHE" ] && return 0
  GROUPS_CACHE="$(occ group:list --output=json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
if isinstance(d, list): d = {gid: [] for gid in d}
for gid, members in d.items():
    print(gid)
    for uid in members: print(f"{gid}\t{uid}")
')"
}
group_exists() {  # GID
  groups_load; printf '%s\n' "$GROUPS_CACHE" | grep -qxF "$1"
}
ensure_group() {  # GID [DISPLAY]
  local gid="$1" display="${2:-}"
  if group_exists "$gid"; then log "group $gid exists"; return 0; fi
  if [ -n "$display" ]; then
    occ group:add --display-name="$display" "$gid" >/dev/null && log "group $gid created ($display)"
  else
    occ group:add "$gid" >/dev/null && log "group $gid created"
  fi
  # Only reached when the create SUCCEEDED: the `&&` above leaves a non-zero status on failure and
  # every phase runs under `set -e`, so a failed create aborts before it can be cached as present.
  GROUPS_CACHE="$gid"$'\n'"$GROUPS_CACHE"
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
# Membership comes from the same cached listing as existence — the separate `user:info` query this
# used to run answered a question `group:list` had already answered for free.
add_user_to_group() {  # UID GID  (query-before-add: accurate + idempotent)
  groups_load
  if printf '%s\n' "$GROUPS_CACHE" | grep -qxF "$2"$'\t'"$1"; then
    log "user $1 already in group $2"; return 0
  fi
  occ group:adduser "$2" "$1" >/dev/null 2>&1 && log "user $1 added to group $2"
  GROUPS_CACHE="$2"$'\t'"$1"$'\n'"$GROUPS_CACHE"
}

# --- apps (install-or-enable; idempotent) ---
ensure_app() {  # APPID
  local app="$1" err
  conf_load
  [ "$(conf_get app "$app" enabled 2>/dev/null || true)" = "yes" ] && { log "app $app enabled"; return 0; }
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
  want="$(printf '"%s",' "$@")"; want="[${want%,}]"
  conf_load; cur="$(conf_get app "$app" enabled)" || cur=""
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
  conf_load; cur="$(conf_get app "$app" enabled)" || cur=""
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
#
# One listing answers everything phases 30 and 40 ask: `groupfolders:list --output=json` carries
# `groups_list` ({gid: permission bits}) alongside the mount point and id. Cached as one
# "mount<TAB>id" line per folder plus one "mount<TAB>gid<TAB>perms" line per grant; the field count
# tells the two apart. Compared with awk, not a regex — mount points contain spaces, slashes and
# accents (`Unidades/Estadística-REM`), none of which survive being pasted into a pattern.
# NB: the groupfolders app (v22+) uses the JSON key `mountPoint` (camelCase). Accept the older
# `mount_point` too for safety.
gf_load() {
  [ -n "$GF_CACHE" ] && return 0
  GF_CACHE="$(occ groupfolders:list --output=json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
for r in (d.values() if isinstance(d, dict) else d):
    mount = r.get("mountPoint") or r.get("mount_point")
    folder_id = r.get("id")
    print(f"{mount}\t{folder_id}")
    for gid, perms in (r.get("groups_list") or {}).items():
        print(f"{mount}\t{gid}\t{perms}")
')"
}
# CALL gf_load FROM THE CALLER, never from groupfolder_id. Every caller reads the id through
# `id="$(groupfolder_id …)"`, and a command substitution runs in a SUBSHELL — so a gf_load in here
# fills a cache that dies with the substitution, leaving the parent's copy empty (or, after the
# first write, holding only that write, which then reads back as "folder not found"). Both
# symptoms, one cause. groupfolder_id is a pure reader; loading is the caller's job.
groupfolder_id() {  # MOUNT -> prints the folder id, or empty
  printf '%s\n' "$GF_CACHE" | awk -F'\t' -v m="$1" 'NF==2 && $1==m {print $2; exit}'
}
ensure_groupfolder() {  # MOUNT -> ensures it exists, prints its id
  local mount="$1" id
  gf_load; id="$(groupfolder_id "$mount")"
  if [ -n "$id" ]; then log "groupfolder '$mount' exists (id $id)"; else
    id="$(occ groupfolders:create "$mount" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    log "groupfolder '$mount' created (id $id)"
    # Prepended, not appended: the lookups above stop at the first match, so the freshest line wins.
    GF_CACHE="$mount"$'\t'"$id"$'\n'"$GF_CACHE"; fi
  printf '%s\n' "$id"
}
# Grant a group access to a group folder (allow-only; empty perms = read-only).
#
# Query-before-set, like every other guard here. `groupfolders:group` builds its bitmask as
# READ|<each word> starting from 1 (apps/groupfolders/lib/Command/Group.php:91-103: read=1,
# write=UPDATE|CREATE=6, share=16, delete=8), and `groups_list` reports exactly that integer back —
# so the current value IS the comparison, no separate state to track. Same trick as
# app_restrict_to_groups.
#
# This used to re-apply every grant unconditionally, which was harmless but indistinguishable in
# the log from a real write — and the log is what scripts/seed-idempotent.sh reads to decide
# whether a second seed changed anything. An unconditional write there would have made that gate
# permanently red and therefore worthless.
gf_grant() {  # MOUNT GROUP [read] [write] [share] [delete]
  local mount="$1" group="$2"; shift 2
  local id want=1 cur p
  gf_load; id="$(groupfolder_id "$mount")"
  [ -n "$id" ] || { log "groupfolder '$mount' not found — cannot grant $group"; return 1; }
  for p in "$@"; do case "$p" in
    read)   ;;
    write)  want=$((want | 6));;
    share)  want=$((want | 16));;
    delete) want=$((want | 8));;
    # Unparseable: occ rejects it too (getNewPermissions returns 0). Force the write and let occ
    # fail loudly rather than silently deciding this grant was already in place.
    *)      want=0;;
  esac; done
  cur="$(printf '%s\n' "$GF_CACHE" | awk -F'\t' -v m="$mount" -v g="$group" 'NF==3 && $1==m && $2==g {print $3; exit}')"
  if [ "$cur" = "$want" ]; then log "grant '$mount' $group already [$want]"; return 0; fi
  occ groupfolders:group "$id" "$group" "$@" >/dev/null 2>&1 && log "grant '$mount' -> $group [${*:-read}]"
  GF_CACHE="$mount"$'\t'"$group"$'\t'"$want"$'\n'"$GF_CACHE"
}
# Create a text file inside a group folder's storage, then index it. Idempotent (test -f).
ensure_gf_file() {  # MOUNT RELPATH CONTENT
  local mount="$1" rel="$2" content="$3" id; gf_load; id="$(groupfolder_id "$mount")"
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
  local mount="$1" sub="$2" id; gf_load; id="$(groupfolder_id "$mount")"
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
