---
baseline_commit: e6a709f583f92cb9add523a86e540158ab85a554
---

# Story 0.7: Repo-as-SSOT onboarding

Status: review

## Story

As a developer,
I want the repository to teach its own use,
so that a new developer reaches a running instance and knows the conventions from the repo alone — no tribal knowledge.

## Acceptance Criteria

1. **README quickstart reaches a running instance.** Following the README from a clean checkout —
   clone → `cp .env.example .env` → `make up` → wait for ready → open the URL — a new developer gets a
   running Nextcloud on a fresh machine. Each step names where it runs, its expected output, and what to do
   if it fails (executed, not just asserted).

2. **Conventions + gate + "where things live" are documented.** The GitHub-Flow branching + PR review gate,
   the principles/language split, and a map of the repo (compose, Makefile, scripts, provisioning, docs) are
   documented across `README.md` / `CONTRIBUTING.md`, one owner per fact.

3. **Honest current-state.** The docs reflect what `make seed` actually provisions **today** (framework +
   fixtures) versus what is still a no-op stub pending later epics (branding, es-CL locale, roles, folders) —
   never claiming configuration that isn't applied yet.

## Tasks / Subtasks

- [x] **Task 1: Executed quickstart in `README.md`** (AC: 1)
  - [x] Rewrite the README with a numbered **Quickstart** (clone → `.env` → `make up` → wait → open URL →
    optional `make seed`), each step with where-it-runs + expected output + failure hint. Written by running
    it clean, not by reading the Makefile.
  - [x] Add a `make` targets reference (pointing to `make help` as the authoritative list) and the
    step-debug / office-switch entry points.

- [x] **Task 2: "Where things live" + current-state** (AC: 2, 3)
  - [x] Repo map (compose/dev-overlay/Makefile/scripts/provisioning/apps-themes/docs).
  - [x] A *Current state* section: framework + fixtures done; `10-branding`/`20-groups`/`30-folders`/`40-acl`
    are no-op stubs pending Epics 1–3 (so no false "es-CL/branding/roles configured" claims).

- [x] **Task 3: `CONTRIBUTING.md` — gate, conventions, doc rules** (AC: 2)
  - [x] De-stub the "local dev environment" section → link to the README quickstart (one owner per fact);
    state the touch-the-stack invariants (nothing VPS-specific; all state via `make seed`).
  - [x] Fix the stale "gate arrives with Epic 0" line (the gate shipped in Story 0.4).
  - [x] Add the seven **documentation rules** + the retired-mention guard, so future docs stay rebuildable.

- [x] **Task 4: Verify** (AC: 1, 2)
  - [x] Ran the exact new-dev path on a **fresh volume with the placeholder `.env`**: `make up` → install →
    (HTTP surface warms up after install) → `make smoke` PASS → `make seed` seeds fixtures → `make test`
    green. Captured the real outputs into the README.
  - [x] All internal doc links resolve.

## Dev Notes

**Documentation story (FR-5).** Applied the `documenting-a-repo` skill: write the runbook by **executing**
it, and ask "who writes this?" of every step.

- **FR-5 (repo-as-SSOT onboarding):** a new dev self-serves everything to run/extend/contribute from the repo.
  [Source: prd.md#FR-5; epics.md#Story 0.7]
- **Executed, not asserted (rule #4):** the quickstart was run on a clean volume with the committed
  `.env.example` placeholders — which surfaced a real onboarding gotcha (below). One owner per fact (rule #5):
  the full quickstart + `make` reference live in `README.md`; `CONTRIBUTING.md` links to them.
- **"Who writes this?" audit (rule #1):** every setup fact has an owner — NC install = the official image
  entrypoint (from `.env`); office connectors/servers = `make office-*`; Xdebug = `make up-dev`; all
  config/fixtures = `make seed`. The one "nobody sets it yet" item — **es-CL locale / branding** — is
  honestly documented as *pending* (owner = `10-branding`, Epic 1), not silently assumed.
- **Scope guards:** this is docs only — no stack/behavior change. `apps/`/`themes/` live-mounts are Story 0.8.

### Onboarding finding (from executing the runbook)

On **first boot**, `occ status` reports `installed: true` **before** the Apache/PHP HTTP surface is serving —
`curl /status.php` returned HTTP 000 (and `make smoke` failed) for ~30–60 s after install, then went green
(healthcheck log `1 1 0 0 0`). The README quickstart documents this explicitly: after `make up`, wait for
`docker compose ps` to show `(healthy)` / `make smoke` to pass before opening the browser (first boot only).
No code change needed — the healthcheck already models it (`start_period`); the gap was only in guidance.

### Project Structure Notes

- **Modified:** `README.md` (quickstart + make ref + repo map + current-state), `CONTRIBUTING.md` (gate fix,
  dev-env link, documentation rules). No code.

### References

- [Source: docs/planning/epics.md#Story 0.7] — user story + ACs
- [Source: docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md#FR-5]
- [Source: docs/planning/implementation/0-1…0-6] — the make/compose/provisioning surface documented here
- Skill: `documenting-a-repo` (execute the runbook; "who writes this?"; one owner per fact)

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

- Clean-room run (fresh volume + placeholder `.env`): `make up` → `occ status: installed`, NC 34.0.1; then
  `curl /status.php` → HTTP **000** and `make smoke` **FAIL** for ~30–60 s (HTTP surface warming up), then
  `(healthy)` + `curl` **200** + `make smoke` **PASS**. `make seed` → 4 fixtures + sample file. `make test` → green.
- Internal doc links in `README.md`/`CONTRIBUTING.md` all resolve.

### Completion Notes List

- README quickstart, make reference, repo map, and an honest *Current state* section written from real runs.
- CONTRIBUTING: fixed the stale gate line, de-stubbed the dev-env section (links to README), added the seven
  documentation rules + retired-mention guard (so the docs stay rebuildable, per the skill).
- Surfaced + documented the first-boot HTTP-readiness gotcha; no code change required.
- Docs-only; no `compose.yaml`/behavior change. Stack left as a clean placeholder install (re-seed with `make seed`).

### File List

- `README.md` (rewritten — quickstart, make ref, repo map, current state)
- `CONTRIBUTING.md` (modified — gate fix, dev-env link, documentation rules)

## Change Log

- 2026-07-19 — Implemented (dev-story, `documenting-a-repo` skill): executed-runbook README quickstart + make
  reference + repo map + honest current-state; CONTRIBUTING gate fix + documentation rules. Surfaced the
  first-boot HTTP-readiness gotcha (documented, no code change). Also flips Story 0.6 → done. Status → review.
