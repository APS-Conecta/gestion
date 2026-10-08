#!/usr/bin/env bash
# What exists on the instance that the repo no longer declares (#85).
#
# WHY THIS REPORTS INSTEAD OF DELETING. Usage is one install on a clean machine, then updates —
# nothing drifts on its own. A folder or group is "live but undeclared" only because a human
# deliberately edited sites/<slug>/site.sh. So divergence is rare, always intentional, and the
# person who caused it is right there. Against that: deleting automatically means a typo in a data
# file silently destroys a clinic's documents, and there is no backup story in this repo to fall
# back on (parked in #75 until a target host exists). Reporting costs one command run by hand;
# deleting costs documents.
#
# TWO CONTRACTS, ONE SCRIPT (S8). Report mode — no flag, or --quiet — is the reporter this file has
# always been: EXIT 0, ALWAYS, because a non-zero exit would fail `make install` for the rest of
# time after a deliberate removal, which teaches people either to ignore the check or to stop
# running updates. Neither is a state worth having, so `make divergence` and install.sh's closing
# `--quiet` call keep exactly that contract. --gate is the handoff gate the Provisionador executor,
# the revalidation suite and the migration hook consume: it exits 1 on ANY note — real divergence
# and guard notes alike, because parser rot must not pass a handoff any more than drift may
# (B-014: a gate that cannot go red is not a gate, and a gate that stays green while its parsers
# are broken is green for the wrong reason).
#
# USERS ARE GATE-MODE-ONLY. Report mode still does not cover them, for the reason it never did: a
# report needs a DECLARED set to compare against, and a hand-run report on a hand-edited clinic has
# no roster — reporting every hand-added personal account as divergence would be noise, and noise
# is how a report stops being read. Gate mode has a declared set — the SITE_ROSTER CSV's usuarios,
# phase 50's standing accounts, and the install's own admin — so there it checks. One-way diff
# preserved: live-but-undeclared only; an account that SHOULD exist and does not is ensure_user's
# job (phase 50), never this script's.
#
# NO WRITE VERBS IN THE OUTPUT, either mode. scripts/seed-idempotent.sh greps a seed's log for
# them, so a report line matching one would redden the idempotency gate on an instance that is
# behaving correctly: things are "live but not declared", never "created".

set -uo pipefail

# shellcheck source=env.sh
# org L5-11: standings AFTER env.sh — its cd makes the provisioning/ path resolve from any
# cwd; sourced before it, a non-root invocation would miss the file and the gate below would
# flag every standing account (the wolf-cry this extraction exists to kill).
# shellcheck source=provisioning/standings.sh
. provisioning/standings.sh
. "$(dirname "$0")/env.sh"
require_site || exit 1
# shellcheck disable=SC1090  # the path is SITE, resolved at run time
. "sites/$SITE/site.sh"
nc_container   # once: the occ calls below run in pipes and $(…), whose cache dies with them

PHASE20=provisioning/phases/20-groups.sh
PHASE12=provisioning/phases/12-apps.sh


# --quiet says nothing at all when there is nothing to say. `make install` uses it so a clean
# install ends clean; `make divergence`, which a person ran ON PURPOSE to ask the question, prints
# the all-clear because silence there is indistinguishable from a broken script.
# --gate is the handoff contract (see the header). Both flags at once is legal — a quiet gate still
# prints its findings, because a red gate that says nothing is indistinguishable from a broken one.
# Anything else is a typo, and a typo behind a future --gate call must not be able to fall through
# to report mode's exit 0 — unknown args die loudly with usage instead (fail loud, never parse
# silently; B-014).
quiet=0
gate=0
for arg in "$@"; do
  case "$arg" in
    --quiet) quiet=1 ;;
    --gate)  gate=1 ;;
    *) printf 'usage: %s [--quiet] [--gate]\n' "$0" >&2; exit 2 ;;
  esac
done


# Findings are collected, not printed as they are found: the header should not appear above an
# empty list, and every loop here runs in the current shell precisely so this array survives.
notes=()
note() { notes+=("$1"); }

# Blindness check, before any domain runs. Forced by the apps retarget below: the live set now
# comes from the instance, so a report assembled against an unreachable instance would be green
# only because every read came back empty — the silent-green class this repo exists never to
# repeat. `occ status` is the cheapest question the instance must be able to answer; a transport
# failure, a down container or a broken install all fail here, as ONE note that names the truth
# instead of an all-clear that only looks like one. Report mode still exits 0 with it (the report
# contract does not change); gate mode fails on it, which is the parser-rot rule applied to the
# transport itself.
occ status >/dev/null 2>&1 \
  || note "no se ve la instancia — una lista vacía aquí sería ceguera, no limpieza; ponga la suite en marcha antes de leer este resultado"


