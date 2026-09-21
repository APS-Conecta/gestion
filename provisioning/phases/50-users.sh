# Phase 50 — the clinic's standing leadership accounts.  OWNER: Story 0.6, redefined 2026-08-01.
# Creates one account per POSITION every CESFAM has, idempotently via ensure_user, and adds each to
# groups phase 20 already created (this phase never creates structure — AD-2). The ordering that
# guarantees is the runner's own: 20-groups -> 30-folders -> 40-acl -> here.
#
# GATED BY SEED_FIXTURES, one shared password. These are POSITIONS, not people: #86 settled the
# roster format and closed 2026-08-01, and the reader waits on password delivery (#106). Every jefe
# de sector holds a role, a sector team and a category at once — the role-union this phase shows.
phase_begin "50-users" "The clinic's standing leadership accounts"

: "${FIXTURE_USER_PASSWORD:?set FIXTURE_USER_PASSWORD in .env}"

# One jefe PER SECTOR, derived from the site file rather than named here: an establishment with four
# sectors gets four, one with two gets two, and this file does not change. A single jefe holding
# every sector team could open every sector's folder, which would leave the per-sector ACL matrix
# true on paper and untested in practice — the separation is the part worth demonstrating.
sector_jefes=()
for entry in "${SITE_TEAMS[@]}"; do
  id="${entry%%|*}"; display="${entry#*|}"
  case "$id" in
    # `sector-norte` -> `jefe.norte`, and the display name carries the sector's own label, so
    # it reads as the clinic wrote it, accents included.
    sector-*) sector_jefes+=("jefe.${id#sector-}|Jefe/a de ${display}|role-jefe-sector-mais ${id} cat-jefaturas all-staff") ;;
  esac
done

# The same move for roles the clinic added itself (#103). A jefatura is a POSITION and this phase
# creates one account per position, so a clinic-local Jefe/a de SAR gets one exactly as the four
# fixed jefaturas do. ONLY cat-jefaturas: a local clinical or technical role — a SAR's TENS, say —
# describes many people rather than a post, and those accounts arrive with the roster (#106).
#
# The uid is DERIVED, not declared: `role-jefe-sar` -> `jefe.sar`, which is the convention the fixed
# jefaturas below already follow. A fourth field would be a second name for the same thing and a
# second thing to get out of step.
local_jefes=()
for entry in "${SITE_ROLES[@]}"; do
  id="${entry%%|*}"; rest="${entry#*|}"; display="${rest%%|*}"; category="${rest##*|}"
  [ "$category" = cat-jefaturas ] || continue
  uid="${id#role-}"; uid="${uid//-/.}"
  local_jefes+=("${uid}|${display}|${id} ${category} all-staff")
done

# The positions every CESFAM has, whatever its sectors. Each entry:
#   uid | display | groups  (space-separated: role-*, cat-*, all-staff, optional team ids)
# cat-jefaturas is load-bearing rather than decorative: SITE_ACL grants it on every Unidades folder,
# so a lead outside it would lead a unit it cannot open.
# A clinic with a SAR, SAPU or other local unit declares its lead in SITE_ROLES (#103) — see above.
users=(
  "director|Director/a de CESFAM|role-director-cesfam cat-jefaturas all-staff"
  "subdirector|Subdirector/a Médico o Jefe Técnico|role-subdirector-jefe-tecnico cat-jefaturas all-staff"
  # The Químico Farmacéutico IS the pharmacy's technical director — one position, not two.
  "jefe.farmacia|Jefe/a de Farmacia (Químico/a Farmacéutico/a)|role-quimico-farmaceutico cat-jefaturas all-staff"
  "jefe.some|Jefe/a de SOME|role-jefe-some cat-jefaturas all-staff"
  "${sector_jefes[@]}"
  "${local_jefes[@]}"
)

for entry in "${users[@]}"; do
  uid="${entry%%|*}"; rest="${entry#*|}"; display="${rest%%|*}"; groups="${rest#*|}"
  ensure_user "$uid" "$display" "$FIXTURE_USER_PASSWORD"
  # Add to each group ONLY if it exists (phase 20 owns them). A missing group is logged, not fatal:
  # a clinic may legitimately not carry a position, and the account is still worth having.
  for g in $groups; do
    if group_exists "$g"; then add_user_to_group "$uid" "$g"
    else log "group $g not provisioned — skipping for $uid (phase 20 must run first)"; fi
  done
done

phase_end
