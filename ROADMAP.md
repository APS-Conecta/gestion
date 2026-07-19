# Roadmap — APS Conecta Gestión

Status doc. Repo-first SSOT. Updated as work lands.

## Completed

- **Bootstrap (2026-07-18):** repo cloned; **BMad Method v6.10.0** installed (module `bmm`, in-repo
  artifacts under `docs/planning/`, portable config); dev-stack **boot-checked** — Nextcloud + PostgreSQL +
  Redis come up cleanly (`occ status: installed`). *(Stack later upgraded to NC34 + PG18 — see Stack upgrade
  below.)*

- **Product brief (2026-07-18):** `docs/planning/briefs/brief-apsconecta-gestion-2026-07-18/brief.md` —
  v1 = Foundation (Epic 0) + Spine A documents; rest is roadmap. Vision, users, scope, non-goals, and
  cross-cutting pillars (GitHub SSOT · OSS-first · role-based access · es-CL/English split · Chile Legal)
  captured.

- **PRD (2026-07-18):** `docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md` (+ `addendum.md`) —
  v1 scoped **developer-facing**: Foundation (Epic 0) + the *initial* Spine A structure the 3 devs build on
  (live rollout/tutorials/validated measurement deferred to a later production version). **17 FRs** across 5
  features (Foundation · Branding/Locale · RBAC role taxonomy · Document Home 4-area hybrid tree + first-cut
  access matrix · office suite), cross-cutting NFRs, Chile Legal, OSS license-outline. Reviewer gate: **strong**
  (0 critical/high). Roadmap items (Tables → REM → search → Paperless → Analytics → AI) deferred.

- **Architecture (2026-07-19):**
  `docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md` +
  `docs/ARCHITECTURE.md` — initiative spine, **11 ADs**. Paradigm: vanilla **NC + configuration-as-code**,
  no fork, zero custom PHP in v1. Resolved the deferred mechanism decisions: office = **switchable Collabora ↔
  Euro-Office** (both >20-concurrent, standalone containers); RBAC = **Group Folders** + flat role/category/team groups (registry)
  via one **idempotent `occ` provisioning script**; locale = `es_419`/`es_CL` unlocked. Reviewer gate (lint +
  4 lenses): strong, 0 critical/high after fixes.

- **Epics & Stories (2026-07-19):** `docs/planning/epics.md` — **5 epics, 18 stories** (Given/When/Then),
  Epic 0 (Foundation) first; all 17 FRs covered. Hardened via an Advanced-Elicitation pass (phase-file
  provisioning framework so epics append not edit; Epic 4 early to de-risk WOPI). Final validation: no forward
  deps, no leftover placeholders.

- **Implementation readiness (2026-07-19):** `docs/planning/implementation-readiness-report-2026-07-19.md` —
  **READY**; 100% FR coverage (17/17), 0 critical / 0 major / 3 justified minors, UX absent by design. Cleared
  to build Epic 0.

- **Sprint plan (2026-07-19):** `docs/planning/implementation/sprint-status.yaml` — 5 epics · 18 stories · 5
  retrospectives, all `backlog`. **Planning phase complete** (brief → PRD → architecture → epics/stories →
  readiness → sprint plan).

- **Story 0.1 — Foundation compose stack (2026-07-19):** `compose.yaml` + `.env.example` + `Makefile` —
  one-command portable bring-up; implemented, reviewed (PR #7), review-findings fixed (PR #8), **done**.

- **Stack upgrade → NC34 + PG18 + dual office (2026-07-19):** re-pinned `nextcloud:34-apache` (34.0.1) +
  `postgres:18-alpine` (PG18, NC-recommended); office editing now **switchable between Collabora and
  Euro-Office** (separate standalone containers, connector-based, one active at a time — AD-5/AD-11). SSOT
  swept; fresh NC34+PG18 install re-verified. Enables the Collabora-vs-Euro-Office comparison (Euro-Office is
  NC34-only).

## Current focus

- **Build — story cycle** (`bmad-create-story` → `bmad-dev-story`), **Epic 0 first**. Story 0.1 is **done**;
  the stack is now **NC34 + PG18**. **Next: Story 0.2 — dual switchable office suite (Collabora ↔
  Euro-Office)**, then the rest of Epic 0.

## Next (standard BMad Method, pure order)

1. `product-brief` → `PRD` → `architecture` (ratifies the dev-stack + feature architecture).
2. `create-epics-and-stories` → **Epic 0 (Foundation & Dev Environment) first**, then feature epics.
3. `check-implementation-readiness` → `sprint-planning` → story cycle (implement **Epic 0 first**:
   Docker Compose + Xdebug + VS Code config + `Makefile` + onboarding).

## Future

- Feature epics (defined by the brief/PRD), implemented on top of the Epic-0 foundation.
