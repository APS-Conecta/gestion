#!/usr/bin/env bash
# provisioning/lib.sh — shared idempotency-guard helpers for the phase files (Story 0.5, AD-2).
# Sourced by seed.sh, which then sources each phase; every mutating helper is QUERY-BEFORE-CREATE:
# it inspects current state and skips/patches rather than blind-creating, so `make seed` is safe to
# re-run. Source this file; do not execute it. Host has python3 (no jq assumed) for JSON parsing.
#
# REQUIRES scripts/env.sh to have been sourced first — it provides occ(), which nearly every helper
# below calls. seed.sh sources them in that order.

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
# — and every one is a `docker compose exec` at ~0.8 s. Each cache fills on first use and is
# updated in place on every write, so it cannot go stale within a phase; seed.sh's subshell-per-
# phase resets it at every boundary, so it cannot go stale across phases either. AD-2's rule
# (cross-phase state goes through Nextcloud, never shell vars) holds unchanged.
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
  # Plain command, and stderr kept: see ensure_group. occ's message is the only thing that says why.
  occ group:adduser "$2" "$1" >/dev/null
  log "user $1 added to group $2"
  GROUPS_CACHE="$2"$'\t'"$1"$'\n'"$GROUPS_CACHE"
}

# --- apps (unpack the vendored tarball, then enable; idempotent) ---
#
# NOT `occ app:install` (#98): a failed store install leaves the app missing and its patches
# unapplied — an instance that looks installed and is not — and it pins no version, while
# `eurooffice/10-admin-section-name.patch` is anchored to a line number in 11.0.1.
# The store stays ENABLED: turning it off also removes the admin Update button, itself a guard (#82).
# The tarballs are UNMODIFIED upstream and stay that way (#82): committing them pre-patched hides a
# four-line change inside 409 files and makes upstream drift silent, where a patch that stops
# applying aborts the phase and says so.
ensure_vendored_app() {  # APPID
  # Two statements, not one. Bash expands every word of a `local` BEFORE assigning any of them, so
  # `local app="$1" dir=".../$app"` reads whatever `app` meant in the CALLER — which here is phase
  # 12's loop variable of the same name, so it produced the right answer for the wrong reason and
  # would have broken the moment anything called this from a different loop.
  local app="$1"
  local dir="$HERE/apps/$app" tgz want sha cur
  local -a tarballs=("$dir"/*.tar.gz)

  # GUARD EVERY READ ON THE FILE EXISTING, and use no pipelines: phases run under `set -e` + `pipefail`,
  # so an unguarded read of a missing file kills the phase before its own `log` line can run.
  [ -f "${tarballs[0]}" ] || { log "FAILED $app — no vendored tarball in provisioning/apps/$app/"; return 1; }
  [ "${#tarballs[@]}" -eq 1 ] || { log "FAILED $app — ${#tarballs[@]} tarballs in provisioning/apps/$app/, expected 1"; return 1; }
  tgz="${tarballs[0]}"
  [ -f "$dir/VENDOR" ] || { log "FAILED $app — provisioning/apps/$app/VENDOR is missing"; return 1; }
  want="$(sed -n 's/^version=//p' "$dir/VENDOR")" || want=""
  sha="$(sed -n 's/^sha256=//p' "$dir/VENDOR")" || sha=""
  [ -n "$want" ] && [ -n "$sha" ] || { log "FAILED $app — VENDOR is missing version= or sha256="; return 1; }

  # The tarball is committed, so git already guarantees the bytes survived the clone. This catches
  # the other thing: a bump where the file and the VENDOR line stopped describing each other.
  echo "$sha  $tgz" | sha256sum --check --status \
    || { log "FAILED $app — tarball does not match sha256 in VENDOR; re-download it from url="; return 1; }

  # apps/ is bind-mounted, so the host can read the installed version without occ. awk rather than
  # `sed | head`: one process, exits 0 on no match, and no pipeline to inherit a status from.
  cur=""
  if [ -f "apps/$app/appinfo/info.xml" ]; then
    cur="$(awk -F'[<>]' '/<version>/ {print $3; exit}' "apps/$app/appinfo/info.xml")"
  fi

  if [ "$cur" = "$want" ]; then
    log "app $app $want vendored, already unpacked"
  else
    # RE-IMPOSE, not report (#117, answering the question #98 left open). App code is not content —
    # #85 classifies re-imposing it as reversible — and the vendored tarball plus the patches beside
    # it reproduce the result exactly, so the instance converging on the repo is the whole point of
    # `make install`. What is NEVER re-imposed is anything that holds files: folders, users, content.
    if [ -n "$cur" ]; then
      # Cleared first so the result IS the tarball. Untarring over a different version leaves
      # whatever that version had and this one dropped — an app that is neither release, which is
      # worse than either. Brief window where the app directory does not exist; the phase fails
      # loudly if the unpack then fails, and re-running restores it from git.
      occ_sh "rm -rf custom_apps/$app" \
        || { log "FAILED to clear $app before re-imposing $want"; return 1; }
    fi
    # Streamed into the container and unpacked as www-data, rather than on the host: files must be
    # writable by uid 33 or the patches below cannot apply. Ownership ends up www-data:www-data and
    # `make fix-mount-perms` restores the host group on the next `make up` (AD-9), which is why
    # nothing does it here.
    if docker compose exec -T --user www-data nextcloud \
         tar xzf - -C /var/www/html/custom_apps < "$tgz"; then
      log "app $app ${cur:+$cur }-> $want unpacked from $(basename "$tgz")"
    else
      log "FAILED to unpack $app from $(basename "$tgz")"; return 1
    fi

    # NEW FILES ARE HALF THE JOB. Nextcloud records each app's version in appconfig, independently
    # of what is on disk, and a mismatch sets needsDbUpgrade — after which occ answers only a
    # handful of commands ("Nextcloud or one of the apps require upgrade") and every later phase
    # fails. Measured 2026-08-01, which is the only reason this line exists.
    #
    # `occ upgrade` is the right tool and not a heavy-handed one: it runs the app's own migrations
    # from the files on disk and never contacts the store. Setting installed_version by hand would
    # be lighter and would SKIP those migrations, which is how an app ends up running new code
    # against an old schema. Only on a version change, so a normal seed never pays for it.
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

  conf_load
  [ "$(conf_get app "$app" enabled 2>/dev/null || true)" = "yes" ] && { log "app $app enabled"; return 0; }
  # `app:enable` alone, never `app:install` — enable reads what is on disk and never contacts the
  # store, which is the whole point. Keep occ's own error: it is the only thing that says WHY.
  # Guessing a cause here once sent an operator hunting file permissions when the real failure was
  # an app store timeout (#41).
  local err
  if err="$(occ app:enable "$app" 2>&1)"; then
    log "app $app -> enabled"
  else
    log "FAILED to enable app $app — occ said: $(printf '%s' "$err" | tr '\n' ' ' | tail -c 300)"
    return 1
  fi
}

# An app WE write (ADR-0003). It ships as a tarball like every other app here, built from a release
# tag of its own repository — so an install needs no network, no git, and no GitHub.
#
# The one thing that differs is a DEVELOPMENT MACHINE, where apps/<id> is not an unpacked tarball
# but a live git clone that someone is editing. ensure_vendored_app clears the directory before
# unpacking, which there would mean `rm -rf` over a working tree: uncommitted work, .git and all.
#
# So this dispatches on a fact rather than a flag — `apps/<id>/.git` exists or it does not. A server
# never has it and gets the pinned, re-imposed tarball, which is what reproducibility needs. A
# developer always has it and gets left alone. Nobody has to remember to set anything, and the
# wrong answer is not reachable by forgetting.
ensure_own_app() {  # APPID CLONE_URL
  local app="$1" url="$2"
  local info="apps/$app/appinfo/info.xml" disk installed

  # Not a checkout: production. Hand it to the tested path, which pins the sha256, re-imposes the
  # bytes and reconciles the schema exactly as it does for the third-party apps.
  if [ ! -d "apps/$app/.git" ]; then
    ensure_vendored_app "$app"
    return
  fi

  # A checkout with no info.xml is a half-clone, not a dev machine. Say the command: apps/ is
  # gitignored, so a clean gestion checkout has an empty apps/ and this is what a new operator hits.
  if [ ! -f "$info" ]; then
    log "FAILED $app — apps/$app has a .git but no $info. Finish the clone:"
    log "        git clone $url apps/$app"
    return 1
  fi

  disk="$(awk -F'[<>]' '/<version>/ {print $3; exit}' "$info")"
  [ -n "$disk" ] || { log "FAILED $app — no <version> in $info"; return 1; }

  conf_load
  installed="$(conf_get app "$app" installed_version 2>/dev/null || true)"

  # Same trap ensure_vendored_app documents, reached by a different route: here the version moves
  # when someone runs `git pull`, and Nextcloud then answers almost nothing until `occ upgrade`
  # runs. Doing it inside the phase means a pull followed by `make seed` is enough, and nobody has
  # to remember the second command. Only on a change, so a normal seed never pays for it.
  if [ -n "$installed" ] && [ "$installed" != "$disk" ]; then
    if occ upgrade --no-interaction >/dev/null 2>&1; then
      log "app $app $installed -> $disk schema reconciled (occ upgrade)"
      CONF_CACHE=""
      conf_load
    else
      log "FAILED to reconcile $app to $disk — 'occ upgrade' errored; instance may be mid-upgrade"
      return 1
    fi
  else
    log "app $app $disk from apps/$app (git working tree, not re-imposed)"
  fi

  [ "$(conf_get app "$app" enabled 2>/dev/null || true)" = "yes" ] && { log "app $app enabled"; return 0; }
  local err
  if err="$(occ app:enable "$app" 2>&1)"; then
    log "app $app -> enabled"
  else
    log "FAILED to enable app $app — occ said: $(printf '%s' "$err" | tr '\n' ' ' | tail -c 300)"
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
  printf '/var/www/html/data/__groupfolders/%s/files/%s\n' "$id" "$2"
}
# Reindex the folder a path belongs to. Best-effort: a failed scan leaves the file on disk and the
# next seed's `test` still finds it, so failing the phase here would be louder than the problem.
gf_scan() { occ groupfolders:scan "$(groupfolder_id "$1")" >/dev/null 2>&1 || true; }

# Create a text file inside a group folder, then index it. Idempotent (test -f).
ensure_gf_file() {  # MOUNT RELPATH CONTENT
  local mount="$1" rel="$2" content="$3" path
  gf_load; path="$(gf_files_path "$mount" "$rel")" || return 1
  if docker compose exec -T --user www-data nextcloud test -f "$path" 2>/dev/null; then
    log "  file $mount/$rel exists"; return 0; fi
  docker compose exec -T --user www-data -e GFC="$content" -e GFP="$path" nextcloud \
    sh -c 'printf "%s" "$GFC" > "$GFP"'
  gf_scan "$mount"
  log "  file $mount/$rel created"
}
# Create a regular subfolder inside a group folder, then index it. Idempotent (test -d).
ensure_gf_subfolder() {  # MOUNT SUBFOLDER
  local mount="$1" sub="$2" path
  gf_load; path="$(gf_files_path "$mount" "$sub")" || return 1
  if docker compose exec -T --user www-data nextcloud test -d "$path" 2>/dev/null; then
    log "  subfolder $mount/$sub exists"; return 0; fi
  docker compose exec -T --user www-data nextcloud mkdir -p "$path"
  gf_scan "$mount"
  log "  subfolder $mount/$sub created"
}

# --- content fixtures (query-before-create): put a file in a user's Files, then index it ---
ensure_sample_file() {  # UID RELPATH CONTENT
  local uid="$1" rel="$2" content="$3" base="data/$1/files"
  if docker compose exec -T --user www-data nextcloud test -f "/var/www/html/$base/$rel" 2>/dev/null; then
    log "file $uid:$rel exists"; return 0
  fi
  docker compose exec -T --user www-data -e SAMPLE="$content" -e DEST="/var/www/html/$base/$rel" nextcloud \
    sh -c 'mkdir -p "$(dirname "$DEST")" && printf "%s" "$SAMPLE" > "$DEST"'
  occ files:scan "$uid" >/dev/null 2>&1 || true
  log "file $uid:$rel created + indexed"
}

# --- TLS intermediates (#28) -------------------------------------------------
# Some hosts we read serve ONLY their leaf certificate and omit the intermediate. Browsers hide it
# by chasing the leaf's authorityInfoAccess pointer; server-side clients do not, so Nextcloud's
# IClientService fails verification with ssl_verify_result=20 and the fetch simply returns nothing.
# Measured 2026-08-02 on www.ispch.gob.cl (24 ISP alert feeds) and estadistica.ssmso.cl (this site's
# own Servicio de Salud) — News loses those feeds at import with only a server log to say so.
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
  # `timeout 20` sits INSIDE the payload: host-side around `docker compose exec` it kills the CLI
  # and orphans openssl in the container; around `sh -c` it SIGTERMs dash, which skips the EXIT
  # trap below and leaks the leaf. 20 is the `curl --max-time 20` further down — a live handshake
  # is sub-second.
  local handshake leaf_pem
  handshake="$(docker compose exec -T -e HOST="$host" nextcloud sh -c '
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

  # "Not imported" and "could not ask" are DIFFERENT ANSWERS (#143). This used to pipe occ straight
  # into grep with stderr discarded, so a container that was briefly too busy to answer looked
  # exactly like an empty bundle — and re-importing a certificate that is already there is a WRITE
  # on a provisioned instance, which reddens seed-idempotent and, through cleanboot, CI. Capture
  # first and let the exit status decide whether the output means anything.
  local listed rc
  if ! listed="$(occ security:certificates --output=json 2>/dev/null)"; then
    log "certs: could not read the certificate list — skipped, leaving $name as it is"
    return 0
  fi

  # --output=json, not the rendered table: that table pads every column to its widest row, so
  # `grep -F " $name "` was really asking "which other certificates are installed?". Parsed the way
  # divergence.sh parses occ's JSON. 0 = present, 1 = absent, 2 = could not be read, which is the
  # same non-answer as a failed occ and takes the same exit.
  # `|| rc=$?`, never a bare pipeline followed by `rc=$?`: phases run under `set -e` (seed.sh), and
  # "certificate absent" is a legitimate non-zero that would kill the phase before the assignment
  # ran. An OR list is exempt from errexit; an `if` condition is too, which is why the old shape
  # never hit this. Caught by cleanboot, not locally — a machine that already holds both
  # certificates never takes the absent branch.
  rc=0
  # The search is inside the `try` with the parse, not after it: valid JSON of the wrong
  # shape — an object, a string, a list of anything but objects — raises on `.get` rather
  # than on `load`, and an uncaught raise exits 1, which this reads as "absent" and
  # answers with the re-import #143 exists to prevent. Unreadable is unreadable however
  # it fails to be read.
  printf '%s' "$listed" | python3 -c '
import json, sys
try:
    found = any(r.get("name") == sys.argv[1] for r in json.load(sys.stdin))
except Exception: sys.exit(2)
sys.exit(0 if found else 1)' "$name" || rc=$?
  case "$rc" in
    0) log "certs: $name already imported"; return 0 ;;
    1) ;;  # absent: the one answer that means carry on and import
    # Everything else is a non-answer, not an absence, and must take the same exit as a
    # failed occ. Listing only 2 left every other status meaning "absent" — a python3 the
    # kernel kills returns 137 — and answering a non-answer with an import is the #143
    # WRITE this whole block exists to prevent.
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
  docker compose exec -T -e AIA="$aia" -e HOST="$host" -e LEAF="$leaf_pem" nextcloud sh -c '
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
  # on the tidying instead is the same defect wearing a different hat. `docker compose
  # cp` in particular fails for the ordinary reason of a container still starting.
  if [ ! -s "/tmp/$name" ]; then
    log "certs: could not fetch or parse $aia — skipped, feeds from $host will fail"
    rm -f "/tmp/$name" || true
    return 0
  fi

  if ! docker compose cp "/tmp/$name" "nextcloud:/tmp/$name" >/dev/null 2>&1; then
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

  # `docker compose cp` writes as root, so www-data cannot unlink it from a sticky /tmp. Left
  # unguarded this was the LAST command in the function, so a failed cleanup became the function's
  # exit status and killed the phase after the first host — caught by removing both certificates
  # and re-running, which imported ispch and then aborted before ssmso.
  docker compose exec -T nextcloud rm -f "/tmp/$name" >/dev/null 2>&1 || true
  return 0
}
