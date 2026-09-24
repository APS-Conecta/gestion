# Phase 41 — welcome screen: IntraVox engine setup, group map, es import, page ACL.
# OWNER: welcome-screen program (this file + provisioning/intravox/es/ move together).
#
# The repo's first provisioning-driven own-app content import (ADR-0015). Territorio's import is
# deliberately operator-paste (host/aps-conecta:380-424); this phase crosses that boundary with
# the disciplines inherited: upsert-by-stable-id, write verbs visible to seed-idempotent.sh,
# query-before-set, fail-closed guards on every optional value (L5-03 class).
#
# IMPORT-ONCE (D2): staff edits are page data. Guard = in-container presence of es/home.json
# inside the IntraVox groupfolder (path via gf_files_path shape, lib.sh:596). A second seed logs
# "already" and writes nothing. Template evolution ships as NEW pages; the documented recovery
# for a half-imported tree is delete-es/-and-reseed (engine admin deletes the es tree, then
# `make seed`). Avisos/news are data, never overwritten.
#
# Runs after 40-acl.sh by numbering: needs phase-20 groups (step 3), the enabled app (phase 12 —
# lab clone during the lab period, vendored after promotion), and groupfolders (APPS). Ungated
# (< 50) by design: every clinic seeds its welcome screen (FR-5) — welcome structure is not a
# fixture. Zero new SITE_* variables: the identity block (site.sh:9-14) carries every value
# substituted here (D3).
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

# --- 2. SETUP: es content tree, no demo pages (D10/D11) ----------------------------------------
# ensure-style and re-run safe (SetupService: groups, 'IntraVox' groupfolder, mount grants,
# one-time admin seeding behind the admin_access_provisioned marker). Output silenced: the phase
# logs its own canonical write verbs; occ noise must never redden seed-idempotent on a re-run.
occ intravox:setup --language es --skip-demo >/dev/null

