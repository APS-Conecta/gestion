#!/usr/bin/env bash
# provisioning/lib.sh — shared idempotency-guard helpers for the phase files (Story 0.5, AD-2).
# Sourced by seed.sh, which then sources each phase; every mutating helper is QUERY-BEFORE-CREATE:
# it inspects current state and skips/patches rather than blind-creating, so the seed is safe to
# re-run. Source this file; do not execute it. Host has python3 (no jq assumed) for JSON parsing.
#
# REQUIRES scripts/env.sh to have been sourced first — it provides occ() and nc_exec(), the docker-
# exec seam every helper below rides; raw sites pass their options before nc_exec's `--`. seed.sh
# sources them in that order.

# --- logging ---
log()         { printf '    %s\n' "$*"; }
# org L5-03: phases only make sense inside the seed runner, which exports SEED_CTX after
# sourcing the site file. Run standalone, a phase loops over unset SITE_* arrays and exits
# green having written nothing — the silent no-op this guard turns into a named refusal.
phase_begin() {
  if [ -z "${SEED_CTX:-}" ]; then
    echo "FATAL: phase ${1} run outside the seed — standalone phases are a silent no-op." >&2
    echo "       Run the whole runner: bash provisioning/seed.sh  (phases see the site file this way)." >&2
    exit 1
  fi
  CURRENT_PHASE="$1"; printf '▶ phase %s — %s\n' "$1" "${2:-}"
}
phase_end()   { printf '✓ phase %s\n' "${CURRENT_PHASE:-?}"; }

# --- preconditions ---
require_installed() {  # the FATAL names the container, and an override that misses the running suite
  nc_container   # here, not inside the pipe below, so the message can name it
  occ status --output=json 2>/dev/null | grep -q '"installed":true' && return 0
  echo "FATAL: Nextcloud is not installed/reachable in $NC_CONTAINER." >&2
  if [ "$NC_CONTAINER" != "$AIO_NC" ] && is_aio; then
    echo "  The AIO stack is running, but NC_CONTAINER=$NC_CONTAINER (environment or .env) overrides it — delete that line from .env." >&2
  fi
  exit 1
}

# --- idempotent config: set only if the current value differs ---
#
# One `config:list` per phase feeds every read below. NOT `--private`: it would pull
# dbpassword/secret/passwordsalt into a variable nothing here needs. Not secret-free either —
# `theming` slogan/url come back REMOVED but `eurooffice jwt_secret` comes back in the clear, so
# never `set -x` in a phase and never print CONF_CACHE. Not written back after a set: a stale read
# costs one redundant write, which seed-idempotent.sh reports rather than hides.
CONF_CACHE=""
conf_load() {
  [ -n "$CONF_CACHE" ] && return 0
  CONF_CACHE="$(occ config:list --output=json 2>/dev/null)"
}

# Prints a value from the cached listing, and EXITS 1 WHEN THE KEY IS ABSENT. That distinction is
# the whole reason this exists rather than a plain lookup: an unset key and a key set to "" both
# read back empty, so `[ "$cur" = "$val" ]` treats "set this to empty" as already-done and never
# writes. That is how `customclient_ios_appid ""` logged "already = " on a fresh instance while the
# iOS banner stayed up (B-009 family). Membership in the JSON object is structural — nothing to
# remember.
#
# Values render EXACTLY as `occ config:*:get` prints them, which is what every comparison here was
# written against:  bool -> "1" / ""   int -> "0"   str -> verbatim, empty included.
# The bool case is load-bearing: `disable-user-theming` is JSON `true` in config:list but `1` from
# occ, and rendering it "true" makes that key rewrite itself on every seed.
#
# CALL conf_load FROM THE CALLER, never from here — same subshell trap documented at groupfolder_id.
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
  local key="$1" val="$2" type="${3:-}" cur want="$2"
  # a boolean reads back the way conf_get renders it ("1" / ""), never as the word it was set with
  if [ "$type" = boolean ]; then case "$val" in true|1) want=1 ;; *) want="" ;; esac; fi
  conf_load
  if cur="$(conf_get system "$key")" && [ "$cur" = "$want" ]; then
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
  # Folded into the `if`, exactly like app_config_set above, and for the reason conf_get returns
  # non-zero at all: `|| cur=""` collapses "key is absent" into "key is empty", so a STORED_FORM
  # of "" would compare equal on an instance that has never had the key and the write would be
  # skipped for ever. Inert today — every call site passes a non-empty literal — which is why it
  # is worth closing now rather than after someone adds the first empty one.
  if cur="$(conf_get app theming "$key")" && [ "$cur" = "$stored" ]; then log "theming:$key already = $val"; else
    occ theming:config "$key" "$val" >/dev/null && log "theming:$key -> $val"; fi
}

# Brand images. Writes UNCONDITIONALLY — do not "fix" this into query-before-set. theming:config
# stores the image bytes plus a <key>Mime entry, never the source path, so there is nothing to
# compare that would notice the FILE changed: a guard here would mean an edited SVG never reaches
# the instance. Cost of writing every run is a bumped theming cachebuster. That is the cheaper bug.
# PATH must be absolute and resolvable INSIDE the container; themes/ is bind-mounted.
theming_image_set() {  # KEY ABSOLUTE_PATH
  local key="$1" path="$2"
  occ theming:config "$key" "$path" >/dev/null && log "theming:$key <- $path"
}

