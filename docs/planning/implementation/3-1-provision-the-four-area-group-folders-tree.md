---
baseline_commit: 64c720b82a838ec75804118722008c63ea3f93b2
---

# Story 3.1: Provision the four-area Group Folders tree

Status: review

## Story

As an administrator, I want the hybrid four-area tree provisioned as Group Folders, so that Spine A's structure exists.

## Acceptance Criteria

1. **Mount model (AD-4).** `phase 30-folders` installs the `groupfolders` app and creates `Transversal` (one group folder, with its shared-knowledge subfolders) + one group folder **per program/unit/sector** — matching the first-cut layout (PRD §4.4).
2. **No nesting assumption; idempotent.** Group Folders can't nest — slash mount points (`Programas/…`, `Unidades/…`, `Sectores/…`) give the tree look; `ensure_groupfolder` queries first (`groupfolders:create` is NOT idempotent by name), so re-seed produces no duplicates.

## Tasks / Subtasks

- [x] **Task 1: Install groupfolders** — `ensure_app groupfolders` (structural dep; nobody installed it before — the "who installs this?" gap).
- [x] **Task 2: Fix the infra the mount needs** — `custom_apps` bind-mount (Story 0.8, root-owned) isn't writable by www-data, so app installs failed; added `make fix-mount-perms` (chown in-container, no host sudo) to `make up`/`up-dev`; gitignore app-store apps in `/apps`.
- [x] **Task 3: Fix `groupfolder_id`** — groupfolders v22 JSON uses `mountPoint` (camelCase), not `mount_point` — the Story-0.5 helper was latently wrong (first exercised here). Accept both.
- [x] **Task 4: Create the tree** — 12 group folders + Transversal's 5 subfolders (`ensure_gf_subfolder`).
- [x] **Task 5: Verify** — `groupfolders:list` = 12 folders, **no duplicates** on re-seed (idempotent).

## Dev Notes

- **AD-4 mount model:** Transversal = one group folder; each program/unit/sector = its own. Grants (Story 3.2) target group IDs. [Source: ARCHITECTURE-SPINE.md#AD-4; PRD §4.4]
- **`groupfolders` (Team folders) is a stack component that nobody installed** until now — phase 30 owns it (`ensure_app`). It installs into `custom_apps` (bind-mounted `./apps`), which must be www-data-writable → `make fix-mount-perms`.
- **Slash mount points work** (verified: `Unidades/Farmacia` stores as-is) — the nested tree look without real nesting.
- Program/unit/sector names are **CESFAM-parameterizable placeholders**; the 3 program folders align with the Epic-2 `prog-*` groups.

### File List
- `provisioning/phases/30-folders.sh` (filled), `provisioning/lib.sh` (+`ensure_app`/`gf_grant`/`ensure_gf_subfolder`/`ensure_gf_file`; fixed `groupfolder_id` mountPoint), `Makefile` (+`fix-mount-perms`, wired into up/up-dev), `.gitignore` (app-store apps in /apps)

## Dev Agent Record

### Agent Model Used
claude-opus-4-8[1m]

### Debug Log References
- `make seed` → `groupfolders 22.0.3` installed; 12 group folders + 5 Transversal subfolders created. `groupfolders:list` = **12, no duplicates** after repeated seeds. Slash mount points confirmed.
- Fixed two latent bugs surfaced here: `custom_apps` not writable (Story 0.8 mount) → `make fix-mount-perms`; `groupfolder_id` used `mount_point` but v22 emits `mountPoint`.

### Completion Notes List
- The four-area tree exists as Group Folders (config-as-code, idempotent). Grants are Story 3.2.

## Change Log
- 2026-07-19 — Implemented (Epic 3): four-area Group Folders tree + groupfolders install + mount-perms/helper fixes. Verified live (12 folders, no dupes). Status → review.
