---
title: PRD Addendum — APS Conecta Gestión (v1)
status: final
created: 2026-07-18
updated: 2026-07-18
---

# PRD Addendum — APS Conecta Gestión (v1)

> Depth that belongs downstream (architecture, epics/stories), not in the PRD body: options considered,
> rejected-alternative rationale, and technical-how the PRD deliberately defers. The PRD stays at capability
> level; this is where the *how* and the *why-not* live until `bmad-architecture` settles them.

## Options considered — Document Home layout (§4.4)

| Option | Shape | Verdict |
|---|---|---|
| By process/knowledge area | Top-level folders per process area (Protocolos, Flujogramas, Actas, …) | Rejected as sole axis — no home for per-sector/per-unit spaces. |
| By sector / role / unit | Top-level folders per sector/unit | Rejected as sole axis — buries shared, all-staff knowledge. |
| **Hybrid → four areas** | **Transversal + Programas + Unidades + Sectores** | **Chosen.** Shared knowledge is all-staff readable; programs are Jefatura-owned; units are role-owned; sectors are the CESFAM's own territorial teams. |

Refinement during coaching: the initial hybrid (Transversal + Sectores) was reworked into **four** areas after
the owner clarified that (a) *Sectores* are the CESFAM's territorial divisions (colour/number/name — **left
open**, no specific CESFAM yet), (b) programs need Jefatura-owned folders, (c) SOME and similar are functional
**Unidades**, and (d) *Actas de reuniones* are per-program and all-readable, so they live under Transversal.

**v1 depth:** owner chose a **fuller first-cut** tree + access matrix over a thin illustrative seed — but it
remains provisional (final validated matrix + concrete program/sector names follow a specific CESFAM).

## Deferred technical-how — Foundation / Epic 0 (§4.1)

The PRD states Foundation *capabilities*; the concrete shapes below are for `bmad-architecture` to ratify and
Epic 0 stories to implement (already boot-checked: **Nextcloud 33.0.6 + PostgreSQL 16** come up clean; pins
`nextcloud:33-apache`, `postgres:16-alpine`).

- **Compose topology** — services (Nextcloud, PostgreSQL 16, Redis, Collabora), networks, volumes, healthchecks.
- **Xdebug** — derived dev-only image/config (not a fork); editor path mappings.
- **Dev ergonomics** — `Makefile` targets (`up`, `down`, `smoke`, `test`, `seed`), `.env.example`, VS Code
  launch/debug config.
- **Bind mounts** — `apps/` → `custom_apps`, `themes/` → theming, for live edit.
- **Fixtures** — deterministic synthetic seed for role groups (§4.3) and the folder tree (§4.4).

## Deferred mechanism decisions

- **RBAC category modeling (§4.3)** — flat groups vs nested groups vs group naming convention for the four
  categories. Architecture decides.
- **Collabora deployment (§4.5)** — bundled CODE (built-in CODE server app) vs a separate Collabora Online
  service. Architecture decides.
- **es-CL locale (§4.2)** — discrete es-CL vs `es`/`es_419` fallback in Nextcloud.

## License outline — components to enumerate (NFR-3)

Committed SSOT artifact to produce: license of every app/stack/dependency, confirming OSS-first and copyleft
acceptance per item. Known cores: **Nextcloud** (AGPL-3.0), **Collabora Online / CODE** (MPL-2.0), **PostgreSQL**
(PostgreSQL License), **Redis** (license varies by version — confirm the pinned image), and for the roadmap:
**Paperless-ngx** (GPL-3.0). Prefer most-permissive licenses that allow free modification; copyleft cores
accepted for self-hosting.
