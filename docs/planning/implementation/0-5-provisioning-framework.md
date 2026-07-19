---
baseline_commit: 843add14800dcbf3182812b08b974b4aa6e663d5
---

# Story 0.5: Provisioning framework

Status: review

## Story

As a developer,
I want a phase-structured, idempotent provisioning framework under `provisioning/`,
so that later epics **append their own phase file** (never editing a monolith) and every `make seed` converges to the same desired state.

## Acceptance Criteria

1. **Phase-file layout + guard helpers.** `provisioning/` holds a `seed.sh` runner, a `lib.sh` of shared **idempotency-guard helpers** (query-before-create), and `provisioning/phases/` with the six numbered phase files as **no-op stubs**: `10-branding.sh`, `20-groups.sh`, `30-folders.sh`, `40-acl.sh`, `50-users.sh`, `60-fixtures.sh`. Each stub is owned by exactly one later epic (10=Epic 1; 20=Epic 2; 30/40=Epic 3; 50/60=Story 0.6) and, until filled, logs its phase and does nothing.

2. **Idempotent, fixed-order runner.** `make seed` (→ `provisioning/seed.sh`) requires an installed stack, then executes the phase files in the fixed numeric order **10 → 20 → 30 → 40 → 50 → 60**. Running it **twice** converges with no errors and no duplicates (idempotent by guard). It fails clearly if the stack isn't up.

3. **Guard helpers are query-before-create.** `lib.sh` provides reusable primitives that never blind-create: `ensure_group` (via `occ group:list`), `ensure_user`, `add_user_to_group`, `ensure_groupfolder` (via `occ groupfolders:list` — `groupfolders:create` is **not** idempotent by name), and `config_system_set` / `config_app_set` (set-only-if-different). Re-invoking any of them on existing state is a no-op/patch, not a duplicate.

4. **Structure-vs-fixtures partition (AD-2).** Phases **10–40** own *structure* (branding/locale, groups, folders, ACLs); phases **50–60** own *fixtures* (sample users into already-existing groups, sample content). The runner gates the fixtures phases (≥50) behind `SEED_FIXTURES` (default on in dev) so production could seed structure without synthetic data. One owner per artifact.

5. **`make up` still seeds nothing (AD-2).** The framework is invoked **only** by `make seed`; `make up` remains services-only. `compose.yaml` is untouched. `make seed` on a not-up stack exits non-zero with a clear message.

## Tasks / Subtasks

- [x] **Task 1: `provisioning/lib.sh` — idempotency-guard helpers** (AC: 1, 3)
  - [x] `occ()` wrapper (`docker compose exec -T --user www-data nextcloud php occ …`); logging helpers `phase_begin`/`phase_end`/`log`; `require_installed` (fails clearly if `occ status` ≠ installed).
  - [x] `config_system_set KEY VALUE` and `config_app_set APP KEY VALUE` — read current, set only if different.
  - [x] `group_exists`/`ensure_group` (query `occ group:list`); `user_exists`/`ensure_user` (via `user:info` / `user:add --password-from-env`); `add_user_to_group`.
  - [x] `groupfolder_id MOUNT` / `ensure_groupfolder MOUNT` (query `occ groupfolders:list` — parse JSON with `python3`; **never** blind `groupfolders:create`). Returns/records the folder id.
  - [x] `set -uo pipefail`-safe; each helper documented so an epic author can call it without reading the body.

- [x] **Task 2: `provisioning/phases/` — six no-op stubs** (AC: 1, 4)
  - [x] `10-branding.sh`, `20-groups.sh`, `30-folders.sh`, `40-acl.sh`, `50-users.sh`, `60-fixtures.sh`. Each: `phase_begin "<nn-name>" "<desc> (Epic X)"`, a `# TODO(Epic X)` no-op body, `phase_end`. Header comment names the owning epic and the ownership rule ("only Epic X edits this file").

