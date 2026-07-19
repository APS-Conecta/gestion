---
baseline_commit: dd9f0401cf360df1b81eeaf90c99b3d4499f66c4
---

# Story 4.3: OSS format support

Status: review

## Story

As a staff member, I want the common office formats supported without a paid license, so that our existing files work.

## Acceptance Criteria

1. **Six formats open + save in-browser.** odt/docx, ods/xlsx, and odp/pptx open and save in the browser.
2. **OSS + self-hosted, no paid license.** The editing stack, when audited, is OSS and self-hosted with no paid license.

## Tasks / Subtasks

- [x] **Task 1 (machine-verified — format coverage + license).** `scripts/office-formats.sh` (`make office-formats`) asserts, for the active backend, that all six formats carry an `edit` action — read from the backend's OWN generated `/hosting/discovery`, not a hand-maintained table (documenting-a-repo: generated > written) — and that the build is OSS with no paid license (Collabora reports `productName: "…Development Edition"`; the image is the AGPL `collabora/code`).
- [x] **Task 2 (Makefile wiring).** `make office-formats` target added; auto-detects the active backend (same detection as `office-smoke`, DRY). For Euro-Office (no WOPI discovery to parse) it asserts server-health + OSS image and defers per-format fidelity to the runbook.
- [x] **Task 3 (human acceptance — fidelity).** Open/save fidelity per format is documented in `docs/ACCEPTANCE-EDITING.md` (step 10). The *set* of editable formats + the no-license posture are machine-verified; fidelity is the human half.

## Dev Notes

- The authoritative format list is the server's generated discovery XML — parsing it means the check can't drift from what the server actually serves. Verified live: 6/6 formats editable + `Collabora Online Development Edition` on `collabora/code:latest`.
- Both office suites are AGPL/self-hosted with no license key (AD-5/AD-11; OSS-first mandate). [Source: ARCHITECTURE-SPINE.md; PRD FR office/OSS]

### File List
- `scripts/office-formats.sh` (new), `Makefile` (+`office-formats` target + `.PHONY`), `docs/ACCEPTANCE-EDITING.md` (step 10)

## Dev Agent Record

### Agent Model Used
claude-opus-4-8[1m]

### Debug Log References
- `make office-formats` live → `✓ odt/docx/ods/xlsx/odp/pptx editable` + `✓ OSS build: Collabora Online Development Edition` → `PASS: Collabora — 6/6 formats editable + OSS build, no paid licence`. `make test` green.

### Completion Notes List
- Format coverage + OSS/no-license are machine-verified and green (new `make office-formats` gate). Open/save fidelity per format is the documented human acceptance step.