# --- per-phase query caches ---
#
# The guards below used to ask the server once per ITEM — 27 `group:list` calls to create 27 groups
# — and every one is a `docker exec` at ~0.8 s. Each cache fills on first use and is
# updated in place on every write, so it cannot go stale within a phase; seed.sh's subshell-per-
# phase resets it at every boundary, so it cannot go stale across phases either. AD-2's rule
# (cross-phase state goes through Nextcloud, never shell vars) holds unchanged.
GROUPS_CACHE=""
GF_CACHE=""
# The instance's data directory — same contract as the caches above: one read per phase. AIO
# installs it at /mnt/ncdata (--data-dir at install); a hardcoded path in the content helpers below
# would let phase 30/60 write a phantom tree with every gate green — the silent-green class this
# repo exists never to repeat.
# Fails CLOSED: an unreadable datadirectory is never guessed at, so a data path can only be built
# from an answer the instance actually gave.
DATADIR=""
datadir_load() {
  [ -n "$DATADIR" ] && return 0
  DATADIR="$(occ config:system:get datadirectory 2>/dev/null | tr -d '\r')" || DATADIR=""
  [ -n "$DATADIR" ] || { log "cannot read datadirectory — data paths cannot be answered, refusing to guess"; return 1; }
}

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
ensure_group() {  # GID DISPLAY
  local gid="$1" display="$2"
  if group_exists "$gid"; then log "group $gid exists"; return 0; fi
  # occ runs as a plain command, NOT as the left side of `&&`. errexit ignores a failure inside an
  # `&&` list, so `occ … && log …` followed by any further statement returns 0 and the phase carries
  # on past a failed create. That is how B-001 looked: a green seed that had skipped its work.
  occ group:add --display-name="$display" "$gid" >/dev/null
  log "group $gid created ($display)"
  GROUPS_CACHE="$gid"$'\n'"$GROUPS_CACHE"
}

# --- users (query-before-create) ---
user_exists() { occ user:info "$1" >/dev/null 2>&1; }  # UID
ensure_user() {  # UID DISPLAY PASSWORD
  local uid="$1" display="$2" pass="$3"
  if user_exists "$uid"; then log "user $uid exists"; return 0; fi
  # Docker copies the named variable from its client environment.
  if OC_PASS="$pass" nc_exec --user www-data -e OC_PASS -- \
       php /var/www/html/occ user:add --password-from-env --display-name="$display" "$uid" >/dev/null; then
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
  # Plain command, and stderr kept: see ensure_group. occ's message is the only thing that says why.
  occ group:adduser "$2" "$1" >/dev/null
  log "user $1 added to group $2"
  GROUPS_CACHE="$2"$'\t'"$1"$'\n'"$GROUPS_CACHE"
}

