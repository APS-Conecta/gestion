# Phase 40 — ACLs.  OWNER: Epic 3 (only Epic 3 edits this file).
# Applies the first-cut access matrix (PRD §4.4) as base group grants on the phase-30 folders —
# ALLOW-REFINEMENT, NO DENY (AD-4). Read = no perms; Write/Manage = "read write". Grants target GROUP
# IDs only (FR-10). Category granularity ("Dirección/Jefaturas" = cat-jefaturas); per-role refinement is
# deferred to the CESFAM-validated matrix. Idempotent (gf_grant re-applies the same grant).
phase_begin "40-acl" "First-cut access matrix — allow-refinement ACLs (Epic 3)"

# Transversal — all-staff readable; jefaturas manage.
gf_grant "Transversal" all-staff
gf_grant "Transversal" cat-jefaturas read write

# Programas — the program's team + jefaturas manage.
gf_grant "Programas/Salud Mental"   prog-salud-mental   read write; gf_grant "Programas/Salud Mental"   cat-jefaturas read write
gf_grant "Programas/Infantil"       prog-infantil       read write; gf_grant "Programas/Infantil"       cat-jefaturas read write
gf_grant "Programas/Cardiovascular" prog-cardiovascular read write; gf_grant "Programas/Cardiovascular" cat-jefaturas read write

# Unidades — jefaturas read; the owning role manages. Estadística-REM stays read-narrow (only jefaturas + owner).
gf_grant "Unidades/SOME"            cat-jefaturas; gf_grant "Unidades/SOME"            role-administrativo-some  read write
gf_grant "Unidades/Farmacia"        cat-jefaturas; gf_grant "Unidades/Farmacia"        role-quimico-farmaceutico read write; gf_grant "Unidades/Farmacia" role-tens-farmacia read write
gf_grant "Unidades/Dental"          cat-jefaturas; gf_grant "Unidades/Dental"          role-dentista             read write; gf_grant "Unidades/Dental" role-tons read write
gf_grant "Unidades/OIRS"            cat-jefaturas; gf_grant "Unidades/OIRS"            role-oirs                 read write
gf_grant "Unidades/Estadística-REM" cat-jefaturas; gf_grant "Unidades/Estadística-REM" role-estadistica-rem     read write
gf_grant "Unidades/Dirección"       cat-jefaturas read write

# Sectores — the sector's team + jefaturas manage.
gf_grant "Sectores/Sector 1"    sector-1    read write; gf_grant "Sectores/Sector 1"    cat-jefaturas read write
gf_grant "Sectores/Sector Azul" sector-azul read write; gf_grant "Sectores/Sector Azul" cat-jefaturas read write

phase_end
