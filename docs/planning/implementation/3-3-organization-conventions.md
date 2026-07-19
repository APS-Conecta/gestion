---
baseline_commit: 64c720b82a838ec75804118722008c63ea3f93b2
---

# Story 3.3: Organization conventions

Status: review

## Story

As a staff member, I want documented organization conventions, so that the structure stays tidy as content grows.

## Acceptance Criteria

1. **Documented in-repo + surfaced in folders (FR-14).** A naming/placement rule set + a one-live-copy versioning norm exist in `docs/CONVENTIONS.md` and are surfaced inside the `Transversal` folder (`LÉEME — Convenciones.md`).
2. **Human-followed (v1).** No automated enforcement / AI auto-sorting (roadmap, not v1).

## Tasks / Subtasks

- [x] **Task 1: `docs/CONVENTIONS.md`** — areas (where a doc belongs), file-naming pattern (`AAAA-MM-DD_area_tema_vN.ext`), and the **one-live-copy** versioning norm (edit in place, don't duplicate — the answer to "no single trusted version").
- [x] **Task 2: Surface in-folder** — `ensure_gf_file` drops a Spanish `LÉEME — Convenciones.md` into `Transversal` pointing at the repo doc (idempotent).

## Dev Notes

- **FR-14:** conventions are **human-followed** in v1; automated enforcement / AI auto-sorting is a roadmap AI-layer capability (NON-GOAL). Content is Spanish (staff-facing, NFR-4). [Source: PRD §4.4 FR-14; ARCHITECTURE-SPINE.md#Consistency-Conventions]
- One owner per fact: the full rule set lives in `docs/CONVENTIONS.md`; the in-folder note is a short pointer.

### File List
- `docs/CONVENTIONS.md` (new), `provisioning/phases/30-folders.sh` (+ in-folder note via `ensure_gf_file`), `provisioning/lib.sh` (+`ensure_gf_file`)

## Dev Agent Record

### Agent Model Used
claude-opus-4-8[1m]

### Debug Log References
- `docs/CONVENTIONS.md` written (Spanish). `make seed` → `Transversal/LÉEME — Convenciones.md` created (idempotent). `make test` green.

### Completion Notes List
- Naming/placement + one-live-copy versioning documented in-repo and surfaced in Transversal; human-followed, no auto-enforcement.

## Change Log
- 2026-07-19 — Implemented (Epic 3): `docs/CONVENTIONS.md` + in-folder Spanish note (FR-14). Status → review.
