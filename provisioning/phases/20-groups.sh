# Phase 20 — groups.  OWNER: Epic 2 (only Epic 2 edits this file).
# Provisions the canonical Group Registry (docs/ARCHITECTURE.md, "Access model"): all-staff, the 4 cat-*
# categories, the 22 shared role-* groups, this clinic's own roles, and its prog-*/sector-* teams.
# English IDs, Spanish display names. Idempotent (ensure_group = query-before-create). Grants target
# IDs, never display names.
#
# THE GROUP IS THE ONLY ACCESS KEY THIS SYSTEM HAS (#103). Every helper that grants anything takes a
# group id and nothing else — gf_grant for folders, app_restrict_to_groups for apps,
# add_user_to_group for people — so "what may this user reach" is answered entirely by "which groups
# is this user in". Any custom app added later plugs into the same key; there is no second mechanism
# to design. The standing rule that follows: GRANT ON THE BROADEST GROUP THAT IS STILL CORRECT,
# which means cat-* over role-* unless the job title is genuinely the point. That is what lets a
# clinic add a Jefe de SAR and have it inherit every existing grant without one being edited.
phase_begin "20-groups" "Role / category / team group registry (Epic 2)"

# Every user belongs here.
ensure_group all-staff "Todo el personal"

# Categories (4).
ensure_group cat-jefaturas       "Jefaturas"
ensure_group cat-clinicos        "Clínicos"
ensure_group cat-tecnicos        "Técnicos"
ensure_group cat-administrativos "Administrativos"

# Roles (22) — id|display, verbatim from the Group Registry. Shared by EVERY clinic: this is the
# vocabulary that keeps one clinic's ACL matrix readable beside another's. Clinic-local additions go
# in the site file, below.
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
  # The SOME LEAD, distinct from the clerks above. Its own group rather than "an administrativo who
  # is also in cat-jefaturas", so it reads the same way Director and Jefe de Sector already do —
  # and so a grant can name the lead without naming the whole counter.
  "role-jefe-some|Jefe/a de SOME"
  "role-oirs|Encargado/a OIRS"
  "role-estadistica-rem|Encargado/a de Estadística (REM)"
  "role-conductor|Conductor (Ambulancia / Traslado)"
  "role-auxiliar-servicio|Auxiliar de Servicio"
)
for entry in "${roles[@]}"; do ensure_group "${entry%%|*}" "${entry#*|}"; done

# --- Roles this clinic adds for itself (#103) — id|display|category, from sites/$SITE/site.sh ---
# The 22 above are every CESFAM's. A clinic running a SAR, SAPU or SUR needs roles this file cannot
# name: it could already declare the unit, its folder and its grants, and then had no way to say who
# leads it. Same split as SITE_TEAMS below — shared vocabulary in code, local additions in data.
#
# THE CATEGORY IS LOAD-BEARING, not a label. Nextcloud groups do not nest, so a role grants nothing
# by "belonging to" a category; what gives a person access is the set of groups they are IN. The
# third field declares which cat-* an account holding this role must ALSO join — 50-users reads it
# for the standing jefaturas it creates, and the roster reader (#106) will read it for everyone else.
# It is declared per role rather than defaulted to cat-jefaturas because a local unit needs both:
# a lead (cat-jefaturas) and its technicians (cat-tecnicos). Unit folders are granted BY ROLE, so
# without a local role a SAR's folder would open to every TENS in the building.
#
# The four categories are NOT site-definable: they are what makes an ACL matrix comparable across
# clinics. A typo here would create a group nothing ever grants on, so it fails loudly instead.
for entry in "${SITE_ROLES[@]}"; do
  id="${entry%%|*}"; rest="${entry#*|}"; display="${rest%%|*}"; category="${rest##*|}"
  case "$id" in
    role-*) ;;
    *) echo "FATAL: SITE_ROLES entry '$id' must start with 'role-' — a bare id reads as a team." >&2
       exit 1 ;;
  esac
  case "$category" in
    cat-jefaturas|cat-clinicos|cat-tecnicos|cat-administrativos) ;;
    *) echo "FATAL: SITE_ROLES entry '$id' names category '$category'." >&2
       echo "       Expected one of: cat-jefaturas cat-clinicos cat-tecnicos cat-administrativos." >&2
       echo "       Categories are shared across clinics and cannot be added by a site file (#103)." >&2
       exit 1 ;;
  esac
  ensure_group "$id" "$display"
done

# Team groups — programs and territorial sectors, which differ in every clinic. Data, not code:
# sites/$SITE/site.sh. Epic-3 folders bind to these team IDs.
for entry in "${SITE_TEAMS[@]}"; do ensure_group "${entry%%|*}" "${entry#*|}"; done

phase_end
