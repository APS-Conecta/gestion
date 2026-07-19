# Phase 50 — sample users (FIXTURE, dev-only — gated by SEED_FIXTURES).  OWNER: Story 0.6.
# Creates a small set of clearly-synthetic sample users via ensure_user (idempotent), and adds
# them to all-staff ONLY if that group already exists (Epic 2 owns it — fixtures never create
# structure, AD-2). Structure lives in phases 20–40.
phase_begin "50-users" "Synthetic sample users into existing groups (Story 0.6)"

: "${FIXTURE_USER_PASSWORD:?set FIXTURE_USER_PASSWORD in .env}"

# Clearly-synthetic fixtures: `dev.` id prefix + "(fixture)" display name.  entry = "uid|display"
users=(
  "dev.direccion|DEV Dirección (fixture)"
  "dev.some|DEV SOME (fixture)"
  "dev.medico|DEV Médico (fixture)"
  "dev.matrona|DEV Matrona (fixture)"
)

for entry in "${users[@]}"; do
  uid="${entry%%|*}"; display="${entry#*|}"
  ensure_user "$uid" "$display" "$FIXTURE_USER_PASSWORD"
  if group_exists all-staff; then
    add_user_to_group "$uid" all-staff
  else
    log "all-staff not provisioned yet (Epic 2) — skipping grouping for $uid"
  fi
done

phase_end