# The IntraVox group map (D5): the engine's own groups follow the registry's — adds-only,
# query-before-set, one group:list json answers both sides. Phase 41 runs it once the engine's
# setup has created the groups; phase 50 runs it again after the standing accounts exist, which on
# a fresh instance they do not when phase 41 runs — without that second call the first seed maps
# nobody and the second seed writes (B-030, Clean boot's seed-idempotent). Admins: engine default
# (setup seeds NC admins once). Adds-never-deletes: membership only grows; leavers keep read —
# harmless, recorded (D5).
intravox_group_map() {
  local _json; _json="$(occ group:list --output=json 2>/dev/null)"
  _iv_gmap() {  # SRC_GID ENGINE_GID — add every member of SRC present in the live roster
    local _uid
    for _uid in $(printf '%s' "$_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for uid in (d.get(sys.argv[1]) or []): print(uid)' "$1"); do
      printf '%s' "$_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
sys.exit(0 if sys.argv[2] in (d.get(sys.argv[1]) or []) else 1)' "$2" "$_uid" && continue
      occ group:adduser "$2" "$_uid" >/dev/null
      log "  group: $_uid added to group $2"
    done
  }
  _iv_gmap all-staff     'IntraVox Users'
  _iv_gmap cat-jefaturas 'IntraVox Editors'
  _iv_gmap role-oirs     'IntraVox Editors'   # registry gid is role-oirs (20-groups.sh:49); the
  # design text said role-encargado-oirs, which does not exist — plan-local fix, design follow-up
}

# The version of an app as the INSTANCE has it, read in-container from custom_apps — the bake-wins
# probe, shared by both app helpers below. A host-side read would be blind under AIO: no bind mount
# means no host-side file, the probe answers "" for every app, `cur=""` means re-impose, and
# seed-idempotent stays permanently red. The instance is the only source of truth for what the
# instance runs.
# ONE exec, no guard: awk's own open-failure IS the absent-app answer (a fresh install has not
# unpacked anything yet), so `|| true` keeps the set -e/pipefail phases alive and empty output
# carries the meaning the old `cur=""` initialization did. A transport-level failure reads the
# same as "absent" and fails LOUDLY one step later at the unpack/enable.
# busybox awk (the AIO image's Alpine base) parses -F'[<>]' identically to gawk — verified.
app_installed_version() {  # APPID -> prints the installed version, or nothing when absent
  local app="$1"
  nc_exec --user www-data -- awk -F'[<>]' '/<version>/ {print $3; exit}' \
    "/var/www/html/custom_apps/$app/appinfo/info.xml" 2>/dev/null || true
}

# --- apps from the store, scoped (#42) ---
#
# THE STORE OPENS ONE COMMAND AT A TIME. No image carries an app, and the store is off
# instance-wide — NC_appstoreenabled="0" is baked into the aio-nextcloud image and Config.php's
# envCache beats config.php, so every bare store leg fails fast. The one exception is
# occ_store: the command carries its own NC_appstoreenabled=1, which beats both the file and
# the image ENV for that process alone, and dies with it. A bare app:install anywhere under
# provisioning/ is the acquisition gate's row to catch — never this file's habit.
#
# NO PIN, BY DESIGN — #98's reasoning, closed by #42. The vendored tarball pinned a version
# because the bake served fixed bytes; the store row installs the newest release compatible
# with the running Nextcloud, ONCE. Convergence is presence + enabled, never "whatever is
# newest": nothing here updates, so a warm server is left alone (apps move only when the
# operator decides, `aps-conecta actualizar`), and a repair re-run installs only what is
# missing. The store's tarball is unmodified upstream, so its own signature.json stays true
# and the integrity check stays green — nothing here patches it (#82's rule, unchanged).
occ_store() {  # OCC_ARGS… — one occ call with the store open, for this command alone
  nc_exec -e NC_appstoreenabled=1 --user www-data -- php /var/www/html/occ "$@"
}

ensure_store_app() {  # APPID — install the store's newest compatible release, scoped, once
  local app="$1" cur err
  cur="$(app_installed_version "$app")"
  if [ -n "$cur" ]; then
    log "app $app $cur already installed (the store's, untouched — nothing here updates)"
  else
    # Keep occ's own error: it is the only thing that says WHY (a guessed cause once sent an
    # operator hunting file permissions when the real failure was a store timeout, #41).
    if err="$(occ_store app:install "$app" 2>&1)"; then
      log "app $app -> installed from the store (NC_appstoreenabled=1, scoped to this command)"
    else
      log "FAILED to install $app from the store — occ said: $(printf '%s' "$err" | tr '\n' ' ' | tail -c 300)"
      return 1
    fi
  fi

  conf_load || return 1
  [ "$(conf_get app "$app" enabled 2>/dev/null || true)" = "yes" ] && { log "app $app enabled"; return 0; }
  # `app:enable` reads what is on disk and never contacts the store — no scope needed.
  if err="$(occ app:enable "$app" 2>&1)"; then
    log "app $app -> enabled"
  else
    log "FAILED to enable app $app — occ said: $(printf '%s' "$err" | tr '\n' ' ' | tail -c 300)"
    return 1
  fi
}

# ── apps from their own releases (ADR-0017, #33) ──
#
# The release path installs what the LOCK names — the fetch leg (the wizard's ejecutar, the
# silent install, the weekly reponer — all `provisionador.py --paso generar`) resolved it,
# downloaded it, verified it against apps.pub and recorded tag/version/sha. THIS side never
# downloads: the seed's whole contract is convergence over what is already on the server, so a
# missing or drifted package is a named FAILED that re-running the install repairs, never a
# silent network fetch mid-seed (the store stayed out of the seed for exactly this reason, #98).
app_elegida() {  # APPID — exit 0 when the operator chose APPID, non-zero when not (#39). The
                 # wizard's options record answers — the same file the host CLI writes at step 6
                 # and the fetch leg reads; anything but an explicit `APPID=1` (no record, no key,
                 # a 0) reads NOT chosen. An optional app installs only by that choice: no lock
                 # row, no release, no store install. Un-choosing on a warm server keeps what
                 # runs (nothing here uninstalls), exactly the manifest flip-back's doctrine:
                 # `occ app:remove`, by hand.
  local archivo="${APS_APPS_OPCIONES:-${AIO_STATE:-/opt/aps-conecta/aio}/opciones}"
  [ -f "$archivo" ] && tr ' ' '\n' < "$archivo" | grep -qx -- "$1=1"
}
lock_row() {  # APPID — the lock's row (tag<TAB>version<TAB>sha256<TAB>tarball), or nothing when
               # the lock names no such app. A lock that exists but cannot be read is FATAL here:
               # falling to the vendored bake would silently re-impose an older app over a live
               # server — the lock is the server's own record, and it outranks the bake.
  local out rc=0
  out="$(python3 "$HERE/../scripts/releases.py" locked "$1")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "FAILED $1 — the lock refused to answer (its FATAL line is above)"
    return 1
  fi
  printf '%s\n' "$out"
}

ensure_release_app() {  # APPID ROW — install the release the lock names, from the stored tarball
  local app="$1" tag want sha tgz cur
  IFS=$'\t' read -r tag want sha tgz <<< "$2"
  [ -n "$tag" ] && [ -n "$want" ] && [ -n "$sha" ] && [ -n "$tgz" ] \
    || { log "FAILED $app — the lock's row is incomplete"; return 1; }
  # The counted floors, in the order the trust chain proved them: the package is there, and it
  # is still the bytes the lock pinned (the store lives inside the backup scope, but a restore
  # or a hand copy is exactly the kind of event that must re-prove, never assume).
  [ -f "$tgz" ] || { log "FAILED $app — the release package $tgz is missing; re-run the install (its download step fetches it again)"; return 1; }
  echo "$sha  $tgz" | sha256sum --check --status \
    || { log "FAILED $app — $tgz does not match the sha256 recorded in the lock; re-run the install"; return 1; }

  cur="$(app_installed_version "$app")"

  # A release never carries appinfo/signature.json (the fetch refuses one that does), so the
  # file's presence on a same-version tree is PROOF the installed copy is not the release's
  # bytes. side_menu (#38) hits exactly this while the bake lives on (#42): the image bakes
  # upstream's 6.0.1 — same version the release ships, with the signature the release drops —
  # and a version comparison alone cannot tell the two apart. Converge on the release.
  if [ "$cur" = "$want" ] && ! occ_sh "test -e custom_apps/$app/appinfo/signature.json"; then
    log "app $app $want already unpacked (release $tag)"
  else
    # The re-impose discipline (cleared first so the result IS the release; schema reconciled
    # through the app's own migrations).
    if [ -n "$cur" ]; then
      occ_sh "rm -rf custom_apps/$app" \
        || { log "FAILED to clear $app before re-imposing $want"; return 1; }
    fi
    if nc_exec -i --user www-data -- \
         tar xzf - -C /var/www/html/custom_apps < "$tgz"; then
      if [ "$cur" = "$want" ]; then
        log "app $app $want re-imposed from release $tag (the installed tree carried appinfo/signature.json — not the release's bytes)"
      else
        log "app $app ${cur:+$cur }-> $want unpacked from release $tag"
      fi
    else
      log "FAILED to unpack $app from release $tag"; return 1
    fi
    if [ -n "$cur" ]; then
      if occ upgrade --no-interaction >/dev/null 2>&1; then
        log "app $app schema reconciled to $want (occ upgrade)"
      else
        log "FAILED to reconcile $app to $want — 'occ upgrade' errored; instance may be mid-upgrade"
        return 1
      fi
      CONF_CACHE=""   # installed_version moved under it
    fi
  fi

  conf_load || { log "FAILED $app — cannot read installed app configuration"; return 1; }
  [ "$(conf_get app "$app" enabled 2>/dev/null || true)" = "yes" ] && { log "app $app enabled"; return 0; }
  local err
  if err="$(occ app:enable "$app" 2>&1)"; then
    log "app $app -> enabled"
  else
    log "FAILED to enable app $app — occ said: $(printf '%s' "$err" | tr '\n' ' ' | tail -c 300)"
    return 1
  fi
}

# Shell inside the nextcloud container, stdin forwarded — hence -i: docker exec closes stdin
# without it. The FOLD: every occ_sh payload is web-root-relative (the re-impose clears and the
# signature probes), and the AIO image sets no WORKDIR, so docker exec
# starts them in / — folding the absolute cd into the ONE shared function fixes every caller at
# once. A failed cd is loud, which is the point: a payload that silently ran from / would be the
# B-014 seam-misparse class wearing a new hat.
# org L5-08: stderr is the diagnosis, stdout is noise. The old form threw both away, so a
# failing command printed only the caller's own FAILED line — #41's lesson ("occ's message
# is the only thing that says WHY") applied to the shell-channel twin. Stderr is captured,
# and its tail printed only on failure; success stays silent exactly as before.
occ_sh() {  # SHELL_COMMAND — runs inside the NC container, www-data, web root
  local _rc=0 _err
  _err="$(nc_exec -i --user www-data -- sh -c "cd /var/www/html && $1" 2>&1 >/dev/null)" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'occ_sh: failed (rc=%s): %s\n' "$_rc" "$1" >&2
    # tail, not all: a die() inside the command prints the whole web root's worth of context
    printf '%s\n' "$_err" | tail -n 5 >&2
  fi
  return "$_rc"
}

# Restrict an app to groups: installed and usable by them, invisible to everyone else. Preferred
# over disabling, because a restricted app is still there for the roadmap's custom apps to build on.
#
# enableAppForGroups() stores json_encode($groupIds) in appconfig `enabled` where a globally-enabled
# app stores "yes", so the current value IS the comparison and query-before-set is exact.
#
# NOT every app can be restricted: types filesystem/authentication/logging/prelogin/
# prevent_group_restriction are refused, loudly rather than by silently enabling globally. Verified
# 2026-07-28 — nextcloud_announcements, photos, federation, sharebymail, circles and logreader all
# refuse. For those the levers are an app config switch or a full disable.
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

# Enable an app globally. Query-before-enable, like app_disable below: the cached `enabled` value
# is "yes" for a globally enabled app, so a second seed reads it and writes nothing. (An app
# restricted to groups stores a JSON list there instead and is re-enabled globally by this call;
# use app_restrict_to_groups for those.)
app_enable() {  # APPID
  local app="$1" cur
  conf_load; cur="$(conf_get app "$app" enabled)" || cur=""
  if [ "$cur" = "yes" ]; then log "app $app already enabled"; return 0; fi
  if occ app:enable "$app" >/dev/null 2>&1; then
    log "app $app -> enabled"
  else
    log "FAILED to enable $app"; return 1
  fi
}

# Disable an app outright. Reserved for apps that cannot be restricted or whose behaviour is
# server-side and therefore unaffected by who can see them (see survey_client in 16-app-policy).
app_disable() {  # APPID
  local app="$1" cur
  conf_load; cur="$(conf_get app "$app" enabled)" || cur=""
  # "Not enabled" has TWO valid representations: the literal "no" (was enabled, then disabled) and
  # an ABSENT key (never enabled here). `occ app:disable` on an absent key is a no-op and does not
  # write "no", so asserting the literal fails forever on a fresh instance. Gates must accept both.
  if [ "$cur" = "no" ] || [ -z "$cur" ]; then log "app $app already disabled"; return 0; fi
  if occ app:disable "$app" >/dev/null; then log "app $app -> disabled"
  else log "FAILED to disable $app"; return 1; fi
}

# --- group folders: groupfolders:create is NOT idempotent by name, so ALWAYS query first ---
#
# One listing answers everything phases 30 and 40 ask: `groupfolders:list --output=json` carries
# `groups_list` ({gid: perms}) alongside the mount point and id. Cached as one "mount<TAB>id" line
# per folder plus one "mount<TAB>gid<TAB>perms" line per grant; the field count tells them apart.
# Matched with awk, not a regex — mount points contain spaces, slashes and accents
# (`Unidades/Estadística-REM`), none of which survive being pasted into a pattern.
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
ensure_groupfolder() {  # MOUNT -> ensures it exists
  local mount="$1" id
  gf_load; id="$(groupfolder_id "$mount")"
  if [ -n "$id" ]; then log "groupfolder '$mount' exists (id $id)"; else
    # stderr kept, and the id asserted: a failed create used to yield an empty id, which was logged
    # as "created (id )" and cached as if real, so every later grant reported "not found" instead of
    # naming the actual failure.
    id="$(occ groupfolders:create "$mount" | grep -oE '[0-9]+' | head -1)"
    [ -n "$id" ] || { log "FAILED to create groupfolder '$mount' — occ printed no id"; return 1; }
    log "groupfolder '$mount' created (id $id)"
    # Prepended, not appended: the lookups above stop at the first match, so the freshest line wins.
    GF_CACHE="$mount"$'\t'"$id"$'\n'"$GF_CACHE"; fi
}
# Grant a group access to a group folder (allow-only; empty perms = read-only).
#
# Query-before-set. `groupfolders:group` builds its bitmask as READ|<each word> from 1
# (Group.php:91-103: read=1, write=UPDATE|CREATE=6, share=16, delete=8) and `groups_list` reports
# that same integer back, so the current value IS the comparison. Guarding matters beyond speed:
# seed-idempotent.sh reads the log to decide whether a second seed changed anything, so an
# unconditional write here would make that gate permanently red and therefore worthless.
gf_grant() {  # MOUNT GROUP [read] [write] [share] [delete]
  local mount="$1" group="$2"; shift 2
  local id want=1 cur p
  gf_load; id="$(groupfolder_id "$mount")"
  [ -n "$id" ] || { log "groupfolder '$mount' not found — cannot grant $group"; return 1; }
  # `read` is a no-op ARM, not a dead one: want already starts at 1 (READ), and without an explicit
  # arm the word would fall through to the catch-all below and zero every grant in 40-acl.sh.
  for p in "$@"; do case "$p" in
    read)   ;;
    write)  want=$((want | 6));;
    share)  want=$((want | 16));;
    delete) want=$((want | 8));;
    # Unparseable: occ rejects it too (getNewPermissions returns 0). Force the write and let occ
    # fail loudly rather than silently deciding this grant was already in place.
    *)      want=0;;
  esac; done
  # Declared either way — gf_prune must not revoke a grant just because it was already correct.
  GF_DECLARED="$mount"$'\t'"$group"$'\n'"$GF_DECLARED"
  cur="$(printf '%s\n' "$GF_CACHE" | awk -F'\t' -v m="$mount" -v g="$group" 'NF==3 && $1==m && $2==g {print $3; exit}')"
  if [ "$cur" = "$want" ]; then log "grant '$mount' $group already [$want]"; return 0; fi
  # Plain command, and stderr kept: see ensure_group. A renamed group makes occ print
  # "group/team not found" and exit non-zero — which used to abort the phase and stopped doing so
  # when the cache write was appended after the `&&`.
  occ groupfolders:group "$id" "$group" "$@" >/dev/null
  log "grant '$mount' -> $group [${*:-read}]"
  GF_CACHE="$mount"$'\t'"$group"$'\t'"$want"$'\n'"$GF_CACHE"
}

