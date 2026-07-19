---
baseline_commit: 64c720b82a838ec75804118722008c63ea3f93b2
---

# Story 3.2: Apply the first-cut access matrix

Status: review

## Story

As a staff member, I want each folder wired to my role groups, so that I see and edit exactly what my role permits.

## Acceptance Criteria

1. **First-cut matrix (allow-refinement, NO DENY).** `phase 40-acl` grants each folder to groups per the PRD §4.4 matrix using base group grants (read = no perms; write/manage = `read write`). Grants target **group IDs only** (FR-10).
2. **FR-13 consequences.** A single-role Médico reads Transversal (via `all-staff`) but cannot see `Unidades/Farmacia`; `role-estadistica-rem` manages `Unidades/Estadística-REM` while other non-Dirección roles cannot read it.
3. **Idempotent.** Re-seed re-applies the same grants cleanly.

## Tasks / Subtasks

- [x] **Task 1: Fill `phase 40-acl.sh`** — `gf_grant` per the matrix (Transversal all-staff-read/jefaturas-manage; Programas team+jefaturas; Unidades jefaturas-read + owner-manage; Estadística-REM read-narrow; Sectores team+jefaturas).
- [x] **Task 2: `gf_grant` helper** — looks up the folder id (`groupfolder_id`) and runs `groupfolders:group id group [read write]`; allow-only, idempotent.
- [x] **Task 3: Verify** — the effective group set per folder matches the matrix; Médico-access = True for Transversal, **False** for Farmacia and Estadística-REM.

## Dev Notes

- **AD-4 / allow-refinement, NO DENY:** base group grants are inherently allow-only; a folder is invisible to groups it isn't granted to, which gives the "read-narrow" folders (Estadística-REM) for free. Advanced per-subfolder ACL (e.g. Transversal/Registro de redes, Actas) is **deferred** to the CESFAM-validated matrix (PRD: final matrix comes later). [Source: ARCHITECTURE-SPINE.md#AD-4; PRD §4.4, FR-13]
- **Category granularity:** "Dirección/Jefaturas" = `cat-jefaturas`. Per-role refinement beyond the first cut is deferred.
- **Every grant targets a group** (FR-10) — `groupfolders:group` takes a group, never a user.
- Verification is at the **grant/config level** (the effective group set matches the matrix). Per-user browse (read vs write in the UI) is a documented manual check.

### File List
- `provisioning/phases/40-acl.sh` (filled), `provisioning/lib.sh` (+`gf_grant`)

## Dev Agent Record

### Agent Model Used
claude-opus-4-8[1m]

### Debug Log References
- `make seed` → phase 40 applied all first-cut grants. `groupfolders:list` groups-per-folder: Transversal = {all-staff, cat-jefaturas}; Farmacia = {cat-jefaturas, role-quimico-farmaceutico, role-tens-farmacia}; Estadística-REM = {cat-jefaturas, role-estadistica-rem}. Médico (role-medico/cat-clinicos/all-staff) access: Transversal=True, Farmacia=False, Estadística-REM=False (FR-13 ✓). Idempotent on re-seed.

### Completion Notes List
- First-cut matrix applied as allow-only base grants; read-narrow works via non-grant; advanced per-subfolder ACL deferred to the validated matrix.

## Change Log
- 2026-07-19 — Implemented (Epic 3): first-cut access matrix (allow-refinement, no DENY) via `gf_grant`. FR-13 consequences verified at grant level. Status → review.
