---
baseline_commit: c25c94556f68edd1a23d3864cd0cc1b879c053f6
---

# Story 2.2: User provisioning + multi-role membership

Status: review

## Story

As an administrator,
I want to create users and assign one or more role groups,
so that people receive exactly their roles' access — the union, nothing more.

## Acceptance Criteria

1. **Membership (FR-11).** `phase 50-users` places each user into their `role-*`, their `cat-*`, `all-staff`,
   and any `prog-*`/`sector-*` teams via `occ group:adduser`.
2. **Multi-role union.** A user in two groups receives the union of both; a fixture user is deliberately
   multi-membership to demonstrate it.
3. **Idempotent + partition (AD-2).** Re-runs converge (query-before-add); membership only targets
   **already-existing** groups (phase 20 owns creation — fixtures never create groups).

## Tasks / Subtasks

- [x] **Task 1: Extend `phase 50-users.sh`** — per-user group lists (role + cat + all-staff + optional teams);
  `add_user_to_group` for each, guarded by `group_exists`.
- [x] **Task 2: Multi-role fixture** — `dev.medico` ∈ role-medico + cat-clinicos + all-staff +
  prog-cardiovascular + sector-1 (union demo).
- [x] **Task 3: Query-before-add guard** — `add_user_to_group` now checks `user_in_group` first (accurate
  logging + true idempotency).
- [x] **Task 4: Verify** — memberships applied; `occ user:info dev.medico` → 5 groups; re-seed → all "already
  in group".

## Dev Notes

- **FR-11 (user provisioning + multi-role union):** access = the union of a user's groups; group-only
  principals (AD-4). Removing a group revokes exactly that group's access; the user stays in `all-staff`.
  [Source: prd.md#FR-11; ARCHITECTURE-SPINE.md#AD-4]
- **Structure-vs-fixtures partition (AD-2):** phase 50 adds users to **existing** groups (phase 20 created
  them) — `add_user_to_group` is guarded by `group_exists`, and never creates a group.
- **`add_user_to_group` is now query-before-add:** `occ group:adduser` returns 0 even for an existing member,
  so the helper first checks `user_in_group` (via `occ user:info … groups`) for accurate, idempotent logging.
- The four synthetic fixtures (Story 0.6) get realistic role/category assignments; `dev.medico` is
  intentionally cross-category (role + program + sector) to exercise the union.
- Owns the membership block of `phase 50-users`; group creation is Story 2.1's `phase 20-groups`.

### References

- [Source: docs/planning/epics.md#Story 2.2] · [ARCHITECTURE-SPINE.md#AD-4, #AD-2] · [prd.md#FR-11]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

- `make seed` → phase 50 added each fixture to its groups: `dev.direccion` (role-director-cesfam, cat-jefaturas,
  all-staff); `dev.some` (role-administrativo-some, cat-administrativos, all-staff); `dev.medico` (role-medico,
  cat-clinicos, all-staff, prog-cardiovascular, sector-1); `dev.matrona` (role-matroneria, cat-clinicos,
  all-staff, prog-salud-mental). `occ user:info dev.medico` → `['all-staff','cat-clinicos','role-medico',
  'prog-cardiovascular','sector-1']` (union). Re-seed → **15** memberships all "already in group" (idempotent).

### Completion Notes List

- Multi-role membership works and is idempotent via a query-before-add guard (`user_in_group`).
- Fixtures never create groups — memberships target only phase-20 groups (guarded); partition held.

### File List

- `provisioning/phases/50-users.sh` (extended — per-user multi-role membership)
- `provisioning/lib.sh` (modified — `add_user_to_group` query-before-add + `user_in_group`)

## Change Log

- 2026-07-19 — Implemented (Epic 2): multi-role membership in `50-users` (role+cat+all-staff+teams), query-before-add guard, `dev.medico` union demo. Verified live + idempotent. Status → review.