# --- group folders: SITE_FOLDERS is the whole declared set ---
# Deleting one deletes every file inside it, which is why this is the report's headline case and why
# the suggested command is printed for a human to run rather than run here.
live_folders="$(occ groupfolders:list --output=json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in (d.values() if isinstance(d, dict) else d):
    m = r.get("mountPoint") or r.get("mount_point")
    fid = r.get("id")
    if m: print(str(fid) + "\t" + m)
')"
declared_folders="$(printf '%s\n%s\n' "${SITE_FOLDERS[@]}" "$IV_MOUNT")"   # engine mount (design §5, ADR-0020): created by
# intravox:setup, not in any SITE_FOLDERS matrix; gf_prune already leaves it alone (prune only
# touches matrix mounts)
iv_told="$(occ config:app:get intravox groupfolder_name 2>/dev/null || true)"   # what the engine was last told
while IFS=$'\t' read -r fid mount; do
  [ -n "${mount:-}" ] || continue
  printf '%s\n' "$declared_folders" | grep -qxF -- "$mount" && continue
  # The storage root under a name other than IV_MOUNT — the engine's default (seeded before
  # ADR-0020) or the name it was told before IV_MOUNT changed — holds every page: the generic
  # advice below would say to delete it. Point at the rename instead.
  if [ "$mount" = IntraVox ] || { [ -n "$iv_told" ] && [ "$mount" = "$iv_told" ]; }; then
    note "la carpeta compartida '$mount' guarda la portada con un nombre distinto del declarado '$IV_MOUNT' — contiene todas las páginas: cámbiele el nombre una vez (docs/WELCOME-SCREEN.md), nunca la borre; la preparación no corre hasta entonces"
    continue
  fi
  note "la carpeta compartida '$mount' existe pero no está en SITE_FOLDERS — conserva sus archivos; elimínela a propósito con 'occ groupfolders:delete $fid' si es lo que quiere"
done <<< "$live_folders"

# --- welcome sections: SITE_WELCOME is the declared set (phase 41, ADR-0019) ---
# Live = the top-level page folders under es/ in the IntraVox group folder — a page folder OWNS
# its own <dir>/<dir>.json (the engine importer's recursion rule, ManagedTreeImporter), so images/,
# _resources/ and _templates/ never count. An undeclared section holds staff content: phase 41 adds
# what is declared and missing and never deletes; this line is the only place a removed row is noticed.
# Tolerated silently: an instance with no IntraVox group folder (the app is not shipped here).
declare -p SITE_WELCOME >/dev/null 2>&1 || SITE_WELCOME=()   # site files written before 2026-09-27
iv_fid="$(printf '%s\n' "$live_folders" | awk -F'\t' -v m="$IV_MOUNT" '$2==m{print $1; exit}')"   # from the group-folders arm above: one occ call, one parser
if [ -n "$iv_fid" ]; then
  datadir="$(occ config:system:get datadirectory 2>/dev/null | tr -d '\r' || true)"
  # unresolved = blindness (B-014): the listing below would cd nowhere and answer "no sections"
  [ -n "$datadir" ] || note "no se pudieron revisar las secciones de la portada: occ no informó datadirectory — una lista vacía aquí sería ceguera, no limpieza"
  declared_sections="$(for e in "${SITE_WELCOME[@]}"; do printf '%s\n' "${e%%|*}"; done)"
  live_sections="$(nc_exec --user www-data -- sh -c '
    cd "$1/__groupfolders/$2/files/es" 2>/dev/null || exit 0
    for d in */; do d=${d%/}; [ -f "$d/$d.json" ] && printf "%s\n" "$d"; done' sh "$datadir" "$iv_fid" 2>/dev/null || true)"
  while read -r sec; do
    [ -n "$sec" ] || continue
    printf '%s\n' "$declared_sections" | grep -qxF -- "$sec" && continue
    note "la sección de portada '$sec' existe en la carpeta de IntraVox pero no en SITE_WELCOME — el contenido del personal se conserva; elimine es/$sec (y sus reglas de acceso) a propósito si es lo que quiere"
  done <<< "$live_sections"
fi

