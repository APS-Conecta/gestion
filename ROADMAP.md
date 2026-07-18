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

## Current focus

- **BMad `architecture`** — ratify the dev-stack (NC33 + PG16 + Redis, Compose + Xdebug) and the feature
  architecture from the PRD; resolve the deferred mechanism decisions (RBAC category modeling, Collabora
  deployment shape, es-CL locale) noted in the PRD addendum.

## Next (standard BMad Method, pure order)

1. `product-brief` → `PRD` → `architecture` (ratifies the dev-stack + feature architecture).
2. `create-epics-and-stories` → **Epic 0 (Foundation & Dev Environment) first**, then feature epics.
3. `check-implementation-readiness` → `sprint-planning` → story cycle (implement **Epic 0 first**:
   Docker Compose + Xdebug + VS Code config + `Makefile` + onboarding).

## Future

- Feature epics (defined by the brief/PRD), implemented on top of the Epic-0 foundation.
