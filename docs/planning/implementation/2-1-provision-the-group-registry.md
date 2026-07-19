---
baseline_commit: c25c94556f68edd1a23d3864cd0cc1b879c053f6
---

# Story 2.1: Provision the group registry

Status: review

## Story

As an administrator,
I want the role/category/all-staff/team groups provisioned,
so that access can be granted per group (never per individual).

## Acceptance Criteria

1. **Full registry (AR-4).** `phase 20-groups` provisions `all-staff`, the 4 `cat-*` categories, all **21
   `role-*`** groups (per the Group Registry IDs), and example `prog-*`/`sector-*` team placeholders — English
   IDs, **Spanish display names**.
2. **Extensible (FR-10).** Adding a role group later doesn't disturb existing groups' access (flat groups;
   grants target IDs).
3. **Idempotent (query-before-create).** `make seed` re-runs converge — `ensure_group` skips existing groups.

## Tasks / Subtasks

- [x] **Task 1: Fill `phase 20-groups.sh`** — `ensure_group` for `all-staff`, 4 `cat-*`, 21 `role-*` (verbatim
  from the registry), 5 example `prog-*`/`sector-*` placeholders.
- [x] **Task 2: Display-name support** — extend `ensure_group GID [DISPLAY]` to pass `occ group:add
  --display-name` (verified supported on NC34).
- [x] **Task 3: Verify** — `occ group:list` = 21 role + 4 cat + 5 team + all-staff (+admin default = 32);
  `occ group:info` confirms Spanish display names; re-seed → all "exists" (idempotent).

## Dev Notes

- **AR-4 / Group Registry:** the canonical taxonomy is the invariant (IDs, slug rule, role→category map);
  `prog-*`/`sector-*` are CESFAM-parameterized placeholders. Grants target **IDs**, never display names.
  [Source: ARCHITECTURE-SPINE.md#Group-Registry, #AD-4]
- **`occ group:add --display-name` is supported on NC34** (verified) — so English IDs + Spanish display names
  in one call. `ensure_group` now takes an optional display.
- **Team placeholders are example dev seeds** — a real deployment renames/extends `prog-*`/`sector-*` per
  CESFAM (colours/numbers/names). Epic-3 folders bind to these team IDs.
- **Guard caveat:** `ensure_group` creates-with-display but (by design) does not *retro-update* the display of
  a pre-existing group — fresh seeds are correct; a group made by an older seed keeps its old display.
- Owns `phase 20-groups`; Story 2.2 (memberships) edits `phase 50-users`.

### References

- [Source: docs/planning/epics.md#Story 2.1] · [ARCHITECTURE-SPINE.md#Group-Registry, #AD-4] · [prd.md#FR-9, #FR-10]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

- `make seed` → phase 20 created `all-staff` (Todo el personal), 4 `cat-*`, 21 `role-*`, 5 team placeholders,
  each with its Spanish display name. `occ group:list` = **32** groups (21 role + 4 cat + 5 team + all-staff +
  admin). `occ group:info role-medico` → displayName "Médico General / de Familia". Re-seed → all "exists".

### Completion Notes List

- Registry provisioned verbatim from the spine (21 roles + 4 categories + all-staff + 5 example teams), Spanish
  display names via `--display-name`, idempotent by guard. `compose.yaml` untouched.

### File List

- `provisioning/phases/20-groups.sh` (filled — the registry)
- `provisioning/lib.sh` (modified — `ensure_group` takes an optional display name)

## Change Log

- 2026-07-19 — Implemented (Epic 2): filled `20-groups` with the canonical registry (21 role + 4 cat + all-staff + 5 team placeholders), Spanish display names, idempotent. Verified live (32 groups). Status → review.