# Every (mount, group) gf_grant has touched this phase, granted or already correct. gf_prune reads it.
GF_DECLARED=""

# Revoke every grant on the phase-30 folders the matrix did not declare, so the phase file is the
# whole truth about who has access. Without this gf_grant could only ADD: deleting a line left the
# access in place and the committed file quietly stopped describing the instance. Access
# that outlives the line that created it is the kind of thing nobody discovers until an audit.
#
# Only folders the matrix mentions are pruned, so a folder managed elsewhere is left alone. Call it
# once, at the end of the ACL phase, after every gf_grant.
gf_prune() {
  local mounts line mount group
  # Re-read rather than trusting GF_CACHE: the cache holds what this run wrote, and pruning needs
  # what the SERVER currently has.
  GF_CACHE=""; gf_load
  mounts="$(printf '%s\n' "$GF_DECLARED" | cut -f1 | sort -u)"
  printf '%s\n' "$GF_CACHE" | awk -F'\t' 'NF==3 {print $1 "\t" $2}' | while IFS=$'\t' read -r mount group; do
    [ -n "$mount" ] || continue
    printf '%s\n' "$mounts" | grep -qxF "$mount" || continue          # folder not in the matrix
    printf '%s\n' "$GF_DECLARED" | grep -qxF "$mount"$'\t'"$group" && continue
    occ groupfolders:group "$(groupfolder_id "$mount")" "$group" --delete >/dev/null
    log "revoked '$mount' -> $group (not in the matrix)"
  done
}
# --- group-folder content ---
#
# THE JAIL RULE, in one place because getting it wrong is silent. Content goes under $id/files/,
# NOT $id/: the storage root also holds trash/ and versions/, and the mount is a Jail rooted at
# files/ (groupfolders FolderStorageManager), so anything written one level up is on disk but
# outside the mount and no user can see it. Everything seeded landed there from 2026-07-24 until
# this was fixed, and `test -f` kept passing on the wrong path, so re-seeding reported "exists" and
# never repaired it. Both writers below build their path through here, so there is one path to be
# wrong about rather than one per writer.
#
# CALL gf_load FROM THE CALLER, never from here — same subshell trap documented at groupfolder_id.
# Every caller reads through `path="$(gf_files_path …)"`, and a cache filled inside a command
# substitution dies with it, so the next lookup would re-read the server (or find nothing).
gf_files_path() {  # MOUNT REL -> absolute in-container path, or fails
  local id; id="$(groupfolder_id "$1")"
  [ -n "$id" ] || { log "groupfolder '$1' not found — cannot write $2"; return 1; }
  # Derived from datadir_load, not hardcoded: AIO's /mnt/ncdata flows through the instance's own
  # answer, and the jail rule above stays the one path to be wrong about. Self-heals when a caller
  # skipped the load (a cache filled inside a command substitution dies with it — documented above
  # — but the VALUE still flows out), so a caller that forgets datadir_load pays one exec, never a
  # wrong path.
  datadir_load || return 1
  printf '%s/__groupfolders/%s/files/%s\n' "$DATADIR" "$id" "$2"
}
# Reindex the folder a path belongs to. Best-effort: a failed scan leaves the file on disk and the
# next seed's `test` still finds it, so failing the phase here would be louder than the problem.
gf_scan() { occ groupfolders:scan "$(groupfolder_id "$1")" >/dev/null 2>&1 || true; }