# --- 3. GROUP MAP (D5): adds-only, query-before-set; one group:list json answers both sides ------
_groups_json="$(occ group:list --output=json 2>/dev/null)"
_gmap() {  # SRC_GID ENGINE_GID — add every member of SRC present in the live roster
  local _uid
  for _uid in $(printf '%s' "$_groups_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for uid in (d.get(sys.argv[1]) or []): print(uid)' "$1"); do
    printf '%s' "$_groups_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
sys.exit(0 if sys.argv[2] in (d.get(sys.argv[1]) or []) else 1)' "$2" "$_uid" && continue
    occ group:adduser "$2" "$_uid" >/dev/null
    log "  group: $_uid added to group $2"
  done
}
_gmap all-staff           'IntraVox Users'
_gmap cat-jefaturas       'IntraVox Editors'
_gmap role-oirs           'IntraVox Editors'   # registry gid is role-oirs (20-groups.sh:49); the
# design text said role-encargado-oirs, which does not exist — plan-local fix, design follow-up
# Admins: engine default (setup seeds NC admins once). Adds-never-deletes: membership only grows;
# leavers keep read — harmless, recorded (D5).

# --- 4. RENDER + TRANSPORT (D3, territorio shape): staged sed-render → docker cp → occ → rm -----
_src="provisioning/intravox/es"
_stage="$(mktemp -d)"
chmod 755 "$_stage"   # mktemp gives 700 root:root and docker cp PRESERVES it — occ runs as
# www-data, every file_exists() in the importer reads false, and the import exits 0 having
# imported NOTHING (the silent-green this repo exists never to repeat; verified live). Files
# inside land 644 via umask — the directory mode is the whole fix.
_esc() { printf '%s' "$1" | sed -e 's/[\\&]/\\&/g' -e 's/#/\\#/g'; }  # sed-replacement-safe
_render_file() {  # IN OUT — the substitution set (§2): identity block only, zero new vars
  sed -e "s#__SITE_NOMBRE__#$(_esc "$SITE_NOMBRE")#g" \
      -e "s#__SITE_NOMBRE_CORTO__#$(_esc "$SITE_NOMBRE_CORTO")#g" \
      -e "s#__SITE_DIRECCION__#$(_esc "$SITE_DIRECCION")#g" \
      -e "s#__SITE_COMUNA__#$(_esc "$SITE_COMUNA")#g" \
      -e "s#__SITE_SERVICIO_SALUD__#$(_esc "$SITE_SERVICIO_SALUD")#g" \
      "$1" > "$2"
}
( cd "$_src" && find . -type f -not -name '*.tpl' | while IFS= read -r _f; do   # .tpl files
    # are templates, rendered explicitly below — never staged raw
    mkdir -p "$_stage/$(dirname "$_f")"
    _render_file "$_f" "$_stage/$_f"
  done )
# equipos hub: rendered, not static — identity substitution first (the tpl carries __SITE_*__
# and must never ship raw), then the slot is dropped via python: sed cannot reliably remove the
# comma preceding the slot, and the fill (Phase 3) is python anyway. Target path is
# equipos/equipos.json — the equipos/ folder must OWN its json so the importer recurses into its
# children (ImportPagesCommand.php:242-246 recurses only through folders that own a <folder>.json;
# a nested equipos/equipos/ would orphan the whole subtree). The staged-JSON gate one step later
# backstops both.
mkdir -p "$_stage/equipos"
_render_file "$_src/equipos/equipos.json.tpl" "$_stage/equipos/equipos.json"   # identity first;
# the __TEAM_LINKS__ slot is handled by the fill-or-delete python below — never shipped raw

# 4b. Team pages — the agnostic dynamic (§1): one page per SITE_TEAMS entry; the hub grid is
# regenerated by the same loop so a different DEIS site gets its own set from site.sh alone.
_team_dir() {  # GID DISPLAY -> the team's Files mount (deis.py Programas/Sectores emission
  # shape — scripts/deis.py:173-192; verified against the pilot's SITE_FOLDERS at implement)
  case "$1" in
    prog-*)   printf 'Programas/%s' "${2#Programa }" ;;
    sector-*) printf 'Sectores/%s' "$2" ;;
    *)        printf '%s' "$2" ;;
  esac
}
for _x in "${SITE_TEAMS[@]}"; do printf '%s\n' "$_x"; done > "$_stage/.teams"
while IFS= read -r _e; do
  [ -n "$_e" ] || continue
  _tg="${_e%%|*}"; _td="${_e#*|}"
  mkdir -p "$_stage/equipos/$_tg"
  _render_file "$_src/equipos/equipo.tpl" "$_stage/equipos/$_tg/$_tg.json"   # identity first
  sed -i.bak -e "s#__TEAM_ID__#${_tg}#g" -e "s#__TEAM_DISPLAY__#$(_esc "$_td")#g" \
      -e "s#__TEAM_DIR__#$(_esc "$(_team_dir "$_tg" "$_td")")#g" \
      "$_stage/equipos/$_tg/$_tg.json" && rm -f "$_stage/equipos/$_tg/$_tg.json.bak"
done < "$_stage/.teams"
python3 - "$_stage/.teams" "$_stage/.team-links" <<'PY'
import json, sys
frags = []
for line in open(sys.argv[1]):
    gid, _, display = line.strip().partition("|")
    if gid:
        frags.append(json.dumps({"title": display, "text": "Actas, plan y noticias del equipo",
            "url": f"/apps/intravox/p/page-aps-team-{gid}",
            "icon": "account-group-outline", "target": "_self"}, ensure_ascii=False))
open(sys.argv[2], "w").write(",\n          ".join(frags))
PY
# hub: fill (or, with no teams, delete) the slot — python both ways, same discipline
python3 - "$_stage/equipos/equipos.json" "$_stage/.team-links" <<'PY'
import re, sys
page, frag = sys.argv[1], open(sys.argv[2]).read().strip()
s = open(page).read()
if frag:
    s = s.replace("__TEAM_LINKS__", frag)
else:
    s = re.sub(r",\s*\n\s*__TEAM_LINKS__", "", s)   # Phase 2 shape: no teams -> drop slot+comma
open(page, "w").write(s)
PY
rm -f "$_stage/.teams" "$_stage/.team-links"

# fail-loud gate: the staged tree must be valid JSON before it ships — a shell-hostile DEIS byte
# in any SITE_*/team value must FATAL here, never import a broken page.
( cd "$_stage" && find . -name '*.json' -print0 | xargs -0 -n1 python3 -m json.tool >/dev/null ) || { echo "FATAL: rendered payload is not valid JSON — a site value broke a page; fix sites/$SITE/site.sh" >&2; exit 1; }

_ivfid="$(occ groupfolders:list --output=json 2>/dev/null | python3 -c '
import sys, json
for f in json.load(sys.stdin):
    if (f.get("mount_point") or f.get("mountPoint")) == "IntraVox": print(f["id"]); break')"
