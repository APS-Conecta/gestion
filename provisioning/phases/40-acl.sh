# Phase 40 — ACLs.  OWNER: Epic 3 (only Epic 3 edits this file).
# Applies the first-cut access matrix (PRD §4.4) as base group grants on the phase-30 folders —
# ALLOW-REFINEMENT, NO DENY (AD-4). Read = no perms; Manage = "read write delete". Grants target GROUP
# IDs only (FR-10). Category granularity ("Dirección/Jefaturas" = cat-jefaturas); per-role refinement is
# deferred to the CESFAM-validated matrix. Idempotent (gf_grant re-applies the same grant).
#
# Manage includes DELETE (owner decision 2026-07-30). "read write" alone is READ|UPDATE|CREATE, which
# makes a folder append-only: a wrong upload can never be removed, and files cannot even be moved,
# because a move needs delete on the source. Only admin could tidy up, and staff work around it by
# leaving _v2/_final copies — the opposite of docs/CONVENTIONS.md's one-live-copy rule. Group folders
# keep their own trash, so a delete stays recoverable.
#
# TEMPORARY — EVERY grant here is currently "read write delete", including the rows that were
# read-only: all-staff on Transversal, and cat-jefaturas on the five Unidades. Owner decision
# 2026-07-30: the folder tree is about to be reorganised and routes defined, and moving anything
# needs delete on the source, so read-only rows would block the restructuring itself.
#
# What this costs while it lasts: any staff account can delete anything in any Team Folder,
# including the shared protocols in Transversal. Recoverable from each folder's trash, but there is
# no longer any difference between "can read" and "can manage" — which is what FR-10 and the PRD §4.4
# matrix exist to express. This file therefore records WHO has access to WHAT, but no longer at what
# level.
#
# Restore before real staff use: put the read-only rows back to a bare `gf_grant "Mount" group`
# (bitmask 1) once the tree is settled. Both halves are one edit away and the seed is idempotent.
phase_begin "40-acl" "First-cut access matrix — allow-refinement ACLs (Epic 3)"

# Transversal — all-staff readable; jefaturas manage.
gf_grant "Transversal" all-staff read write delete
gf_grant "Transversal" cat-jefaturas read write delete

# Programas — the program's team + jefaturas manage.
gf_grant "Programas/Salud Mental"   prog-salud-mental   read write delete; gf_grant "Programas/Salud Mental"   cat-jefaturas read write delete
gf_grant "Programas/Infantil"       prog-infantil       read write delete; gf_grant "Programas/Infantil"       cat-jefaturas read write delete
gf_grant "Programas/Cardiovascular" prog-cardiovascular read write delete; gf_grant "Programas/Cardiovascular" cat-jefaturas read write delete

# Unidades — jefaturas read; the owning role manages. Estadística-REM stays read-narrow (only jefaturas + owner).
gf_grant "Unidades/SOME"            cat-jefaturas read write delete; gf_grant "Unidades/SOME"            role-administrativo-some  read write delete
gf_grant "Unidades/Farmacia"        cat-jefaturas read write delete; gf_grant "Unidades/Farmacia"        role-quimico-farmaceutico read write delete; gf_grant "Unidades/Farmacia" role-tens-farmacia read write delete
gf_grant "Unidades/Dental"          cat-jefaturas read write delete; gf_grant "Unidades/Dental"          role-dentista             read write delete; gf_grant "Unidades/Dental" role-tons read write delete
gf_grant "Unidades/OIRS"            cat-jefaturas read write delete; gf_grant "Unidades/OIRS"            role-oirs                 read write delete
gf_grant "Unidades/Estadística-REM" cat-jefaturas read write delete; gf_grant "Unidades/Estadística-REM" role-estadistica-rem     read write delete
gf_grant "Unidades/Dirección"       cat-jefaturas read write delete

# Sectores — the sector's team + jefaturas manage.
gf_grant "Sectores/Sector 1"    sector-1    read write delete; gf_grant "Sectores/Sector 1"    cat-jefaturas read write delete
gf_grant "Sectores/Sector Azul" sector-azul read write delete; gf_grant "Sectores/Sector Azul" cat-jefaturas read write delete

phase_end