# Create a text file inside a group folder, then index it. Idempotent (test -f).
ensure_gf_file() {  # MOUNT RELPATH CONTENT
  local mount="$1" rel="$2" content="$3" path
  # datadir_load HERE, parent-side of the command substitution below — gf_files_path's own load
  # would die with the substitution and every call would re-pay the exec. gf_load for the same
  # reason, per its own contract above.
  gf_load; datadir_load || return 1; path="$(gf_files_path "$mount" "$rel")" || return 1
  if nc_exec --user www-data -- test -f "$path" 2>/dev/null; then
    log "  file $mount/$rel exists"; return 0; fi
  nc_exec --user www-data -e GFC="$content" -e GFP="$path" -- \
    sh -c 'printf "%s" "$GFC" > "$GFP"'
  gf_scan "$mount"
  log "  file $mount/$rel created"
}
# Create a regular subfolder inside a group folder, then index it. Idempotent (test -d).
ensure_gf_subfolder() {  # MOUNT SUBFOLDER
  local mount="$1" sub="$2" path
  gf_load; datadir_load || return 1; path="$(gf_files_path "$mount" "$sub")" || return 1
  if nc_exec --user www-data -- test -d "$path" 2>/dev/null; then
    log "  subfolder $mount/$sub exists"; return 0; fi
  nc_exec --user www-data -- mkdir -p "$path"
  gf_scan "$mount"
  log "  subfolder $mount/$sub created"
}

