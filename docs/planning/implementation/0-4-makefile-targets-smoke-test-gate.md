---
baseline_commit: 556c7adbeb4e62bbd35d142e5905293272848395
---

# Story 0.4: Makefile targets + smoke/test gate

Status: review

## Story

As a developer,
I want `make` targets for the full lifecycle and a one-command smoke/test gate,
so that the local quality gate — the project's CI stand-in — is a single command that passes on a healthy stack and fails on a broken one.

## Acceptance Criteria

1. **Lifecycle targets exist and are documented.** The Makefile exposes `up`, `down`, `seed`, `smoke`, `test` (alongside the existing `up-dev` / `office-*`), each with a `##` help line shown by `make help`. `up` starts **services only** (no seeding — AD-2); `seed` runs the provisioning pipeline (its content lands in Story 0.5 — `seed` is the stable interface to it and reports clearly if the pipeline isn't present yet).

2. **`make smoke` is a health gate.** Against a **healthy** running stack it exits **0**; against a **broken/absent** stack (a core service down, Nextcloud not installed, or not reachable) it exits **non-zero** with a clear failing line. It checks the core invariants: `occ status: installed`, PostgreSQL reachable, Redis responding, and `GET /status.php` → 200.

3. **`make test` is the local gate.** It runs the **static** checks that need no running stack — compose config validity (base + dev overlay + office profiles), shell scripts parse (`bash -n`), Xdebug ini present — and then the smoke check when a stack is up. It exits non-zero if any check fails. This is the gate a contributor runs before a PR (CI is deferred per `CONTRIBUTING.md`).

4. **No regressions.** `up`/`down`/`up-dev`/`office-*` behavior is unchanged; the core `up` still starts only `db`/`redis`/`nextcloud`. New shell lives under `scripts/`, consistent with `scripts/office-smoke.sh`.

## Tasks / Subtasks

- [x] **Task 1: `scripts/smoke.sh` — core-stack health gate** (AC: 2)
  - [x] Assert, exiting non-zero with a labeled FAIL on the first failure: (a) the `nextcloud` container is running; (b) `occ status` → `installed:true`; (c) `pg_isready` in the `db` container (or `occ` DB check) OK; (d) `redis-cli ping` → PONG; (e) `curl -sf http://localhost:${HTTP_PORT}/status.php` → 200. Print a PASS summary on success.
  - [x] Read `HTTP_PORT` from `.env` (default 8180); mirror the style of `scripts/office-smoke.sh`.

- [x] **Task 2: `scripts/test.sh` — static + smoke gate** (AC: 3)
  - [x] Static (no stack needed): `docker compose -f compose.yaml config -q`; `docker compose -f compose.yaml -f compose.dev.yaml config -q`; `docker compose --profile collabora --profile eurooffice config -q`; `bash -n` every `scripts/*.sh`; assert `dev/xdebug.ini` exists.
  - [x] If a stack is running, also run `scripts/smoke.sh`; if not, note it's skipped (static-only) and still exit 0 for the static gate.
  - [x] Exit non-zero on any failure, with a labeled FAIL.

- [x] **Task 3: Makefile targets** (AC: 1, 4)
  - [x] `smoke`: `HTTP_PORT=$(HTTP_PORT) bash scripts/smoke.sh`.
  - [x] `test`: `bash scripts/test.sh`.
  - [x] `seed`: run the provisioning entrypoint if present (`[ -x provisioning/seed.sh ] && provisioning/seed.sh || echo "provisioning pipeline arrives in Story 0.5"`), documented as the AD-2 provisioning entry (separate from `up`).
  - [x] Add `HTTP_PORT` to the Makefile's `.env`-sourced vars (like `OFFICE_PORT`). Update `.PHONY` and ensure `make help` lists all.

- [x] **Task 4: Verify** (AC: 2, 3, 4)
  - [x] `make up` → `make smoke` exits **0**; `make test` passes.
  - [x] Break it (e.g. `docker compose stop redis` or full `down`) → `make smoke` exits **non-zero** with a clear FAIL line.
  - [x] `make test` static checks pass with the stack down (compose/scripts validation).
  - [x] `make help` shows `up`, `up-dev`, `down`, `seed`, `smoke`, `test`, `office-*`. Stop the stack after.

## Dev Notes

**Extends Story 0.1/0.2/0.3** (`Makefile`, `scripts/`). New shell under `scripts/`, same idioms as `scripts/office-smoke.sh` (read `.env`, labeled FAIL, exit non-zero, `set -euo pipefail`).

- **AD-2 (provisioning boundary):** `up` starts services only; `seed` is the **separate** provisioning entry. This story delivers `seed` as the stable interface; the phase-file provisioning content is Story 0.5. `smoke`/`test` must **not** perform provisioning. [Source: ARCHITECTURE-SPINE.md#AD-2; epics.md Conventions]
- **The gate is local, by design.** No CI pipeline story up front — the quality gate is `make smoke` / `make test`, run by a contributor before a PR (readiness M3; `CONTRIBUTING.md`). [Source: implementation-readiness-report-2026-07-19.md#M3]
- **`occ` invocation:** `docker compose exec -T --user www-data nextcloud php occ <cmd>` (as elsewhere). For a down stack, `exec` fails — the smoke must detect "container not running" and FAIL cleanly, not hang.
- **Distinct from `office-smoke`:** `scripts/smoke.sh` checks the **core** stack (db/redis/nextcloud); `scripts/office-smoke.sh` (Story 0.2) checks the **active office backend**. `test` may call `smoke` but not `office-smoke` (office is a profile, not always up).
- **Scope guards:** provisioning content = Story 0.5; fixtures = 0.6; `apps/`+`themes/` = 0.8. Only the Makefile + `scripts/` are touched here.

### Project Structure Notes

- **New:** `scripts/smoke.sh`, `scripts/test.sh`. **Modified:** `Makefile` (+`smoke`, +`test`, +`seed`; +`HTTP_PORT` var). Matches ARCHITECTURE-SPINE.md#Structural Seed.

### References

- [Source: docs/planning/epics.md#Story 0.4] — user story + ACs
- [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-2]
- [Source: docs/planning/implementation-readiness-report-2026-07-19.md#M3] — local gate, CI deferred
- [Source: docs/planning/implementation/0-1-portable-core-compose-stack.md, 0-2-…, 0-3-…] — Makefile/scripts patterns extended
- [Source: CONTRIBUTING.md] — convention gate, local quality gate

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

Verified live on the NC34.0.1 + PG18.4 stack:

- `make help` → lists `up`, `up-dev`, `down`, `seed`, `smoke`, `test`, `office-*` (all `##`-documented).
- `make test` (stack **down**) → static gate green: base + dev overlay + office-profiles `config -q` all ok, `bash -n` on all `scripts/*.sh` ok, `dev/xdebug.ini` present; smoke **skipped** (no running stack); exit **0**.
- `make up` → `make smoke` → `PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200`; exit **0**.
- `make test` (stack **up**) → static gate + smoke both green; exit **0**.
- **Broken-stack check:** `docker compose stop redis` → `make smoke` → `FAIL: Redis is not responding to PING`; exit **2** (non-zero, labeled). Confirms AC2 both directions.
- `make seed` (services up) → `Provisioning pipeline arrives in Story 0.5 …` (stable interface, no provisioning performed — AD-2).

### Completion Notes List

- `scripts/smoke.sh` = **core-stack** health (container running → `occ installed` → `pg_isready` → Redis PONG → `/status.php` 200), first-failure exit with a labeled `FAIL:`. Distinct from `scripts/office-smoke.sh` (office backend).
- `scripts/test.sh` = the **local gate**: aggregates static checks (compose validity across all overlays/profiles, `bash -n`, xdebug ini) — no `set -e`, so it runs every check and reports all failures — then runs smoke only if a stack is up. This is the CI stand-in (CI deferred per `CONTRIBUTING.md`).
- `seed` is the **interface** to the Story 0.5 provisioning pipeline (runs `provisioning/seed.sh` when present, else a clear message) — keeps AD-2's up-vs-seed split.
- No regressions: `compose.yaml` untouched (only `Makefile` + new `scripts/` files); `up`/`up-dev`/`down`/`office-*` unchanged. Stack stopped after verification.

### File List

- `scripts/smoke.sh` (new — core-stack health gate)
- `scripts/test.sh` (new — static + smoke local gate)
- `Makefile` (modified — +`seed`, +`smoke`, +`test`; +`HTTP_PORT` var)

## Change Log

- 2026-07-19 — Story drafted (create-story): Makefile `seed`/`smoke`/`test` gate + `scripts/smoke.sh` + `scripts/test.sh`. `smoke` = core-stack health (0 healthy / non-0 broken); `test` = static + smoke; `seed` = interface to Story 0.5. Status → ready-for-dev.
- 2026-07-19 — Implemented (dev-story): `scripts/smoke.sh` + `scripts/test.sh` + Makefile `seed`/`smoke`/`test` (+`HTTP_PORT`). Verified live: `smoke` exits 0 healthy / 2 with Redis down; `test` green static (stack down) and with smoke (stack up); `seed` stubs to Story 0.5; `compose.yaml` untouched. Also flips Story 0.3 → done. Status → review.