# --- groups ---
# The shared registry is READ OUT OF PHASE 20 rather than restated here, so there is one list and it
# is the one that runs. The coupling is to that file's shape: `ensure_group <id>` lines and
# "id|display" array entries. If the shape changes, the count guard below turns a silent
# every-role-is-undeclared report into a loud one — which is the failure mode worth designing for,
# since a report that cries wolf is a report nobody reads.
declared_shared="$( { sed -n 's/^ *"\(\(role\|cat\)-[a-z0-9-]*\)|.*/\1/p' "$PHASE20"
                     sed -n 's/^ensure_group \([a-z0-9-]*\).*/\1/p' "$PHASE20"; } | sort -u )"
shared_count="$(printf '%s\n' "$declared_shared" | grep -c . || true)"
if [ "$shared_count" -lt 20 ]; then
  note "no se pudieron revisar los grupos: solo $shared_count grupos declarados se leyeron de $PHASE20 (se esperan 27 o más) — cambió de forma; corrija las dos expresiones sed de $0 antes de confiar en este resultado"
else
  # The three engine groups (D5) join the declared set the same way: created by intravox:setup,
  # membership mapped by phases 41 and 50 (lib.sh intravox_group_map) — not registry vocabulary,
  # tolerated rather than declared in phase 20.
  declared_groups="$(printf '%s\n%s\n%s\n%s\n%s\n' "$declared_shared" "admin" \
                     "IntraVox Admins" "IntraVox Editors" "IntraVox Users"
                     for e in "${SITE_TEAMS[@]}"; do printf '%s\n' "${e%%|*}"; done
                     declare -p SITE_ROLES >/dev/null 2>&1 || SITE_ROLES=()
                     for e in "${SITE_ROLES[@]}"; do printf '%s\n' "${e%%|*}"; done)"
  # `admin` is Nextcloud's own and no phase declares it, hence its place in the declared list above.
  #
  # The difference is taken ONCE into a variable, then looped over with a here-string. Piping `occ`
  # straight into the `while` would put the loop in a subshell, where every `note` appends to a copy
  # of the array that dies with it — the report would find things and then print the all-clear.
  extra_groups="$(occ group:list --output=json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for g in (d.keys() if isinstance(d, dict) else d): print(g)
' | grep -vxF -f <(printf '%s\n' "$declared_groups") || true)"
  while read -r gid; do
    [ -n "$gid" ] || continue
    # Named, not deleted: a group that is a group folder's only grantee strands that folder when
    # removed, which is the one way "delete a group" reaches files without touching them.
    note "el grupo '$gid' existe pero no está declarado en SITE_TEAMS, SITE_ROLES ni $PHASE20 — revise que no sea el único con acceso a una carpeta compartida antes de 'occ group:delete $gid'"
  done <<< "$extra_groups"
fi

# --- apps unpacked into custom_apps that no inventory names ---
# The live set is read IN THE CONTAINER: custom_apps is where the seed unpacks (lib.sh) and where a
# hand-copied app lands, and under AIO there is no host bind mount at all — the compose-era host
# glob `apps/*/` read the same directory through the mount, and under AIO it silently matched
# nothing, which is a check that answers green without looking (the exact defect class this gate
# exists to kill). One exec; the glob runs in the container's own shell so the semantics are the
# old ones transposed — directories only, trailing slash stripped. The blindness check above already
# refused to report against an instance that cannot answer.
# TWO DECLARED SURFACES, because two things reproduce an app on a clean install:
#   - the inventories name what the SEED installs: APPS is vendored, OWN_APPS is ours and shipped
#     (ADR-0003), LAB_APPS is ours and under development (ADR-0005) — the last two carry a clone
#     URL after an `=`, stripped to the app id here. LAB_APPS is SOURCED, not sed'd:
#     dev/lab-apps.sh is a shell file, and a parser that reads it as text would silently report
#     every lab app the day its formatting changes.
#   - provisioning/apps/ names what the repo SHIPS BYTES FOR: every directory there is a tarball
#     the AIO bake (patch 030) unpacks into the image — notify_push included, which phase 12
#     deliberately does not name (v0.2.0: "gestion's stack itself does not install notify_push —
#     the tarball is vendored FOR the bake"; the suite's notify-push container runs it out of
#     custom_apps, and the stock entrypoint installs it on every start). Without this line the
#     gate would flag notify_push on every AIO clinic, baked by design — a permanently red gate
#     is the B-014 class wearing the opposite hat. On compose the line is inert: a tarballed app
#     the seed does not install never lands in custom_apps either.
# shellcheck source=../dev/lab-apps.sh
[ -f dev/lab-apps.sh ] && . dev/lab-apps.sh
apps_list="$( { sed -n 's/^APPS="\(.*\)"/\1/p' "$PHASE12"
                sed -n 's/^OWN_APPS="\(.*\)"/\1/p' "$PHASE12"
                printf '%s\n' "${LAB_APPS:-}"; } | tr ' ' '\n' | sed 's/=.*//')"