# --- TLS intermediates (#28) -------------------------------------------------
# Some hosts we read serve ONLY their leaf certificate and omit the intermediate. Browsers hide it
# by chasing the leaf's authorityInfoAccess pointer; server-side clients do not, so Nextcloud's
# IClientService fails verification with ssl_verify_result=20 and the fetch simply returns nothing.
# Measured 2026-08-02 on www.ispch.gob.cl (24 ISP alert feeds) — epidemiologia loses those feeds at import
# with only a server log to say so.
#
# The intermediate is taken from the leaf's OWN AIA pointer at run time rather than vendored,
# because that survives a CA rotation: the leaf always names its current issuer, a committed .pem
# does not. The price is that THIS IS THE FIRST PHASE THAT CONTACTS THE NETWORK — #98 kept the app
# store out of a clean install, and while a CA is not the app store, an offline install now skips
# this phase rather than failing it. That is why every failure below is a warning, not an error:
# a clinic with no internet at seed time must still finish provisioning.
# Whether an AIA pointer is safe to hand to a shell and to curl.
#
# It is read out of a REMOTE certificate over a handshake nothing verifies, so it is
# attacker-chosen input. An allowlist rather than an escape: escaping is an argument about
# which characters matter, and this needs no argument. The strip that used to look like a
# mitigation, `tr -d '[:space:]'`, is not one — `;id>/tmp/p;` carries no whitespace.
aia_is_safe() {
  # C collation, because `[A-Za-z]` is a RANGE and a range is locale-dependent: under the
  # es_CL.UTF-8 a Chilean dev actually runs, `é` collates inside it and the allowlist is
  # quietly wider than it reads.
  local LC_ALL=C
  # Length first, because what follows treats this value as an argv entry and a path
  # component, and both have ceilings a remote host can reach: at 128KB `basename`
  # fails to exec (E2BIG), and well before that `/tmp/$name` is too long to remove.
  # Either is fatal under the phase's errexit. 2048 is far above any real pointer.
  [ "${#1}" -le 2048 ] || return 1

  # `[[ =~ ]]`, not `grep`: grep matches a LINE, so a two-line value whose first line is
  # clean would pass. Bash anchors the whole string.
  #
  # `%` and `+` are in the set because real AIA URIs carry them — AD CS emits `%20` — and
  # refusing a legal pointer silently kills the feeds this function exists to keep.
  [[ $1 =~ ^[Hh][Tt][Tt][Pp][Ss]?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%+/-]*)?(\?[A-Za-z0-9._~%+/=\&-]*)?$ ]]
}

