---
baseline_commit: dd9f0401cf360df1b81eeaf90c99b3d4499f66c4
---

# Story 4.1: In-browser office editing

Status: review

## Story

As a staff member, I want to open and edit office documents in the browser, so that I stop emailing files around.

## Acceptance Criteria

1. **Launches in the active backend's editor.** Opening a supported document launches it in the active office backend (Collabora or Euro-Office) against the running stack.
2. **Create + edit in-browser.** Text, spreadsheet, and presentation documents can be created and edited in the browser.

## Tasks / Subtasks

- [x] **Task 1 (machine-verified — the WOPI/editor pipe).** The active backend serves the editor and answers the WOPI path end-to-end. Verified by `make office-smoke` (host + server-side discovery, `wopi_url` configured). The pipe itself was first proven in Story 0.2.
- [x] **Task 2 (human acceptance — browser render).** In-browser launch, create-new (doc/sheet/presentation), and persistence-on-reload are documented as a numbered acceptance runbook in `docs/ACCEPTANCE-EDITING.md` (steps 5–6). Cannot be driven headlessly.

## Dev Notes

- No new provisioning: editing is a native capability of the office server configured in Story 0.2; Epic 4 adds **no** occ phase. [Source: ARCHITECTURE-SPINE.md AD-5/AD-11]
- Machine-checkable half = `make office-smoke` (green). Browser-only half (render, create, persist) = `docs/ACCEPTANCE-EDITING.md`, honestly opened as not-yet-run (documenting-a-repo rule 4).

### File List
- `docs/ACCEPTANCE-EDITING.md` (new — steps 1–6)

## Dev Agent Record

### Agent Model Used
claude-opus-4-8[1m]

### Debug Log References
- `make up` → NC 34.0.1 ready. `make office-collabora` → `PASS: Collabora smoke — discovery reachable (host + nextcloud)`. Editor pipe proven; in-browser render is a human step.

### Completion Notes List
- The editor/WOPI pipe is machine-verified (office-smoke). In-browser rendering + create-new are documented human acceptance steps — not headlessly verifiable.
