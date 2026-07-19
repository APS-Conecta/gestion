# Phase 60 — sample content (FIXTURE, dev-only — gated by SEED_FIXTURES).  OWNER: Story 0.6.
# Delivers the content-fixture MECHANISM: one clearly-synthetic welcome note in a sample user's
# own Files, seeded idempotently via ensure_sample_file. Folder/role-specific content is Epics 2–3.
phase_begin "60-fixtures" "Deterministic synthetic sample content (Story 0.6)"

if user_exists dev.direccion; then
  ensure_sample_file dev.direccion "Bienvenida-APS-Conecta.md" \
"# Bienvenida a APS Conecta (archivo de ejemplo)

Este es un archivo de ejemplo **sintético** creado por el aprovisionamiento de desarrollo.
No contiene datos reales. El contenido por carpeta y por rol se agrega en los Épicos 2 y 3.
"
else
  log "sample user dev.direccion not present — phase 50-users must run first"
fi

phase_end