tarballed="$(cd provisioning/apps 2>/dev/null && for d in */; do printf '%s\n' "${d%/}"; done)"
declared_apps="$(printf '%s\n' "$apps_list" | grep -c . || true)"
if [ "$declared_apps" -eq 0 ]; then
  note "no se pudieron revisar las aplicaciones: $PHASE12 no trae la línea APPS="
else
  while IFS= read -r a; do
    [ -n "${a:-}" ] || continue
    printf '%s\n' "$apps_list" "$tarballed" | grep -qxF -- "$a" && continue
    note "la aplicación '$a' está en custom_apps pero nada la declara — ni APPS, ni OWN_APPS, ni LAB_APPS, ni provisioning/apps/ — una instalación limpia no la reproduce"
  done <<< "$(nc_exec --user www-data -- sh -c 'cd /var/www/html/custom_apps 2>/dev/null && for d in */; do printf "%s\n" "${d%/}"; done' 2>/dev/null || true)"
fi


# --- users: live accounts the declared set does not name (GATE MODE ONLY) ---
# Declared = the SITE_ROSTER CSV's usuario column + phase 50's standing accounts + the install's own
# admin. The standings are re-derived here exactly the way 50-users.sh derives them (sector jefes
# from SITE_TEAMS, jefatura uids from cat-jefaturas SITE_ROLES entries, the four fixed positions),
# because a phase file cannot be sourced (it creates what it declares) or sed'd (its users array is
# built at runtime). The coupling is to that derivation, and drift here can only be loud: a
# standing account this re-derivation forgets shows up as undeclared on every gate run — a gate
# that cries wolf, never one that goes green without looking. `admin` is the install's own account
# (AIO names it admin; compose takes it from NEXTCLOUD_ADMIN_USER — smoke check 12's same
# expression), and the roster is written by the Provisionador, so an operator that never ran it
# simply has no roster to read — not a guard, a legitimate empty.
# One-way diff: live-but-undeclared only. Deleting a user deletes their files (the header's first
# paragraph), so the note prints the command for a human to run, never runs it.
if [ "$gate" -eq 1 ]; then
  roster=""
  if [ -n "${SITE_ROSTER:-}" ]; then
    if [ -r "$SITE_ROSTER" ]; then
      roster="$(python3 -c '
import csv, sys
with open(sys.argv[1], encoding="utf-8-sig", newline="") as fh:
    r = csv.DictReader(fh, delimiter=";")
    if "usuario" not in (r.fieldnames or []): sys.exit(1)
    for row in r:
        u = (row.get("usuario") or "").strip()
        if u: print(u)
' "$SITE_ROSTER" 2>/dev/null)" \
        || note "no se pudieron revisar los usuarios: '$SITE_ROSTER' no tiene la columna usuario — lo declarado está incompleto; corrija la planilla"
    else
      note "no se pudieron revisar los usuarios: SITE_ROSTER nombra '$SITE_ROSTER', que no se puede leer — lo declarado está incompleto; corrija la ruta en sites/$SITE/site.sh"
    fi
  fi
  # org L5-11: the standing half comes from provisioning/standings.sh — the one derivation,
  # the same bytes phase 50 provisions from. This copy used to re-derive it by hand and was
  # documented to "fail loud" on drift: a gate that cries wolf on every clinic until fixed.
  declared_users="$(
    printf '%s\n' "${NEXTCLOUD_ADMIN_USER:-admin}"
    standing_uids
    if [ -n "$roster" ]; then printf '%s\n' "$roster"; fi
  )"
  # Same one-shot-then-loop shape as the groups domain above, for the same reason: piping into the
  # while would lose every note to a subshell copy of the array.
  # --limit 0 is UNLIMITED and is not optional here: NC's user:list caps at 500 without it
  # (core/Command/User/ListCommand.php — searchDisplayName's default limit), and a clinic past 500
  # staff would have its tail silently unlisted — the gate reading green without ever looking at
  # the accounts it was built to judge. The default listing includes disabled accounts, which is
  # what this wants: a disabled stray account is still an account that owns files.
  extra_users="$(occ user:list --output=json --limit 0 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for u in (d.keys() if isinstance(d, dict) else d): print(u)
