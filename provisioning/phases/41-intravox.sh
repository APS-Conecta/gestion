# Phase 41 — welcome screen: IntraVox engine setup, group map, es import, page ACL.
# OWNER: welcome-screen program (this file + provisioning/intravox/ — render.py and the es/ library —
# move together).
#
# The repo's first provisioning-driven own-app content import (ADR-0015). Territorio's import is
# deliberately operator-paste (host/aps-conecta:380-424); this phase crosses that boundary with
# the disciplines inherited: upsert-by-stable-id, write verbs visible to seed-idempotent.sh,
# query-before-set, fail-closed guards on every optional value (L5-03 class).
#
# PER-SECTION CONVERGENCE (ADR-0019, supersedes D2's import-once): the tree is DECLARED per site
# (SITE_WELCOME, sites/<slug>/site.sh) and every seed converges reality toward it — a declared
# section whose <section>/<section>.json is absent from the groupfolder is rendered and imported;
# everything that exists is left exactly as found (occ intravox:import --skip-existing: the engine
# never overwrites); a section live on disk but absent from the declaration is REPORTED by
# scripts/divergence.sh, never deleted. Staff edits are page data (D2's core principle, kept):
# nothing here can flatten them. The core files (home/navigation/footer) render on the first
# seed only — they are staff-editable afterwards, so a section declared later gets a log line
# asking for its menu entry, not a merge. Template evolution still ships as NEW sections/pages.
#
# Runs after 40-acl.sh by numbering: needs phase-20 groups (step 3), the enabled app (phase 12 —
# lab clone during the lab period, vendored after promotion), and groupfolders (APPS). Ungated
# (< 50) by design: every clinic seeds its welcome screen (FR-5) — welcome structure is not a
# fixture. Zero new identity variables: the identity block (site.sh:9-14) carries every value
# substituted here (D3); the tree's shape is SITE_WELCOME (ADR-0019).
phase_begin "41-intravox" "Welcome screen: engine setup, group map, es import, page ACL"

# --- 1. GUARDS (16-app-policy.sh:54 shape — every value fails closed, never defaults) -----------
for _v in SITE_NOMBRE SITE_NOMBRE_CORTO SITE_DIRECCION SITE_COMUNA SITE_SERVICIO_SALUD; do
  [ -n "${!_v:-}" ] || { echo "FATAL: sites/$SITE/site.sh carries no $_v — the welcome payload substitutes it (D3). Regenerate the site file (scripts/deis.py <codigo> --new <slug>) or add the line by hand." >&2; exit 1; }
done

# App-state guard, declare-driven (the declaration, not a probe, is the truth — 12-apps.sh:55-59
# class): undeclared on this install → the loud clinic skip (lab period); declared but not
# enabled → a broken checkout, FATAL. LAB_APPS is sourced HERE, guarded — 12-apps.sh loads it
# inside its own subshell, which is dead by the time this phase runs (divergence.sh:158 sources
# it the same explicit way); without this line the lab would always take the clinic skip.
[ -f dev/lab-apps.sh ] && . dev/lab-apps.sh
_declared="$( { sed -n 's/^OWN_APPS="\(.*\)"/\1/p' provisioning/phases/12-apps.sh
                printf '%s\n' "${LAB_APPS:-}"; } | tr ' ' '\n' | sed 's/=.*//' | grep -x intravox || true)"
if [ -z "$_declared" ]; then
  log "  intravox not shipped to this install — nothing to seed (lab period on clinics; defaultapp stays dashboard,files)"
  phase_end
  return 0
fi
[ "$(occ config:app:get intravox enabled 2>/dev/null || true)" = "yes" ] || { echo "FATAL: intravox is declared but not enabled — phase 12 did not converge. A silent skip here ships a clinic without its welcome screen." >&2; exit 1; }

