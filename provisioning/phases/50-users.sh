# Phase 50 — sample users (FIXTURE, dev-only — gated by SEED_FIXTURES).  OWNER: Story 0.6.
# Creates a small set of clearly-synthetic sample users via ensure_user (idempotent), and adds
# them to all-staff ONLY if that group already exists (Epic 2 owns it — fixtures never create
# structure, AD-2). Structure lives in phases 20–40.
phase_begin "50-users" "Synthetic sample users into existing groups (Story 0.6)"

: "${FIXTURE_USER_PASSWORD:?set FIXTURE_USER_PASSWORD in .env}"

# Clearly-synthetic fixtures + their multi-role membership (Story 2.2). Each entry:
#   uid | display | groups  (space-separated: role-*, cat-*, all-staff, optional prog-*/sector-* teams)
# dev.medico is deliberately multi-membership to exercise the role-union (Story 2.2 AC).
users=(
  "dev.direccion|DEV Dirección (fixture)|role-director-cesfam cat-jefaturas all-staff"
  "dev.some|DEV SOME (fixture)|role-administrativo-some cat-administrativos all-staff"
  "dev.medico|DEV Médico (fixture)|role-medico cat-clinicos all-staff prog-cardiovascular sector-1"
  "dev.matrona|DEV Matrona (fixture)|role-matroneria cat-clinicos all-staff prog-salud-mental"
)

for entry in "${users[@]}"; do
  uid="${entry%%|*}"; rest="${entry#*|}"; display="${rest%%|*}"; groups="${rest#*|}"
  ensure_user "$uid" "$display" "$FIXTURE_USER_PASSWORD"
  # Add to each group ONLY if it exists (Epic 2's phase 20 owns/creates them; fixtures never create groups).
  for g in $groups; do
    if group_exists "$g"; then add_user_to_group "$uid" "$g"
    else log "group $g not provisioned — skipping for $uid (phase 20 must run first)"; fi
  done
done

phase_end
