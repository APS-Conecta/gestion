---
baseline_commit: 3bf217a06d297d45f792b64879b2432595c044e9
---

# Story 1.1: White-label branding phase

Status: review

## Story

As an administrator,
I want the instance branded as APS Conecta,
so that it presents as our suite, not stock Nextcloud — via config, not a fork.

## Acceptance Criteria

1. **Branding via `occ theming:config` (AD-6).** The `10-branding` phase sets `name`, `slogan`, `url`,
   `primary_color`, `background_color`, and `disable-user-theming yes` — config-as-code, no `defaults.php`,
   no source fork.
2. **Idempotent.** `make seed` re-runs converge (set-if-different; "already =" on re-run).
3. **Honest on image assets.** `logo`/`favicon`/`background` are **not** CLI-settable on NC34 (`occ
   theming:config` accepts only text/color keys) — documented as an admin-UI/owner step, not silently
   assumed done.

## Tasks / Subtasks

- [x] **Task 1: Fill the branding part of `phase 10-branding.sh`** (AC: 1, 2) — `theming_set` for
  name/slogan/url/primary_color/background_color/disable-user-theming.
- [x] **Task 2: Idempotent theming helper** (AC: 2) — add `theming_set` to `lib.sh` (parses the
  `"<key> is currently set to <value>"` sentence `occ theming:config <key>` returns; normalizes booleans so
  `disable-user-theming` compares `yes`≡`1`).
- [x] **Task 3: Document the NC34 image-asset limitation** (AC: 3) — logo/favicon via admin UI.
- [x] **Task 4: Verify** (AC: 1, 2) — `occ theming:config` dump shows all values; re-seed → all "already =".

## Dev Notes

- **AD-6 (branding as config):** `occ theming:config` (name/slogan/url/colors) + `disable-user-theming yes`;
  a `themes/` CSS theme only for what theming:config can't express. No `defaults.php`/opcache path. [Source: ARCHITECTURE-SPINE.md#AD-6]
- **Verified NC34 limitation:** `occ theming:config` settable keys are `name, url, imprintUrl, privacyUrl,
  slogan, color, primary_color, background_color, disable-user-theming` — **logo/favicon/background are NOT
  CLI-settable** (admin-UI uploads). AD-6 lists logo/favicon as theming:config items; on NC34 they aren't,
  so they're an owner/admin-UI step (documented in the phase + `themes/README.md`). The instance degrades
  gracefully to default marks until a real logo is uploaded.
- **`occ theming:config <key>` returns a sentence** (`"<key> is currently set to <value>"`), and
  `disable-user-theming` stores `yes` as `1` — both handled by `theming_set` (parse + boolean-normalize) so
  the set-if-different guard actually matches on re-run.
- **Provisional palette:** `primary_color=#17667a` (professional healthcare teal) pending an owner brand
  guide; `slogan="Gestión interna CESFAM"` (Spanish, user-facing). English code / Spanish UI (NFR-4).
- Owns `phase 10-branding` jointly with Story 1.2 (locale) — no other epic edits it.

### References

- [Source: docs/planning/epics.md#Story 1.1] · [ARCHITECTURE-SPINE.md#AD-6] · [prd.md#FR-7]
- [Source: docs/planning/implementation/0-5-provisioning-framework.md] — the framework/guards this fills

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

- `make seed` → phase 10 set `theming:name=APS Conecta`, `slogan=Gestión interna CESFAM`, `url`,
  `primary_color=#17667a`, `background_color=#ffffff`, `disable-user-theming=yes`. `occ theming:config` dump
  confirms all. Re-seed → all six theming keys "already =" (idempotent, including the normalized boolean).
- Discovered NC34's `occ theming:config` rejects image keys (logo/favicon) — documented as admin-UI step.

### Completion Notes List

- Branding is config-as-code (no fork, no `defaults.php`); `themes/` mount reserved for CSS the CLI can't express.
- Added the reusable `theming_set` guard (sentence-parse + boolean-normalize) to `lib.sh`.
- logo/favicon deferred to admin-UI/owner (NC34 CLI limitation) — honest, not silently skipped.

### File List

- `provisioning/phases/10-branding.sh` (filled — branding part; locale part is Story 1.2)
- `provisioning/lib.sh` (modified — +`theming_set`)

## Change Log

- 2026-07-19 — Implemented (Epic 1): branding via `occ theming:config` (+`theming_set` guard). Verified live + idempotent. logo/favicon documented as NC34 admin-UI step. Status → review.