ensure_aia_intermediate() {  # HOST
  local host="$1" aia name

  # occ security:certificates prints one row per imported file; the file name is the key.
  # One handshake, and it yields both halves: the pointer on the first line, the leaf after
  # it. Read separately they came from two connections, so behind a load balancer mid-rotation
  # the certificate being verified was not the one whose pointer was followed.
  # `timeout 20` sits INSIDE the payload: host-side around `docker exec` it kills the CLI
  # and orphans openssl in the container; around `sh -c` it SIGTERMs dash, which skips the EXIT
  # trap below and leaks the leaf. 20 is the `curl --max-time 20` further down — a live handshake
  # is sub-second.
  local handshake leaf_pem
  handshake="$(nc_exec -e HOST="$host" -- sh -c '
    leaf=$(mktemp); trap "rm -f $leaf" EXIT
    echo | timeout 20 openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null \
      | openssl x509 -outform PEM > "$leaf" 2>/dev/null || exit 1
    openssl x509 -in "$leaf" -noout -text 2>/dev/null \
      | sed -n "s|.*CA Issuers - URI:||p" | tr -d " \t\r" | grep -m1 -i "^http"
    echo
    cat "$leaf"' 2>/dev/null | tr -d '\r')" || true

  # Split in the shell, not through `head`/`tail`: `head -1` closes the pipe on line
  # two, so a large leaf makes `printf` take SIGPIPE and the assignment return 141 —
  # which under this phase's `pipefail` is fatal. The leaf's size is chosen by the
  # remote host, so that turns a phase that only warns into one a server can kill.
  aia="${handshake%%$'\n'*}"
  leaf_pem="${handshake#*$'\n'}"

  if [ -z "$aia" ]; then
    log "certs: $host published no CA-Issuers pointer (offline?) — skipped, feeds from it will fail"
    return 0
  fi

  if ! aia_is_safe "$aia"; then
    log "certs: $host published a CA-Issuers pointer that is not a plain URL — refused, feeds from it will fail"
    return 0
  fi

  name="$(basename "$aia" .crt).pem"

  local rc=0
  cert_listed "$name" || rc=$?
  case "$rc" in
    0) log "certs: $name already imported"; return 0 ;;
    1) ;;  # absent: the one answer that means carry on and import
    2) log "certs: could not read the certificate list — skipped, leaving $name as it is"; return 0 ;;
    *) log "certs: certificate list was unreadable — skipped, leaving $name as it is"; return 0 ;;
  esac

  # GlobalSign serves DER; others serve PEM. Try DER, fall back to PEM, and let openssl be the
  # gate: an HTML error page must never reach the bundle as a "certificate". Empty output means
  # one of fetch or parse failed, and either way there is nothing to import.
  # The URI and the host go through the environment, never into the script text: the one is
  # attacker-chosen and the other has no business being quoted by hand.
  #
  # And the fetched certificate must actually have ISSUED the leaf. Without that check the
  # unverified handshake above is the whole attack: whoever answers for the host picks the
  # pointer, and Nextcloud trusts whatever comes back for every later server-side fetch.
  # It must chain to a root the container ALREADY trusts, and the leaf must be for this host.
  # `-partial_chain -trusted` was tried first and is theatre: it proves only that the fetched
  # certificate signed the certificate the handshake presented, and an on-path attacker chooses
  # both — verified by forging a leaf and its CA, which that form accepted and this one refuses.
  # Nothing legitimate is lost: an intermediate that does not reach a public root would not fix
  # the feed either.
  nc_exec -e AIA="$aia" -e HOST="$host" -e LEAF="$leaf_pem" -- sh -c '
      leaf=$(mktemp); blob=$(mktemp); pem=$(mktemp)
      trap "rm -f $leaf $blob $pem" EXIT
      printf "%s\n" "$LEAF" > "$leaf"   # a PEM without its final newline is not one
      curl -fsS --max-time 20 -o "$blob" "$AIA" || exit 1
      openssl x509 -inform DER -in "$blob" -outform PEM > "$pem" 2>/dev/null \
        || openssl x509 -in "$blob" -outform PEM > "$pem" 2>/dev/null || exit 1
      openssl verify -untrusted "$pem" -verify_hostname "$HOST" "$leaf" >/dev/null 2>&1 || exit 1
      cat "$pem"
    ' > "/tmp/$name" 2>/dev/null || true

  # Every cleanup and copy below is `|| true` or guarded, for one reason: this helper
  # warns and returns 0 on every failure it already knows about, and a phase that dies
  # on the tidying instead is the same defect wearing a different hat. `docker cp` in
  # particular fails for the ordinary reason of a container still starting.
  if [ ! -s "/tmp/$name" ]; then
    log "certs: could not fetch or parse $aia — skipped, feeds from $host will fail"
    rm -f "/tmp/$name" || true
    return 0
  fi

  # The one transport site that is not an exec — docker cp takes the container name itself, so it
  # rides env.sh's nc_cp (same resolution as nc_exec).
  if ! nc_cp "/tmp/$name" "/tmp/$name" >/dev/null 2>&1; then
    log "certs: could not copy $name into the container — skipped, feeds from $host will fail"
    rm -f "/tmp/$name" || true
    return 0
  fi
  rm -f "/tmp/$name" || true

  if occ security:certificates:import "/tmp/$name" >/dev/null 2>&1; then
    log "certs: imported $name for $host"
  else
    log "certs: import of $name FAILED"
  fi

  # `docker cp` writes as root, so www-data cannot unlink it from a sticky /tmp. Left
  # unguarded this was the LAST command in the function, so a failed cleanup became the function's
  # exit status and killed the phase after the first host — caught by removing both certificates
  # and re-running, which imported ispch and then aborted before the second host.
  nc_exec -- rm -f "/tmp/$name" >/dev/null 2>&1 || true
  return 0
}

