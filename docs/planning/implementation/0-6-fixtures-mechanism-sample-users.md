---
baseline_commit: a133b1519210a96fc4d6ed60a40590a69fcf407e
---

# Story 0.6: Fixtures mechanism + sample users

Status: review

## Story

As a developer,
I want an idempotent fixtures mechanism that seeds a small set of clearly-synthetic sample users (and a content example),
so that a fresh instance is populated for development without any real data — and so re-running `make seed` never duplicates them.

## Acceptance Criteria

1. **Synthetic sample users, idempotently.** The `50-users` phase creates a small fixed set (≈4) of **clearly synthetic** sample users via the `ensure_user` guard. `make seed` and re-runs create them **once** — no duplicates, no errors on the second run. Users are obviously fake (a `dev.` id prefix and a "(fixture)" display-name suffix).

2. **Guarded grouping (respects the structure-vs-fixtures partition).** If the `all-staff` group exists (created by Epic 2's `20-groups`), each sample user is added to it via `add_user_to_group` (idempotent). If it does not exist yet, the phase **skips grouping with a clear note** — it never creates `all-staff` itself (fixtures don't create structure, AD-2). Once Epic 2 lands, a re-seed groups them (phase 20 runs before phase 50).

3. **Content-fixture mechanism.** The `60-fixtures` phase seeds a small, clearly-synthetic content example (a welcome note in a sample user's own Files), idempotently (guarded by existence), demonstrating the content-fixture pattern. Role/folder-specific content remains deferred to Epics 2–3 (this story delivers the *mechanism*).

4. **No real data or secrets.** Fixtures are deterministic synthetic dev data only. The sample-user password is **not** hard-coded in a committed file — it comes from `.env` (`FIXTURE_USER_PASSWORD`, placeholder in `.env.example`). No real names, no secrets committed or seeded (NFR-2).

5. **No regressions.** Runs only under `make seed` (AD-2); `make up` seeds nothing. Fixtures phases stay gated by `SEED_FIXTURES` (0.5). `compose.yaml` untouched. `make seed` stays idempotent end-to-end.

## Tasks / Subtasks

- [x] **Task 1: `.env` fixtures password + seed.sh env-load** (AC: 4)
  - [x] Add `FIXTURE_USER_PASSWORD=change-me-fixture-pass` (placeholder) to `.env.example`, documented as the synthetic sample-user password (dev-only).
  - [x] In `provisioning/seed.sh`, load `.env` (host-side, `set -a; . .env; set +a`) before running phases so phase files can read `FIXTURE_USER_PASSWORD` (and any future phase config). Guard for `.env` absence.

- [x] **Task 2: Fill `provisioning/phases/50-users.sh`** (AC: 1, 2)
  - [x] A fixed list of ≈4 synthetic users (`dev.direccion`, `dev.some`, `dev.medico`, `dev.matrona`) with "(fixture)" display names. Loop: `ensure_user "$uid" "$display" "${FIXTURE_USER_PASSWORD:?…}"`.
  - [x] After creating, if `group_exists all-staff` → `add_user_to_group "$uid" all-staff`; else `log` that all-staff isn't provisioned yet (Epic 2) and skip grouping. **Never** `ensure_group all-staff` here.

- [x] **Task 3: Fill `provisioning/phases/60-fixtures.sh`** (AC: 3)
  - [x] Seed one clearly-synthetic welcome file (e.g. `Bienvenida-APS-Conecta.md`, Spanish, "archivo de ejemplo") into a sample user's Files, idempotently: guard on existence, write via the container data dir, then `occ files:scan <uid>` so Nextcloud indexes it. A small `ensure_sample_file` helper in `lib.sh` if it reads cleaner.
  - [x] Comment clearly that folder/role content is Epics 2–3.

- [x] **Task 4: Verify** (AC: 1, 2, 3, 4, 5)
  - [x] `make up`; `make seed` → sample users created, content example seeded, exit 0; **re-run** → all `ensure_user`/file guards report "exists", user count unchanged (no duplicates).
  - [x] `occ user:list` shows exactly the 4 `dev.*` fixtures (plus admin); display names carry "(fixture)".
  - [x] Grouping note: with `all-staff` absent (Epic 2 stub), the phase logs the skip; (optional) create `all-staff` throwaway, re-seed → users added, then remove it.
  - [x] Confirm no secrets committed (`FIXTURE_USER_PASSWORD` only in `.env`, not in any phase file); `SEED_FIXTURES=0 make seed` skips 50/60. `compose.yaml` untouched. Stop the stack.

## Dev Notes

**Fills the `50-users` / `60-fixtures` stubs from Story 0.5** using its `lib.sh` guard helpers — the first real phase content. No new framework; no `compose.yaml` change.

- **FR-4 (fixtures mechanism):** deterministic synthetic fixtures (users, later groups/folders/content) — no real data. This story = the mechanism + sample users; role/folder seed content lands with Epics 2–3. [Source: prd.md#FR-4; epics.md Epic-0 goal]
- **AD-2 partition:** fixtures own *only* sample content + sample users into **already-existing** groups; they never create structure. Hence the **guarded** `all-staff` grouping (add-if-exists, never create). [Source: ARCHITECTURE-SPINE.md#AD-2]
- **`all-staff` is an Epic 2 artifact** (`20-groups`, AD-4 registry — "every user"). It won't exist until Epic 2 fills phase 20; phase 50 runs after phase 20, so once Epic 2 lands a normal `make seed` groups the fixtures. Verifying now: grouping is skipped-with-note (honest), user creation is fully exercised. [Source: #AD-4; epics.md AR-4]
- **Guard reuse:** `ensure_user` (query `user:info`, then `user:add --password-from-env`), `add_user_to_group`, `group_exists`, and `log` are all in `provisioning/lib.sh` (Story 0.5). Don't reimplement.
- **Secrets (NFR-2 / rule 15):** the sample-user password is a synthetic dev value but still must not be hard-coded in committed code — read it from `.env` (`FIXTURE_USER_PASSWORD`), placeholder only in `.env.example`. `ensure_user` passes it via `OC_PASS`/`--password-from-env` (never on the command line).
- **Content seeding:** Nextcloud has no simple "put file" occ command; the accepted dev pattern is to drop the file under the user's data dir (`/var/www/html/data/<uid>/files/…`) then `occ files:scan <uid>`. Guard with `test -f` for idempotency. Keep it to one tiny Spanish example file.
- **Scope guards:** groups = Epic 2; folders/ACLs = Epic 3; branding/locale = Epic 1. Only `50-users` / `60-fixtures` (+ `.env.example`, `seed.sh` env-load) here.

### Project Structure Notes

- **Modified:** `provisioning/phases/50-users.sh`, `provisioning/phases/60-fixtures.sh` (fill stubs); `provisioning/seed.sh` (load `.env` for phases); `.env.example` (+`FIXTURE_USER_PASSWORD`); optionally `provisioning/lib.sh` (+`ensure_sample_file`). No new top-level files.

### References

- [Source: docs/planning/epics.md#Story 0.6] — user story + ACs (idempotent synthetic users; mechanism only)
- [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-2, #AD-4]
- [Source: docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md#FR-4, #NFR-2]
- [Source: docs/planning/implementation/0-5-provisioning-framework.md] — the framework + guard helpers this fills

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

Verified live on the NC34.0.1 + PG18.4 stack:

- `make seed` → phase 50 creates `dev.direccion` / `dev.some` / `dev.medico` / `dev.matrona`; phase 60 seeds `Bienvenida-APS-Conecta.md` into `dev.direccion`'s Files ("created + indexed"). `occ user:list` = `admin` + the 4 `dev.*` fixtures, display names carry "(fixture)".
- **Idempotent re-run** → every user reports "exists", the file reports "exists"; no duplicates (AC1).
- **Guarded grouping** (AC2): with `all-staff` absent (Epic 2 stub) the phase logs "skipping grouping" and never creates the group; after `occ group:add all-staff` + re-seed, `occ user:info dev.direccion` → `groups: ['all-staff']` (authoritative — `group:info` JSON carries no `users` field, so member membership is read from the user side).
- `SEED_FIXTURES=0 make seed` → skips 50/60 (4 run, 2 skipped). No password literal in `provisioning/` (only the `FIXTURE_USER_PASSWORD` reference). `compose.yaml` untouched; `make test` green.

**Bug found & fixed (latent in Story 0.5's `lib.sh`, first exercised here):** `ensure_user` set `OC_PASS` on the **host**, but `occ` runs via `docker compose exec`, which does **not** forward host env — so `--password-from-env` saw nothing and `user:add` silently failed (no users created). Fixed `ensure_user` to pass `-e OC_PASS="$pass"` into the container (never on the command line). This is exactly the kind of latent guard-helper bug the fixtures story surfaces.

### Completion Notes List

- Sample users are unmistakably synthetic — `dev.` id prefix + "(fixture)" display suffix (AC1/AC4).
- **Structure-vs-fixtures partition kept (AD-2):** `50-users` adds to `all-staff` only if it already exists; it never creates the group. Once Epic 2 fills `20-groups` (which runs before `50` in seed order), a normal `make seed` groups the fixtures.
- **No secret in git:** `FIXTURE_USER_PASSWORD` is placeholder-only in `.env.example`; `seed.sh` loads `.env` host-side so phases can read it; `ensure_user` forwards it via `-e OC_PASS`. No password on any command line or in any committed file.
- **Content mechanism:** `ensure_sample_file` (new in `lib.sh`) writes into the user's data dir then `occ files:scan`s it — the accepted dev pattern (Nextcloud has no simple "put file" occ command), guarded by `test -f` for idempotency. Folder/role content stays deferred to Epics 2–3.
- No `compose.yaml` change; `make up` seeds nothing. Stack stopped after verification.

### File List

- `provisioning/phases/50-users.sh` (filled — synthetic sample users + guarded all-staff grouping)
- `provisioning/phases/60-fixtures.sh` (filled — synthetic welcome-file content example)
- `provisioning/lib.sh` (modified — fixed `ensure_user` OC_PASS forwarding; added `ensure_sample_file`)
- `provisioning/seed.sh` (modified — load `.env` so phases can read config)
- `.env.example` (modified — +`FIXTURE_USER_PASSWORD` placeholder)

## Change Log

- 2026-07-19 — Story drafted (create-story): fill `50-users` (synthetic sample users, idempotent, guarded `all-staff` grouping) + `60-fixtures` (content mechanism); `FIXTURE_USER_PASSWORD` via `.env`; `seed.sh` loads `.env`. Mechanism only — role/folder content is Epics 2–3. Status → ready-for-dev.
- 2026-07-19 — Implemented (dev-story): filled 50-users/60-fixtures; added `ensure_sample_file`; `.env`-load in seed.sh; `FIXTURE_USER_PASSWORD`. **Fixed a latent `ensure_user` bug** (OC_PASS not forwarded into the container). Verified live: 4 synthetic users + welcome file, idempotent re-run, guarded grouping (proven via user:info), no secrets committed. Also flips Story 0.5 → done. Status → review.
