# Phase 20 — groups.  OWNER: Epic 2 (only Epic 2 edits this file).
# Provisions the canonical Group Registry (docs/ARCHITECTURE.md, "Access model"): all-staff, the 4 cat-*
# categories, the 21 role-* groups, and example prog-*/sector-* team placeholders. English IDs, Spanish
# display names. Idempotent (ensure_group = query-before-create). Grants target IDs, never display names.
phase_begin "20-groups" "Role / category / team group registry (Epic 2)"

# Every user belongs here.
ensure_group all-staff "Todo el personal"

# Categories (4).
ensure_group cat-jefaturas       "Jefaturas"
ensure_group cat-clinicos        "Clínicos"
ensure_group cat-tecnicos        "Técnicos"
ensure_group cat-administrativos "Administrativos"

# Roles (21) — id|display, verbatim from the Group Registry.
roles=(
  "role-director-cesfam|Director/a de CESFAM"
  "role-subdirector-jefe-tecnico|Subdirector/a Médico o Jefe Técnico"
  "role-jefe-sector-mais|Jefe/a de Sector (Gestión MAIS)"
  "role-medico|Médico General / de Familia"
  "role-dentista|Cirujano Dentista"
  "role-quimico-farmaceutico|Químico Farmacéutico (Dir. Técnico Farmacia)"
  "role-enfermeria|Enfermera/o"
  "role-matroneria|Matrona/Matrón"
  "role-kinesiologo|Kinesiólogo/a"
  "role-psicologo|Psicólogo/a"
  "role-trabajador-social|Trabajador/a Social"
  "role-nutricionista|Nutricionista"
  "role-terapeuta-fono|Terapeuta Ocupacional / Fonoaudiólogo/a"
  "role-tens-procedimientos|TENS – Procedimientos / Vacunatorio"
  "role-tens-farmacia|TENS – Farmacia / PNAC"
  "role-tons|TONS (Técnico en Odontología)"
  "role-administrativo-some|Administrativo SOME"
  "role-oirs|Encargado/a OIRS"
  "role-estadistica-rem|Encargado/a de Estadística (REM)"
  "role-conductor|Conductor (Ambulancia / Traslado)"
  "role-auxiliar-servicio|Auxiliar de Servicio"
)
for entry in "${roles[@]}"; do ensure_group "${entry%%|*}" "${entry#*|}"; done

# Team-group placeholders — parameterized PER CESFAM (names/colours vary). These are example dev seeds;
# a real deployment renames/extends them. Epic-3 folders bind to these team IDs.
teams=(
  "prog-salud-mental|Programa Salud Mental"
  "prog-infantil|Programa Infantil"
  "prog-cardiovascular|Programa Cardiovascular"
  "sector-1|Sector 1"
  "sector-azul|Sector Azul"
)
for entry in "${teams[@]}"; do ensure_group "${entry%%|*}" "${entry#*|}"; done

phase_end