# Whether Nextcloud's bundle already holds NAME (one row per imported file; the file name is the
# key): 0 = it does, 1 = it does not, 2 = the list could not be read, 3 = it was read and is not
# a list of rows.
#
# "Not imported" and "could not ask" are DIFFERENT ANSWERS (#143). This used to pipe occ straight
# into grep with stderr discarded, so a container that was briefly too busy to answer looked
# exactly like an empty bundle — and re-importing a certificate that is already there is a WRITE
# on a provisioned instance, which reddens seed-idempotent and, through cleanboot, CI. Capture
# first and let the exit status decide whether the output means anything.
#
# --output=json, not the rendered table: that table pads every column to its widest row, so
# `grep -F " $name "` was really asking "which other certificates are installed?". Parsed the way
# divergence.sh parses occ's JSON.
# `|| rc=$?`, never a bare pipeline followed by `rc=$?`: phases run under `set -e` (seed.sh), and
# "certificate absent" is a legitimate non-zero that would kill the phase before the assignment
# ran. An OR list is exempt from errexit; an `if` condition is too, which is why the old shape
# never hit this. Caught by cleanboot, not locally — a machine that already holds both
# certificates never takes the absent branch.
# The search is inside the `try` with the parse, not after it: valid JSON of the wrong
# shape — an object, a string, a list of anything but objects — raises on `.get` rather
# than on `load`, and an uncaught raise exits 1, which would read as "absent" and
# answer with the re-import #143 exists to prevent. Unreadable is unreadable however
# it fails to be read — and every status that is not 0 or 1 is a non-answer too: listing only 2
# left every other status meaning "absent", and a python3 the kernel kills returns 137.
cert_listed() {  # NAME
  local listed rc=0
  listed="$(occ security:certificates --output=json 2>/dev/null)" || return 2
  printf '%s' "$listed" | python3 -c '
import json, sys
try:
    found = any(r.get("name") == sys.argv[1] for r in json.load(sys.stdin))
except Exception: sys.exit(2)
sys.exit(0 if found else 1)' "$1" || rc=$?
  case "$rc" in 0|1) return "$rc" ;; *) return 3 ;; esac
}

# The installer's own CA, on an install by IP (R22). The suite then answers at https://<ip>/ with a
# leaf that CA signed (patch 235), and Nextcloud calls itself there — Talk's signaling backend, the
# setup checks. The mastercontainer's NEXTCLOUD_TRUSTED_CACERTS_DIR mounts the CA at the path below
# and the container's start adds it to the OS store, but Nextcloud's own HTTP client reads its
# bundle, not that store — the reason this file imports it, exactly as the intermediates above.
# A domain install mounts no such file: nothing to do. Unlike those, this one is not optional — an
# install by IP that does not trust itself is broken — so a failed import fails the phase; a container
# or a list that cannot be asked is still skipped (#143: a non-answer is never an absence), and the
# next run imports it. The probe answers in words, not by exit status: `docker exec` itself exits 1
# on a stopped container, exactly as `test -f` does for an absent file.
INSTALLER_CA=/usr/local/share/ca-certificates/aps-conecta-ca.crt
ensure_installer_ca() {
  local name rc=0 mounted
  name="$(basename "$INSTALLER_CA")"
  mounted="$(nc_exec -- sh -c 'if [ -f "$1" ]; then echo yes; else echo no; fi' _ "$INSTALLER_CA" 2>/dev/null)" || true
  case "$mounted" in
    no) return 0 ;;
    yes) ;;
    *) log "certs: could not ask the container for $name — skipped, leaving it as it is"; return 0 ;;
  esac
  cert_listed "$name" || rc=$?
  case "$rc" in
    0) log "certs: $name already imported"; return 0 ;;
    1) ;;
    *) log "certs: could not read the certificate list — skipped, leaving $name as it is"; return 0 ;;
  esac
  if occ security:certificates:import "$INSTALLER_CA" >/dev/null 2>&1; then
    log "certs: imported $name for this server's own address"
  else
    log "certs: import of $name FAILED — this server will not trust its own address"
    return 1
  fi
}
