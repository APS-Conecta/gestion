---
baseline_commit: dd9f0401cf360df1b81eeaf90c99b3d4499f66c4
---

# Story 4.2: Concurrent co-editing

Status: review

## Story

As a staff member, I want to co-edit a document with colleagues live, so that we work on one trusted version.

## Acceptance Criteria

1. **Convergence, no lost update.** Two user sessions editing the same document simultaneously converge with no lost update.
2. **Presence/cursors.** Co-editors see each other's presence/cursors.

## Tasks / Subtasks

- [x] **Task 1 (native capability, no build).** Concurrent co-editing + presence is provided by the office server itself (Collabora CODE / Euro-Office), which supports >20 concurrent editors — the hard requirement locked in the architecture. Nothing to implement in this repo. [Source: ARCHITECTURE-SPINE.md; PRD NFR concurrency]
- [x] **Task 2 (human acceptance — two-session convergence).** Two-session simultaneous edit (convergence + no lost update) and cursor/presence are documented as a numbered acceptance runbook in `docs/ACCEPTANCE-EDITING.md` (steps 7–9). Requires two live browser sessions; cannot be driven headlessly.

## Dev Notes

- Live convergence and presence are runtime behaviours of the document server, not config this repo sets. The only honest verification is a human running two sessions — captured in `docs/ACCEPTANCE-EDITING.md`.

### File List
- `docs/ACCEPTANCE-EDITING.md` (steps 7–9)

## Dev Agent Record

### Agent Model Used
claude-opus-4-8[1m]

### Debug Log References
- Co-editing is a native server capability; no repo change. Acceptance is the two-session browser runbook.

### Completion Notes List
- No code: convergence/presence are the office server's own behaviour. Documented as human acceptance steps (two sessions), not headlessly verifiable.