' | grep -vxF -f <(printf '%s\n' "$declared_users") || true)"
  while read -r uid; do
    [ -n "$uid" ] || continue
    note "el usuario '$uid' existe pero no está declarado — ni en la planilla, ni es cuenta de cargo, ni el administrador de la instalación; eliminar un usuario elimina sus archivos: hágalo a propósito con 'occ user:delete $uid' si es lo que quiere"
  done <<< "$extra_users"
fi


# --- territorio's comuna keys: identity in app config, checked against the site file ---
# App-config keys are not a folder/group/app inventory; these two are checked alone because
# they are identity-bearing: an empty or wrong comuna_cut silently disarms the
# refuseAnotherComuna import door (apps/territorio ImportService::refuseAnotherComuna) while imports
# keep working. tile_url is deliberately absent — it is derived from how this instance is
# reached (overwrite.cli.url) and phase 16 converges it on every seed. The territorio admin UI
# is a second writer of these rows (ComunaConfig::set), so a deliberate re-choice appears here
# exactly like a hand-edited site file does.
if [ -z "${SITE_COMUNA_CUT:-}" ]; then
  note "sites/$SITE/site.sh no trae SITE_COMUNA_CUT — la fase 16 falla hasta regenerar el archivo (scripts/deis.py <codigo> --new <slug>)"
elif ! occ status >/dev/null 2>&1; then
  # "could not ask" is not "not present" (#143): config:app:get also exits 1 for an ABSENT
  # key (measured on the live stack), so the reads below must not read its exit code as
  # failure. occ answering is established here once with a key-independent probe; after it,
  # an absent key lands as the empty string — which is exactly the drift this section
  # exists to name, and a section that cannot tell an absent key from a broken occ is a
  # section that reports nothing on the install that needs it most.
  note "no se pudieron leer las claves de comuna de territorio — occ no respondió; no se revisó nada"
else
  have="$(occ config:app:get territorio comuna_cut 2>/dev/null || true)"
  [ "$have" = "$SITE_COMUNA_CUT" ] || note "territorio comuna_cut es '${have:-<sin valor>}' pero sites/$SITE/site.sh dice '$SITE_COMUNA_CUT' — la re-provisión lo vuelve a converger, o el administrador elige la comuna a propósito"
  have="$(occ config:app:get territorio comuna_name 2>/dev/null || true)"
  [ "$have" = "${SITE_COMUNA:-}" ] || note "territorio comuna_name es '${have:-<sin valor>}' pero sites/$SITE/site.sh dice '${SITE_COMUNA:-}' — la re-provisión lo vuelve a converger"
fi

# --- estadistica's establishment: identity in app config, checked against the site file ---
# Same reason as territorio's pair above: a wrong deis_code does not fail, it shows another
# clinic's figures as this one's, and an unset one shows none (apps/estadistica Establishment::of).
# Unlike territorio, the app has no second writer, so any difference here is a hand-set key or a
# site file edited after the last install. Checked whether the app is installed or not: phase 16
# writes the keys either way.
if [ -z "${SITE_DEIS:-}" ]; then
  note "sites/$SITE/site.sh no trae SITE_DEIS — la fase 16 falla hasta regenerar el archivo (scripts/deis.py <codigo> --new <slug>)"
elif ! occ status >/dev/null 2>&1; then
  note "no se pudieron leer las claves del establecimiento en estadistica — occ no respondió; no se revisó nada"
else
  for pair in "deis_code=$SITE_DEIS" "establishment_type=${SITE_TIPO:-}" "comuna_cut=${SITE_COMUNA_CUT:-}"; do
    have="$(occ config:app:get estadistica "${pair%%=*}" 2>/dev/null || true)"
    [ "$have" = "${pair#*=}" ] || note "estadistica ${pair%%=*} es '${have:-<sin valor>}' pero sites/$SITE/site.sh dice '${pair#*=}' — la re-provisión lo vuelve a converger"
  done
fi

if [ "${#notes[@]}" -eq 0 ]; then
  [ "$quiet" -eq 1 ] || echo "  nada en la instancia que el repositorio no declare"
  exit 0
fi

# Deliberately not a warning banner in report mode. These are things a person decided to do; the
# report exists so the decision is visible on the next install, not so anyone feels told off.
# Gate mode is the one place a banner is the point: the consumer's contract is exit-code-first, and
# a red run that ends without saying so is a red run nobody diagnoses.
printf '\n  en esta instancia, sin declarar en el repositorio:\n'
printf '    %s\n' "${notes[@]}"
if [ "$gate" -eq 1 ]; then
  printf '\n  DIVERGENCIA: ✗ — la entrega queda limpia solo con esta lista vacía; resuelva o declare cada elemento de arriba\n'
  exit 1
fi
exit 0