- [x] **Task 3: `provisioning/seed.sh` — the runner** (AC: 2, 4, 5)
  - [x] Source `lib.sh`; `require_installed`; record an idempotent framework marker (`config_app_set provisioning framework_version 1`) to demonstrate the guard.
  - [x] Discover `provisioning/phases/[0-9]*.sh`, sort **numerically**, and `source` each in order. Skip phases numbered **≥ 50** when `SEED_FIXTURES=0` (default `1`).
  - [x] Stop on first error (`set -e` around the phase loop) with the failing phase named; print a run summary. Resolve paths relative to the script dir so it runs from any CWD.

- [x] **Task 4: `provisioning/README.md` — conventions** (AC: 1, 4)
  - [x] Document: the phase-order contract (10→60), the **one-epic-per-file** ownership map, the idempotency contract (query-before-create; list the helpers), the structure-vs-fixtures partition + `SEED_FIXTURES`, and a worked "how to fill a stub" example.

- [x] **Task 5: Verify** (AC: 2, 3, 5)
  - [x] `make up`; `make seed` → runs 10→60 in order, exit 0; **run again** → idempotent (marker "already", stubs no-op), exit 0.
  - [x] Guard proof (throwaway, leaves no residue): `ensure_group` a temp id twice → created then "exists", no error/dup; then remove it. `config_app_set` the marker twice → set then "already".
  - [x] `make seed` with the stack **down** → non-zero + clear message. `make up` seeds nothing (only `make seed` does). `SEED_FIXTURES=0 make seed` skips 50/60.
  - [x] Stop the stack after.

## Dev Notes

**Extends Story 0.4** (`make seed` already calls `provisioning/seed.sh`). This story fills in that pipeline. Reuse the `scripts/*.sh` idioms (`.env`-aware, labeled failures). No `compose.yaml` change.

