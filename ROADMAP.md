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
  swept; fresh NC34+PG18 install re-verified (PR #9). Enables the Collabora-vs-Euro-Office comparison.

- **Epic 0 — Foundation & Dev Environment (2026-07-19):** all 8 stories built and verified live on
  NC34.0.1 + PG18.4, each its own PR:
  - **0.1** portable core compose stack · **0.2** dual switchable office suite (Collabora ↔ Euro-Office,
    PR #10) · **0.3** Xdebug derived dev profile (PR #11) · **0.4** Makefile `seed`/`smoke`/`test` gate
    (PR #12) · **0.5** phase-structured idempotent provisioning framework (PR #13) · **0.6** fixtures
    mechanism + synthetic sample users (PR #14) · **0.7** repo-as-SSOT onboarding (PR #15) · **0.8**
    custom app/theme live-mounts (this PR). A dev can now clone → `make up` → debug → gate → `make seed` →
    extend, all locally and portably.

- **Epic 1 — White-label Identity & Localization (2026-07-19):** `provisioning/phases/10-branding.sh` —
  APS Conecta theming (name/slogan/URL/primary color, user-theming disabled) + es-CL locale
  (`default_language=es_419`, `default_locale=es_CL`, `default_phone_region=CL`), idempotent. Verified live on
  NC34.0.1 (PR #17). Gotcha logged: NC34 `occ theming:config` sets text/color only — logo/favicon are an
  admin-UI step.

- **Epic 2 — Roles & Access Model (2026-07-19):** `provisioning/phases/20-groups.sh` + `50-users.sh` — the
  full group registry (all-staff · 4 categories · 21 role-* from the spine · 5 team placeholders) and 4
  synthetic fixture users incl. a **multi-role** demo (`dev.medico`), all query-before-create idempotent.
  Verified live (PR #18).

- **Epic 3 — Document Home / Spine A (2026-07-19):** `provisioning/phases/30-folders.sh` + `40-acl.sh` +
  `docs/CONVENTIONS.md` — installed `groupfolders`, built the **12-folder four-area tree** (Transversal ·
  Programas · Unidades · Sectores) + the **first-cut access matrix** (allow-refinement, no DENY;
  FR-13 verified at grant level) + Spanish conventions surfaced in-folder. Verified live (PR #19). Surfaced +
  fixed 3 latent infra gaps: groupfolders never installed, custom_apps mount not www-data-writable
  (`make fix-mount-perms`), and a `mountPoint` vs `mount_point` helper bug.

- **Epic 4 — Live Collaborative Editing (2026-07-19):** the final feature epic. Editing is a **native
  capability** of the office server built in Story 0.2 — no new provisioning. Added `scripts/office-formats.sh`
  (`make office-formats`): a headless audit asserting the active backend can **edit all 6 formats** (odt/docx,
  ods/xlsx, odp/pptx — read from the server's own `/hosting/discovery`) and is **OSS with no paid license**
  (Collabora CODE "Development Edition"). Verified live: 6/6 + OSS, green. The browser-only ACs (render, live
  convergence, cursor presence, open/save fidelity) are a numbered **human acceptance runbook**,
  `docs/ACCEPTANCE-EDITING.md`, honestly opened as not-yet-run.

## Current focus

- **v1 feature-complete (Foundation + Spine A).** Epics 0–4 built and merged (Epic 4 = this PR). A dev can
  `make up` → `make seed` and get the whole white-label CESFAM intranet as config-as-code: APS Conecta
  branding + es-CL, the 21-role RBAC taxonomy with sample multi-role users, and the permissioned four-area
  document tree — plus switchable live office editing. The only remaining Epic-4 work is a **human browser
  acceptance run** (`docs/ACCEPTANCE-EDITING.md`); it can't be driven headlessly.

## Next (standard BMad Method, pure order)

1. **Human acceptance run** of `docs/ACCEPTANCE-EDITING.md` against a live backend (Collabora/Euro-Office) —
   fill its execution-record table.
2. **Epic retrospectives** (all optional) via the BMad retrospective flow.
3. Then the post-v1 production roadmap (below).

## Future

- Roadmap beyond v1 (defined by the brief/PRD): Nextcloud **Tables** → **REM app** (first Layer-2 custom
  app) → full-text **search** → **Paperless-ngx** → **Analytics** → local **AI** layer.
