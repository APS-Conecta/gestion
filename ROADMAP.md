# Roadmap — APS Conecta Gestión

Status doc. Repo-first SSOT. Updated as work lands.

## Completed

- **Bootstrap (2026-07-18):** repo cloned; **BMad Method v6.10.0** installed (module `bmm`, in-repo
  artifacts under `docs/planning/`, portable config); dev-stack **boot-checked** — Nextcloud **33.0.6** +
  PostgreSQL 16 come up cleanly (`occ status: installed`). Pins validated: `nextcloud:33-apache`,
  `postgres:16-alpine`.

- **Product brief (2026-07-18):** `docs/planning/briefs/brief-apsconecta-gestion-2026-07-18/brief.md` —
  v1 = Foundation (Epic 0) + Spine A documents; rest is roadmap. Vision, users, scope, non-goals, and
  cross-cutting pillars (GitHub SSOT · OSS-first · role-based access · es-CL/English split · Chile Legal)
  captured.

- **PRD (2026-07-18):** `docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md` (+ `addendum.md`) —
  v1 scoped **developer-facing**: Foundation (Epic 0) + the *initial* Spine A structure the 3 devs build on
  (live rollout/tutorials/validated measurement deferred to a later production version). **17 FRs** across 5
  features (Foundation · Branding/Locale · RBAC role taxonomy · Document Home 4-area hybrid tree + first-cut
  access matrix · Collabora), cross-cutting NFRs, Chile Legal, OSS license-outline. Reviewer gate: **strong**
  (0 critical/high). Roadmap items (Tables → REM → search → Paperless → Analytics → AI) deferred.

- **Architecture (2026-07-19):**
  `docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md` +
  `docs/ARCHITECTURE.md` — initiative spine, **10 ADs**. Paradigm: vanilla **NC33 + configuration-as-code**,
  no fork, zero custom PHP in v1. Resolved the deferred mechanism decisions: office = **standalone Collabora
  CODE** (>20 concurrent, whitest-label); RBAC = **Group Folders** + flat role/category/team groups (registry)
  via one **idempotent `occ` provisioning script**; locale = `es_419`/`es_CL` unlocked. Reviewer gate (lint +
  4 lenses): strong, 0 critical/high after fixes.

- **Epics & Stories (2026-07-19):** `docs/planning/epics.md` — **5 epics, 18 stories** (Given/When/Then),
  Epic 0 (Foundation) first; all 17 FRs covered. Hardened via an Advanced-Elicitation pass (phase-file
  provisioning framework so epics append not edit; Epic 4 early to de-risk WOPI). Final validation: no forward
  deps, no leftover placeholders.

## Current focus

- **BMad `check-implementation-readiness`** → `sprint-planning` → the story cycle — implement **Epic 0
  (Foundation & Dev Environment) first** (Docker Compose + Collabora/WOPI + Xdebug + Makefile + the
  phase-structured provisioning framework + onboarding).

## Next (standard BMad Method, pure order)

1. `product-brief` → `PRD` → `architecture` (ratifies the dev-stack + feature architecture).
2. `create-epics-and-stories` → **Epic 0 (Foundation & Dev Environment) first**, then feature epics.
3. `check-implementation-readiness` → `sprint-planning` → story cycle (implement **Epic 0 first**:
   Docker Compose + Xdebug + VS Code config + `Makefile` + onboarding).

## Future

- Feature epics (defined by the brief/PRD), implemented on top of the Epic-0 foundation.