- **AD-2 (single idempotent writer):** all desired state comes from the one `provisioning/` `occ` script; every step **idempotent by guard** (query-before-create — `occ group:list`, `groupfolders:list`, recorded folder-id map; skip/patch if present; never blind-create). Fixed phase order **branding/locale → groups → group folders → ACLs → membership → fixtures**. **Ownership partition:** provisioning owns *structure*; fixtures own *only* sample content + sample users into existing groups. [Source: ARCHITECTURE-SPINE.md#AD-2; epics.md AR-2]
- **`groupfolders:create` is NOT idempotent by name** — re-running creates a duplicate mount. `ensure_groupfolder` MUST query `groupfolders:list` first and reuse the id. This is the single most important guard for Epic 3. [Source: #AD-2]
- **No-op stubs, one owner each:** Epic 1 fills `10-branding` (`occ theming:config` + es-CL); Epic 2 fills `20-groups` (the 21 `role-*` + `cat-*` + `all-staff` + `prog-*`/`sector-*` registry); Epic 3 fills `30-folders` + `40-acl`; Story 0.6 fills `50-users` + `60-fixtures` (sample users into `all-staff`). Because each epic touches only its own file, parallel epics don't conflict. [Source: epics.md Sequencing + Epic-0 goal]
- **`make up` seeds nothing (AD-2):** provisioning is invoked only by `make seed`. Keep it that way. [Source: #AD-2; epics.md Conventions]
- **JSON parsing:** the host has `python3` (no `jq` assumed) — use it for `groupfolders:list`/`group:list` JSON where exact matching matters. `occ` invocation is `docker compose exec -T --user www-data nextcloud php occ …`.
- **Scope guards:** this is the FRAMEWORK only — the phase bodies are no-ops. Real branding/groups/folders/ACLs/users are Epics 1/2/3 and Story 0.6. Do not implement phase content here.

### Project Structure Notes

- **New:** `provisioning/seed.sh`, `provisioning/lib.sh`, `provisioning/phases/{10-branding,20-groups,30-folders,40-acl,50-users,60-fixtures}.sh`, `provisioning/README.md`. **Modified:** none required (`make seed` from Story 0.4 already targets `provisioning/seed.sh`; confirm it's executable). Matches ARCHITECTURE-SPINE.md#Structural Seed (`provisioning/` numbered phases).

### References

- [Source: docs/planning/epics.md#Story 0.5] — user story + ACs (no-op stubs + guard helpers; idempotent order 10→60)
- [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-2, #AD-4, #Group Registry]
- [Source: docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md#FR-4] deterministic synthetic fixtures mechanism
- [Source: docs/planning/implementation/0-4-makefile-targets-smoke-test-gate.md] `make seed` interface this fills

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

Verified live on the NC34.0.1 + PG18.4 stack:

- `make seed` → framework marker `app:provisioning:framework_version -> 1`, then phases **10→20→30→40→50→60** in order, "6 phase(s) run, 0 skipped", exit **0**.
- `make seed` **again** → marker `already = 1`, all six stubs no-op, exit **0** — idempotent (AC2).
- **Guard proof** (`ensure_group`, throwaway): first call `group zzz-guard-test created`, second `… exists`; group count = **1** (no duplicate); removed after — no residue (AC3).
- `SEED_FIXTURES=0 make seed` → `▷ skipping 50-users.sh` + `▷ skipping 60-fixtures.sh`, "4 phase(s) run, 2 skipped" (structure-vs-fixtures partition, AC4).
- `make seed` with the stack **down** → `FATAL: Nextcloud is not installed/reachable — run 'make up' first.`, exit **2** (AC5).
- `make test` still green with the provisioning shell now in the gate; `compose.yaml` untouched (AC5).

### Completion Notes List

- The framework is the **single writer** (AD-2): `seed.sh` sources `phases/[0-9]*.sh` numerically, each in a `set -e` **subshell** for fault isolation — a failing phase stops the run (named) and no phase can leak shell state into the next (cross-phase state goes through Nextcloud, re-queried by the guard helpers, never via shell vars).
- `lib.sh` guard helpers are all **query-before-create**: `ensure_group`/`ensure_user`/`add_user_to_group`, `ensure_groupfolder` (queries `groupfolders:list` — `groupfolders:create` is **not** idempotent by name), and `config_system_set`/`config_app_set` (set-if-different). JSON parsed with `python3` (no `jq` assumed).
- The six phase files are **no-op stubs**, one owner each (10=Epic 1 · 20=Epic 2 · 30/40=Epic 3 · 50/60=Story 0.6). An epic fills only its own file → parallel epics never conflict. `provisioning/README.md` documents the contract + a worked "fill a stub" example.
- Extended `scripts/test.sh` to `bash -n` the provisioning shell too, so the gate covers it.
- No `compose.yaml` change; `make up` still seeds nothing. Stack stopped after verification.

### File List

- `provisioning/seed.sh` (new — idempotent runner)
- `provisioning/lib.sh` (new — query-before-create guard helpers)
- `provisioning/phases/10-branding.sh`, `20-groups.sh`, `30-folders.sh`, `40-acl.sh`, `50-users.sh`, `60-fixtures.sh` (new — no-op stubs)
- `provisioning/README.md` (new — conventions)
- `scripts/test.sh` (modified — gate now lints provisioning shell)

## Change Log

- 2026-07-19 — Story drafted (create-story): phase-structured idempotent provisioning framework (`seed.sh` runner + `lib.sh` guard helpers + `phases/10-60` no-op stubs + README), fixed order 10→60, structure-vs-fixtures partition (AD-2). Status → ready-for-dev.
- 2026-07-19 — Implemented (dev-story): `provisioning/` framework (runner + guard helpers + six no-op phase stubs + README); `test` gate extended to lint provisioning shell. Verified live: `make seed` runs 10→60 idempotently (twice, exit 0), guard helpers query-before-create, `SEED_FIXTURES=0` skips fixtures, down-stack fails clean, `compose.yaml` untouched. Also flips Story 0.4 → done. Status → review.