# --- 2. SETUP: bare — groupfolder + groups + grants, ZERO content (D10/D11, L1-03) -----
# The engine reads the mount name from app config (IntraVox MountName, review L1-01): set it
# BEFORE setup so the group folder is CREATED as $IV_MOUNT on a fresh install. On an install whose
# folder carries another name — the engine's default, or the name this install was told before
# (its groupfolder_name) — setup would not find $IV_MOUNT and would create a second mount beside
# the old one: two trees, one of them empty. Refuse loudly: a rename is a deliberate runbook
# (docs/WELCOME-SCREEN.md → "Renaming the storage folder on an existing install"), never a seed
# side effect. A name the engine refuses (MountName: one non-empty segment, no '/') is refused
# here first — written to the engine, it would fail every page.
case "$IV_MOUNT" in
  */*|'') echo "FATAL: IV_MOUNT '$IV_MOUNT' is not one folder name (empty, or contains '/') — the engine refuses it (MOUNT_NAME_INVALID) and every page would fail. Fix IV_MOUNT in .env." >&2; exit 1 ;;
esac
[ -n "${IV_MOUNT//[[:space:]]/}" ] || { echo "FATAL: IV_MOUNT is blank — fix it in .env." >&2; exit 1; }
_mounts="$(occ groupfolders:list --output=json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for f in (d.values() if isinstance(d, dict) else d):
    m = f.get("mount_point") or f.get("mountPoint")
    if m: print(m)')"
if ! printf '%s\n' "$_mounts" | grep -qxF -- "$IV_MOUNT"; then
  _told="$(occ config:app:get intravox groupfolder_name 2>/dev/null || true)"
  for _old in IntraVox "${_told:-IntraVox}"; do
    if [ "$_old" != "$IV_MOUNT" ] && printf '%s\n' "$_mounts" | grep -qxF -- "$_old"; then
      echo "FATAL: the engine's group folder is still named '$_old' but IV_MOUNT is '$IV_MOUNT' — rename it first (docs/WELCOME-SCREEN.md → Renaming the storage folder on an existing install), or set IV_MOUNT=$_old in .env for this install. Seeding now would create a second, empty mount." >&2
      exit 1
    fi
  done
fi
occ config:app:set intravox groupfolder_name --value="$IV_MOUNT" >/dev/null
# ensure-style and re-run safe (SetupService: groups, the $IV_MOUNT groupfolder, mount grants,
# one-time admin seeding behind the admin_access_provisioned marker). --skip-demo is bare
# mode (L1-03): setup creates NO content — no language folder, no boilerplate home, no
# _resources/_templates; the real es/ tree arrives with the import in step 4. Output
# silenced: the phase logs its own canonical write verbs; occ noise must never redden
# seed-idempotent on a re-run.
occ intravox:setup --skip-demo >/dev/null

# Drift detector (fail loud, never silently manage around it): the demo marker set means demo
# content lives in the groupfolder — the post-migration repair step's old behavior (pre-3.1.2)
# or a deliberate `occ intravox:import-demo`. Either way it outranks the seeded welcome for
# default-language users. Recovery: engine admin deletes the demo language trees (en/… —
# everything but es/), `occ config:app:delete intravox demo_data_imported`, then `make seed`.
# v3.1.2 removed the re-injection; this guard is what makes any regression of that loud.
if [ -n "$(occ config:app:get intravox demo_data_imported 2>/dev/null || true)" ]; then
  echo "FATAL: intravox demo_data_imported is set — demo content outranks the seeded welcome. Delete the demo language trees, occ config:app:delete intravox demo_data_imported, and re-seed." >&2
  exit 1
fi

# L2-01 (ADR-0018): the enabled_languages convergence is RETIRED — the engine's
# own unset-key default is the deployment reality (['es','en']: LanguageService's
# DEFAULT_ENABLED_LANGUAGES + the Version001600 seed). The deprecated key keeps
# its legacy readers working; gestion no longer writes it.

# --- 3. GROUP MAP (D5): the engine's groups follow the registry's — lib.sh intravox_group_map --------
# (phase 50 runs it again once the standing accounts exist — B-030)
intravox_group_map

# --- 4. RENDER + CONVERGE (ADR-0019): declaration → render.py → per-section import ------------
# render.py owns the whole "declare, don't hard-code" (review M3): identity substitution, the
# sections the site declared, one team page per SITE_TEAMS entry when 'equipos' is declared, the
# Documentos links from SITE_SUBFOLDERS, home tiles / navigation / footer from the declaration
# (review L0-01, L0-06, L0-07). It fails closed (unknown flag, undeclared section, a Files link
# to a folder the site does not have, invalid JSON) with one FATAL line on stderr. Arrays travel
# newline-joined: bash cannot export an array, render.py reads the environment.
_lib="provisioning/intravox/es"
_stage="$(mktemp -d)"
trap 'rm -rf "$_stage" ${_import:+"$_import"}' EXIT   # every exit path, FATALs included (own subshell)
chmod 755 "$_stage"   # mktemp gives 700 root:root and docker cp PRESERVES it — occ runs as
# www-data, every file_exists() in the importer reads false, and the import exits 0 having
# imported NOTHING (the silent-green this repo exists never to repeat; verified live). Files
# inside land 644 via umask — the directory mode is the whole fix.
# Nothing in sites/<slug>/site.sh is exported (seed.sh sources it; there is no set -a anywhere),
# so EVERY value render.py reads is forwarded here by name — the identity block included. The
# gate in scripts/test.sh asserts this list stays complete (a missing name is a FATAL on line one
# of every seed, and a gate that hands python its environment directly would never see it).
env SITE_NOMBRE="$SITE_NOMBRE" SITE_NOMBRE_CORTO="$SITE_NOMBRE_CORTO" SITE_DIRECCION="$SITE_DIRECCION" \
    SITE_COMUNA="$SITE_COMUNA" SITE_SERVICIO_SALUD="$SITE_SERVICIO_SALUD" \
    SITE_WELCOME="$(printf '%s\n' "${SITE_WELCOME[@]}")" \
    SITE_TEAMS="$(printf '%s\n' "${SITE_TEAMS[@]}")" \
    SITE_FOLDERS="$(printf '%s\n' "${SITE_FOLDERS[@]}")" \
    SITE_SUBFOLDERS="$(printf '%s\n' "${SITE_SUBFOLDERS[@]}")" \
    IV_MOUNT="$IV_MOUNT" \
    python3 provisioning/intravox/render.py "$_lib" "$_stage" >/dev/null \
  || { echo "FATAL: the welcome tree did not render — the FATAL line above names the declaration row or site value that broke it (sites/$SITE/site.sh)" >&2; exit 1; }

_ivfid="$(occ groupfolders:list --output=json 2>/dev/null | env IV_MOUNT="$IV_MOUNT" python3 -c '
import os, sys, json
d = json.load(sys.stdin)
for f in (d.values() if isinstance(d, dict) else d):   # both shapes, as the guard above (B-028)
    if (f.get("mount_point") or f.get("mountPoint")) == os.environ["IV_MOUNT"]: print(f["id"]); break')"
[ -n "$_ivfid" ] || { echo "FATAL: the '$IV_MOUNT' groupfolder was not found after intravox:setup — setup did not converge." >&2; exit 1; }
datadir_load || { echo "FATAL: datadir unresolved (fail-closed, lib.sh:139-148)." >&2; exit 1; }
_gf="$DATADIR/__groupfolders/$_ivfid/files"   # gf_files_path shape (lib.sh:596): <DATADIR>/__groupfolders/<fid>/files/<rel>
_gf_has() { nc_exec --user www-data -- test -f "$_gf/$1" 2>/dev/null; }   # groupfolder-root-relative

  # Same discipline for the EN fallback home: every content generator now stamps its output
  # (seed/import → `page-aps` uniqueId, engine-generated → `_generated`), so a home carrying
  # NEITHER is pre-3.1.1 setup boilerplate — the only marker-less generator that ever existed.
  # Cleared so it cannot outrank the seeded es welcome (hasRealContent counts it as real). No
  # clinic ever ran 3.1.1's predecessors in production (the app shipped 2026-09-25), so this
  # arm cannot meet staff data; it exists to converge this lab box and any restored backup.
  if _gf_has en/home.json \
     && ! nc_exec --user www-data -- grep -q -e "page-aps" -e "_generated" "$_gf/en/home.json" 2>/dev/null; then
    nc_exec -- rm -f "$_gf/en/home.json"
    # rescan: the rm bypassed the Files API, and a mounted view reads the file cache —
    # without this the stale entry answers "exists" and the engine serves a ghost
    occ files:scan --path="/__groupfolders/$_ivfid/files" >/dev/null 2>&1
    log "  welcome: legacy marker-less en/home.json cleared (pre-3.1.1 boilerplate)"
  fi

# Markers. Core = es/navigation.json (only the import ever writes it; setup is bare under
# --skip-demo, so it cannot fake the marker — commit 5ff154e's lesson). Section = the section's
# own hub page es/<s>/<s>.json — the exact thing the importer recurses through. Team page (when
# 'equipos' is declared) = es/equipos/<gid>/<gid>.json. What is missing gets imported; what
# exists is logged with the noop verb and never touched (--skip-existing is the engine-side
# guarantee, these lines are the seam's own record).
_first_run=0; _gf_has es/navigation.json || _first_run=1
_new_sections=(); _new_teams=(); _equipos=0
for _row in "${SITE_WELCOME[@]}"; do
  _s="${_row%%|*}"
  [ "$_s" = equipos ] && _equipos=1
  if _gf_has "es/$_s/$_s.json"; then log "  welcome: section $_s exists"; else _new_sections+=("$_s"); fi
done
if [ "$_equipos" = 1 ]; then
  for _e in "${SITE_TEAMS[@]}"; do
    _tg="${_e%%|*}"
    if _gf_has "es/equipos/$_tg/$_tg.json"; then log "  welcome: team page $_tg exists"; else _new_teams+=("$_tg"); fi
  done
fi

if [ "$_first_run" = 1 ] || [ "${#_new_sections[@]}" -gt 0 ] || [ "${#_new_teams[@]}" -gt 0 ]; then
  # Setup boilerplate pre-clean (v3.1.1 discipline): if a home.json exists that does NOT
  # carry the seeded `page-aps` uniqueId namespace (staff edits always carry it — every
  # seeded page and every child of one does; setup boilerplate never does), clear it so the
  # import can write ours. Post-L1-03 bare setup never creates one; the live sources are the
  # admin API's full-mode setup endpoint (a `_generated` boilerplate home) and restored
  # backups. Query-before-set: a seeded home is never touched. First run only — afterwards
  # home.json is staff data and --skip-existing leaves it alone.
  if [ "$_first_run" = 1 ] && _gf_has es/home.json \
     && ! nc_exec --user www-data -- grep -q "page-aps" "$_gf/es/home.json" 2>/dev/null; then
    nc_exec -- rm -f "$_gf/es/home.json"
    occ files:scan --path="/__groupfolders/$_ivfid/files" >/dev/null 2>&1   # same cache discipline as the en arm
    log "  welcome: setup-boilerplate es/home.json cleared for import"
  fi
  # What is imported (owner decision 2026-09-28): the FIRST seed takes the whole rendered tree —
  # core files + every declared section. A later seed takes ONLY what is new: each new section's
  # folder, and for a new team under an existing equipos the hub JSON (the importer recurses only
  # through a folder that owns its JSON; the hub exists, so it is skipped) plus that team's folder.
  # Never the whole tree again: --skip-existing skips what EXISTS but creates what is MISSING at
  # every level, so a seeded page staff deleted on purpose («Aviso de ejemplo») would come back
  # every time any section or team is added — a deletion is a staff edit too.
  _import="$_stage"
  if [ "$_first_run" = 0 ]; then
    _import="$(mktemp -d)"; chmod 755 "$_import"   # the same docker-cp mode trap as $_stage
    for _s in "${_new_sections[@]}"; do cp -a "$_stage/$_s" "$_import/"; done
    if [ "${#_new_teams[@]}" -gt 0 ] && [ ! -d "$_import/equipos" ]; then
      mkdir "$_import/equipos" && cp -a "$_stage/equipos/equipos.json" "$_import/equipos/"
      for _tg in "${_new_teams[@]}"; do cp -a "$_stage/equipos/$_tg" "$_import/equipos/"; done
    fi
  fi
  # pre-clean: docker cp into an existing dir nests one level deeper and the retry imports
  # nothing, silently (territorio cp's single files into /tmp/ for the same reason)
  nc_exec -- rm -rf /tmp/intravox-welcome-es
  nc_cp "$_import" /tmp/intravox-welcome-es
  # --skip-existing is not optional, pruned import or not: without it the engine overwrites every
  # existing node it meets (the equipos hub above; a first run over a restored tree), so a failing
  # command is the correct outcome. An engine that predates the flag rejects it — promote the
  # engine first; never drop the flag to get past it.
  occ intravox:import /tmp/intravox-welcome-es --language es --user admin --skip-existing >/dev/null \
    || { echo "FATAL: occ intravox:import --skip-existing failed — re-run it by hand without >/dev/null to see why; an IntraVox engine older than welcome-folders p3 rejects the flag: promote the engine before seeding (a tree is never overwritten to work around it)" >&2; exit 1; }
  nc_exec -- rm -rf /tmp/intravox-welcome-es
  if [ "$_first_run" = 1 ]; then
    log "  welcome: es tree created"
    for _s in "${_new_sections[@]}"; do log "  welcome: section $_s created"; done
  else
    for _s in "${_new_sections[@]}"; do
      log "  welcome: section $_s created — add its menu entry and home tile by hand (navigation.json and home.json are staff data, ADR-0019)"
    done
  fi
  for _tg in "${_new_teams[@]}"; do log "  welcome: team page $_tg created"; done
fi

# --- 5. PAGE ACL (D4): baseline-deny + target-allow, written with the page it governs ---------
# ACL.php's --test branch demands --user + <path> (ACL.php:72-82) — query-by-group is not a CLI
# surface, so per-rule query-before-set is impossible. Instead a rule rides the creation of the
# page it governs (the _new_teams list above): written exactly once, immediately after the page
# exists — write-once to match add-once. A seed that dies between import and rules leaves a
# team page without its rules; the next seed sees the page as existing and does NOT rewrite
# them — recovery is `occ groupfolders:permissions` by hand for that page, or delete the page
# folder and reseed (only that team's page is touched). Verification uses --test with REAL
# USERS (T-4), never this block. Paths are groupfolder-root-relative — pages live under es/
# (ACL.php:152-154 resolves from the folder root). ACL must be enabled before rule writes
# (setup does not enable it — verified live, T-5 lab fact); the --enable setter is idempotent
# and a real failure surfaces in the rule writes, which demand ACL on (ACL.php:99-101).
# The static restricted pages (jefaturas, estadistica-rem, oirs) are gone with the static team
# pages (review L0-07): a role-restricted page is a declared team, e.g. 'role-oirs|OIRS' — a row
# you add by hand (deis.py emits programs and sectors only; the site file is yours after that);
# its page links the one declared folder named after it (Unidades/OIRS), render.py refuses else.
if [ "${#_new_teams[@]}" -gt 0 ]; then
  occ groupfolders:permissions "$_ivfid" --enable >/dev/null 2>&1 || true
  _acl() {  # PATH GID PERM — one rule, on page creation only (block comment above)
    occ groupfolders:permissions "$_ivfid" "$1" --group "$2" -- "$3" >/dev/null
    log "  acl: $1 rule created ($2 $3)"
  }
  for _tg in "${_new_teams[@]}"; do   # gid = the team itself (page-ACL by construction, FR-4)
    _acl "es/equipos/$_tg" 'IntraVox Users' '-read'   # baseline deny
    _acl "es/equipos/$_tg" "$_tg"           '+read'   # target allow
    # Jefaturas read every team page — the same oversight the folder matrix gives them on every
    # Unidad and Sector (site.sh SITE_ACL: "a Jefatura READS a Unidad that has an owning role"),
    # and what the retired restricted-page rows gave estadistica-rem and oirs. Without it a
    # declared role page ('role-oirs|OIRS') would lock its jefaturas out.
    _acl "es/equipos/$_tg" cat-jefaturas    '+read'
  done
fi

phase_end