[ -n "$_ivfid" ] || { echo "FATAL: IntraVox groupfolder not found after intravox:setup — setup did not converge." >&2; exit 1; }
datadir_load || { echo "FATAL: datadir unresolved (fail-closed, lib.sh:139-148)." >&2; exit 1; }
# Import guard — gf_files_path shape (lib.sh:596): <DATADIR>/__groupfolders/<fid>/files/<rel>.
if nc_exec --user www-data -- test -f "$DATADIR/__groupfolders/$_ivfid/files/es/home.json" 2>/dev/null; then
  log "  welcome: es tree already imported (staff edits are data — import-once, D2)"
else
  # pre-clean: docker cp into an existing dir nests one level deeper and the retry imports
  # nothing, silently (territorio cp's single files into /tmp/ for the same reason)
  docker exec "${NC_CONTAINER:?}" rm -rf /tmp/intravox-welcome-es
  docker cp "$_stage" "${NC_CONTAINER:?}:/tmp/intravox-welcome-es"
  occ intravox:import /tmp/intravox-welcome-es --language es --user admin >/dev/null
  docker exec "${NC_CONTAINER:?}" rm -rf /tmp/intravox-welcome-es
  log "  welcome: es tree created"
  _welcome_first_run=1   # arms the one-time ACL writes in step 5
fi
rm -rf "$_stage"

# --- 5. PAGE ACL (D4): baseline-deny + target-allow, written ONCE with the first import -------
# ACL.php's --test branch demands --user + <path> (ACL.php:72-82) — query-by-group is not a CLI
# surface, so per-rule query-before-set is impossible. Instead the rule writes ride the first
# run (armed by _welcome_first_run): rules are created exactly once, immediately after the
# pages they govern exist — write-once to match import-once. A seed that dies between import
# and rules is a half-imported tree; the documented recovery (delete es/ + reseed) covers it.
# Verification uses --test with REAL USERS (T-4), never this block. Paths are groupfolder-root-
# relative — pages live under es/ (ACL.php:152-154 resolves from the folder root). ACL must be
# enabled before rule writes (setup does not enable it — verified live, T-5 lab fact); the
# --enable setter is idempotent and a real failure surfaces in the rule writes, which demand
# ACL on (ACL.php:99-101).
occ groupfolders:permissions "$_ivfid" --enable >/dev/null 2>&1 || true
_acl() {  # PATH GID PERM — one rule, first-run only (block comment above)
  occ groupfolders:permissions "$_ivfid" "$1" --group "$2" -- "$3" >/dev/null
  log "  acl: $1 rule created ($2 $3)"
}
# Restricted pages (path|gid). Phase 1 ships the section with an empty list; Phase 2 fills it
# (registry gids per 20-groups.sh:49-50); Phase 3 appends the team loop in the same branch.
# Gids are the registry ids — the design text's role-encargado-* names do not exist (plan-local
# fix, design follow-up noted). Paths carry the es/ language segment: ACL resolves from the
# groupfolder root (ACL.php:152-154) while import nests pages under es/.
RESTRICTED_PAGES=(
  'es/equipos/jefaturas|cat-jefaturas'
  'es/equipos/estadistica-rem|role-estadistica-rem'
  'es/equipos/estadistica-rem|cat-jefaturas'
  'es/equipos/oirs|role-oirs'
  'es/equipos/oirs|cat-jefaturas'
)
if [ "${_welcome_first_run:-}" = "1" ]; then
  for _entry in "${RESTRICTED_PAGES[@]:-}"; do
    [ -n "$_entry" ] || continue
    _acl "${_entry%%|*}" 'IntraVox Users' '-read'   # baseline deny
    _acl "${_entry%%|*}" "${_entry#*|}"   '+read'   # target allow
  done
  # Team pages: same two-rule pattern, gid = the team itself (page-ACL by construction, FR-4)
  while IFS= read -r _e; do
    [ -n "$_e" ] || continue
    _tg="${_e%%|*}"
    _acl "es/equipos/$_tg" 'IntraVox Users' '-read'
    _acl "es/equipos/$_tg" "$_tg" '+read'
  done <<< "$(for _x in "${SITE_TEAMS[@]}"; do printf '%s\n' "$_x"; done)"
fi

phase_end
