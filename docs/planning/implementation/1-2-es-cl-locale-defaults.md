---
baseline_commit: 3bf217a06d297d45f792b64879b2432595c044e9
---

# Story 1.2: es-CL locale defaults

Status: review

## Story

As a user,
I want a Spanish (es-CL) UI and Chilean formats by default,
so that the instance behaves as a Chilean system — while staying changeable (unlocked).

## Acceptance Criteria

1. **Seeded defaults (AD-7).** The `10-branding` phase sets `default_language=es_419` (the UI translation
   Nextcloud ships — a discrete `es_CL` doesn't exist) and `default_locale=es_CL` (a valid ICU locale for
   Chilean date/number formatting), plus `default_phone_region=CL`.
2. **Unlocked.** These are **defaults**, not forced — a user/dev can still change their language/locale.
3. **Idempotent.** `make seed` re-runs converge ("already =").

## Tasks / Subtasks

- [x] **Task 1: Fill the locale part of `phase 10-branding.sh`** (AC: 1, 3) — `config_system_set`
  `default_language=es_419`, `default_locale=es_CL`, `default_phone_region=CL`.
- [x] **Task 2: Verify** (AC: 1, 2, 3) — `occ config:system:get` confirms each; re-seed → "already =";
  the values are `default_*` (unlocked), never `force_language`/`force_locale`.

## Dev Notes

- **AD-7 (es-CL seeded, unlocked):** `default_language=es_419` + `default_locale=es_CL` via `occ`, **not
  forced** — users/devs may change them. UI text Spanish; code/keys English (NFR-4). [Source: ARCHITECTURE-SPINE.md#AD-7]
- **Why es_419 for language:** Nextcloud ships no discrete `es_CL` UI translation; `es_419` (Latin-American
  Spanish) is the correct shipped translation. `es_CL` is used for **locale** (ICU date/number formatting).
- **Unlocked = `default_*`, not `force_*`:** we intentionally set `default_language`/`default_locale` (a hint
  for new users) — **not** `force_language`/`force_locale` (which would lock them). AC2 requires changeability.
- **Timezone is per-user** (Nextcloud personal setting), so the phase does **not** force a global tz;
  `default_phone_region=CL` gives Chilean phone formatting.
- Shares `phase 10-branding` with Story 1.1 (branding) — the locale block; Epic 1 owns the file.

### References

- [Source: docs/planning/epics.md#Story 1.2] · [ARCHITECTURE-SPINE.md#AD-7] · [prd.md#FR-8, #NFR-4]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

- `make seed` → `system:default_language=es_419`, `default_locale=es_CL`, `default_phone_region=CL`;
  `occ config:system:get` confirms each. Re-seed → all three "already =" (idempotent). Set as `default_*`
  (unlocked), no `force_*`.

### Completion Notes List

- Chilean-Spanish defaults are seeded but **unlocked** (`default_*`, not `force_*`) — devs/users can switch.
- Timezone left per-user (AC framing); `default_phone_region=CL` added for Chilean phone formatting.

### File List

- `provisioning/phases/10-branding.sh` (filled — locale part; branding part is Story 1.1)

## Change Log

- 2026-07-19 — Implemented (Epic 1): es-CL locale defaults (`default_language=es_419`, `default_locale=es_CL`, `default_phone_region=CL`), unlocked + idempotent. Status → review.
