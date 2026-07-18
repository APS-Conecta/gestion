# Roadmap — APS Conecta Gestión

Status doc. Repo-first SSOT. Updated as work lands.

## Completed

- **Bootstrap (2026-07-18):** repo cloned; **BMad Method v6.10.0** installed (module `bmm`, in-repo
  artifacts under `docs/planning/`, portable config); dev-stack **boot-checked** — Nextcloud **33.0.6** +
  PostgreSQL 16 come up cleanly (`occ status: installed`). Pins validated: `nextcloud:33-apache`,
  `postgres:16-alpine`.

## Current focus

- **BMad `product-brief`** — define the suite's features and CESFAM users (nothing assumed).

## Next (standard BMad Method, pure order)

1. `product-brief` → `PRD` → `architecture` (ratifies the dev-stack + feature architecture).
2. `create-epics-and-stories` → **Epic 0 (Foundation & Dev Environment) first**, then feature epics.
3. `check-implementation-readiness` → `sprint-planning` → story cycle (implement **Epic 0 first**:
   Docker Compose + Xdebug + VS Code config + `Makefile` + onboarding).

## Future

- Feature epics (defined by the brief/PRD), implemented on top of the Epic-0 foundation.
