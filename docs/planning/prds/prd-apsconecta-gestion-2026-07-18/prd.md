---
title: APS Conecta Gestión — PRD (v1)
status: final
created: 2026-07-18
updated: 2026-07-18
---

# PRD: APS Conecta — Gestión (v1)
*Working title — confirm.*

## 0. Document Purpose

This PRD is the **HOW** for **v1** of *APS Conecta Gestión*, derived from the product brief
(`docs/planning/briefs/brief-apsconecta-gestion-2026-07-18/brief.md`, the **WHAT**). Its primary readers are
the **three developers** building the suite and the downstream BMad workflows that consume it —
`bmad-architecture` (which ratifies the stack and design), then `bmad-create-epics-and-stories`
(Epic 0 first). It is structured Glossary-first: domain terms are defined once in §3 and used verbatim
everywhere; capabilities are grouped as Features (§4) with globally-numbered **Functional Requirements**
(`FR-N`) nested under them; inferred decisions are tagged inline as `[ASSUMPTION]` and collected in the Assumptions Index (§14).
Technical *how* (Compose service topology, image pins, Xdebug, Makefile/VS Code wiring, license-outline
mechanics) lives in the companion `addendum.md` and is settled by `bmad-architecture` — this PRD stays at the
level of capabilities.

**v1 is developer-facing.** It is *not* the live CESFAM staff pilot. v1 delivers the **Foundation** (Epic 0)
and the **initial Spine A document structure** — a running, white-label Nextcloud the three developers stand
up, run, debug, test, and iteratively improve. The live staff rollout, end-user tutorials, and validated
adoption/wellbeing measurement are a **later production version** (see §5, §6, §7).

## 1. Vision

*APS Conecta Gestión* is the secure, centralized intranet a Chilean CESFAM's clinical and management staff
will eventually run their processes on — replacing the broken chain of Excel, Word and PowerPoint files
scattered across WhatsApp, email, pendrives and Google Drive — where there is **no single trusted version** and
**data is quietly lost** — with one permissioned, live-collaborative home. The **core bet** is turning that
scattered content into a **structured, searchable database** the CESFAM can analyze and use to run its
processes: the data itself is the value, with a later AI layer as assist *on top*, not the source of it. It is
built **white-label on Nextcloud 33** (official image, never a source fork), self-hosted and OSS-first, and it
deliberately is **not** an HR, finance, or shift/absence system: it is process- and knowledge-management for
staff working on their own data.

**v1 delivers the foundation that makes all of that buildable.** It is a running, white-label Nextcloud 33 +
PostgreSQL + Redis stack that any of the three developers can bring up locally with one command, debug and
test, plus the **initial Spine A structure**: a role-based access model over an organized, permissioned
folder tree with live collaborative editing (Collabora / Nextcloud Office) working end to end. v1 is the
scaffold the team improves on — correct in its bones (branding, locale, roles, permissions, editing), and
deliberately thin everywhere the real answer depends on watching real staff use it.

Everything past v1 — Nextcloud Tables, the REM custom app, full-text search, Paperless-ngx and Analytics (the
structured-data stack that delivers the analytic payoff), and *on top of that* a local-model **AI layer** that
auto-organizes documents, flags expiring protocols and finds cross-reference errors — is roadmap, built one
capability at a time on top of this foundation. The vision is a CESFAM whose
knowledge and processes live in one secure, structured, searchable place; v1 lays the first, load-bearing
stone.

## 2. Target User

### 2.1 Jobs To Be Done

**Primary — the three developers (v1's actual users):**

- *As a developer, I can clone the repo and bring the whole suite up locally with one command*, so I can start
  working without hand-assembling services or per-machine setup.
- *As a developer, I can debug the running Nextcloud (step through PHP) and run a smoke/test check*, so I can
  build and verify custom apps and configuration with a real feedback loop.
- *As a developer, I can read the repo and know how to run, extend, and contribute*, so onboarding a new dev is
  self-service and the repo is the single source of truth for how the project is built.
- *As a developer, I can configure the initial white-label branding, role groups, and permissioned folder
  structure*, so there is a correct, shared baseline to iterate on rather than each dev improvising.
- *As the team, we are building this for a real CESFAM's roles* — so the initial structure must be shaped
  around the actual staff roles and their access boundaries, even though no staff use v1 yet.

**Eventual — CESFAM staff (whom the structure is built *for*, served in a later production version):** staff
across differentiated roles who need one secure, permissioned place to keep and co-edit protocolos, actas and
documentación instead of WhatsApp, pendrives and Google Drive.

### 2.2 Non-Users (v1)

- **Live CESFAM staff.** v1 is not deployed to real users; the live pilot and adoption are a later production
  version. Staff roles inform the *structure* v1 builds, but no staff account is a v1 user.
- **Patients / clinical users.** Never in scope — this is internal ops with **no patient/clinical data**; dev
  uses synthetic fixtures only.
- **HR, finance, and operations staff** acting in those capacities — turnos, ausencias, remuneraciones and
  RRHH are explicit non-goals (§5), so those users are out of scope entirely, not just deferred.

*(User Journeys are intentionally omitted from this PRD. v1's users are the developers; the end-user tutorial
and staff journeys are a production-version deliverable.)*

## 3. Glossary

*Downstream workflows and readers use these terms exactly. FRs and SMs use Glossary terms verbatim; a synonym
introduced elsewhere is a discipline violation.*

- **APS Conecta** — the umbrella **brand/project**. The white-label suite carries this brand; future sibling
  apps may live under it.
- **APS Conecta Gestión** — **this app**: the management/intranet application. "The suite" and "the product"
  refer to it.
- **CESFAM** — *Centro de Salud Familiar*, a Chilean primary-healthcare centre. The eventual deploy target is
  one real CESFAM.
- **Nextcloud (Hub)** — the OSS self-hosted collaboration platform the suite is built on, pinned to
  **Nextcloud 33** (`33-apache`), used **white-label** via the official image — **never a source fork**.
- **Collabora / Nextcloud Office** — the integrated office suite providing **live collaborative editing** of
  documents inside Nextcloud.
- **White-label** — Nextcloud re-branded as *APS Conecta* (name, logo, theme, locale) via supported theming,
  with no fork of Nextcloud source.
- **Foundation (Epic 0)** — the first deliverable and first definition of success: the repo + Nextcloud 33
  stack + local dev/debug environment where the three developers read, build, run, debug and test the suite.
- **Spine A** — the **documents** track of v1: vanilla Nextcloud + Collabora live editing + role-based access +
  an organized, permissioned folder/group structure. v1's feature scope is Foundation + Spine A only.
- **Layer 1 / Layer 2 / Layer 3** — Layer 1 = native Nextcloud apps configured/white-labeled; Layer 2 = custom
  CESFAM apps (e.g. the future REM app); Layer 3 = the AI layer (local models). v1 is Foundation + Layer 1
  (Spine A); Layers 2–3 are roadmap.
- **Role group** — a Nextcloud group representing a CESFAM staff role. **Access to every feature and folder
  is granted per role group, never per individual.** The taxonomy is **provisional and extensible** (not yet
  fully validated; designed to grow — "leave space for more"). Roles fall into coarse categories —
  **Dirección/Jefaturas**, **Profesionales clínicos**, **Técnicos (TENS/TONS)**, **Administrativos y
  soporte** — usable for coarse-grained access. The full initial enumeration lives in §4.3.
- **Access matrix** — the mapping of *which role group can do what in which folder/feature*. v1 establishes the
  RBAC **model** and an **initial** mapping; the final, validated matrix is refined with the CESFAM later.
- **RBAC (role-based access control)** — the model by which access to folders/apps is differentiated by role
  group. A core, cross-cutting requirement.
- **Group folder** — a shared folder scoped and permissioned to one or more role groups (the mechanism for the
  permissioned structure).
- **Document Home** — the organized, permissioned folder tree that is Spine A's structure, plus the
  **organization conventions** (naming/placement rules) that keep it tidy.
- **Roadmap feature** — a capability deferred past v1, built later one at a time: Nextcloud **Tables** → **REM
  app** → **full-text search** → **Paperless-ngx** → **Analytics** → **AI layer**.
- **REM** — *Registro Estadístico Mensual*, the Chilean APS/MINSAL monthly statistical reporting format; the
  future **REM app** (Layer 2) relates to the existing `rem-analyzer`. Defined here for reference; **out of
  v1**.
- **License outline** — the committed SSOT artifact enumerating the license of every app, code, stack and
  dependency (OSS-first; copyleft cores accepted for self-hosting).
- **Legal SSOT artifact** — the committed Chile compliance/localization document (locale, formats, calendar,
  data-protection law, MINSAL conventions) reviewed whenever a feature touches data, formats, or scheduling.
- **Synthetic fixtures** — fake, non-real seed data used in dev; real data and secrets never enter git, Docker
  volumes, or Syncthing.
- **es-CL** — Chilean Spanish locale; timezone **America/Santiago**, currency **CLP ($)**, Chilean date/number
  and identifier formats (e.g. **RUT**). All user-facing UI is Spanish; all code/backend/identifiers are
  English.

## 4. Features

*Each subsection is a coherent feature: behavioral description, then FRs nested under it. FRs are numbered
globally (`FR-1`…`FR-17`) so downstream artifacts have stable references even if features are reorganized.
Capabilities only — technical mechanisms (Compose topology, image pins, Xdebug wiring, theming internals)
live in `addendum.md` and are settled by `bmad-architecture`.*

### 4.1 Foundation & Local Dev Environment (Epic 0)

**Description:** The first deliverable and first definition of success. A developer clones the repo and brings
the entire suite up locally — **Nextcloud 33 + PostgreSQL + Redis** — with one command, then debugs, tests,
and extends it. Because v1's users *are* the three developers, this feature is the product's core: a portable,
reproducible, debuggable environment plus a repo that teaches its own use. Custom code and themes live in the
repo and are bind-mounted so edits are live. No step depends on one developer's machine.

**Functional Requirements:**

#### FR-1: One-command local bring-up

A developer can bring the full stack up locally from a clean clone with a single documented command, reaching a
running Nextcloud in a browser.

**Consequences (testable):**
- From `clone → copy the example env → one `make`-style command`, the stack starts with **no manual
  per-service steps**.
- Nextcloud reports installed and healthy (`occ status` → `installed: true`) against PostgreSQL 16, with Redis
  active for caching/locking.
- The instance is reachable at a documented local URL/port defined in committed config.

#### FR-2: Live PHP debugging

A developer can step-debug the running Nextcloud from their editor (breakpoints, variable inspection) against
the containerized PHP.

**Consequences (testable):**
- A breakpoint set in editor is hit on a matching request to the running instance.
- Debugging is a **derived dev-only image/config**, never a fork of Nextcloud source.

#### FR-3: Smoke check & test entry point

A developer can run one command that verifies the stack is healthy and runnable, as the local quality gate.

**Consequences (testable):**
- A single `smoke`/`test` target returns non-zero on a broken stack and zero on a healthy one.
- The gate is documented as the pre-merge check (CI is deferred; the gate is local — see `CONTRIBUTING.md`).

#### FR-4: Synthetic fixtures seeding

A developer can seed the instance with deterministic **synthetic fixtures** — users, role groups, and the
initial folder structure — so the environment is populated for development without any real data.

**Consequences (testable):**
- Seeding creates the role groups (§4.3) and folder tree (§4.4) reproducibly.
- Fixtures are clearly fake; **no real CESFAM data, no secrets** are ever committed or seeded.

#### FR-5: Repo-as-SSOT onboarding

A new developer can read the repository and self-serve everything needed to run, extend, and contribute — the
repo is the single source of truth and manages developer access/collaboration.

**Consequences (testable):**
- A quickstart (`clone → configure → up → open`) is present and sufficient for a fresh machine.
- Conventions, branching/review gate, and "where things live" are documented in-repo (`README`,
  `CONTRIBUTING`, `docs/`).

#### FR-6: Custom app & theme live-edit mounts

A developer can add custom apps and theme code in the repo and see changes live in the running instance
without rebuilding from scratch.

**Consequences (testable):**
- `apps/` maps to Nextcloud `custom_apps` and `themes/` to theming, bind-mounted for live edit.
- A trivial custom app placed in `apps/` is discoverable/enable-able in the running instance.

**Feature-specific NFRs:** portability and reproducibility across dev machines and OSes are load-bearing here —
see Cross-Cutting NFRs (`host.docker.internal` works cross-OS; nothing VPS-specific or absolute-path-bound in
the core compose).

### 4.2 White-label Branding & Locale Scaffold

**Description:** The instance presents as **APS Conecta**, not stock Nextcloud, and behaves as a Chilean system
by default. Branding is applied through supported Nextcloud theming only — never a source fork. Locale defaults
make Spanish (es-CL), America/Santiago, and Chilean formats the baseline every later feature inherits.

**Functional Requirements:**

#### FR-7: White-label APS Conecta branding

An administrator sees the instance branded as APS Conecta — name, logo, and theme/colors — across login and
the web UI.

**Consequences (testable):**
- Product name, logo, and primary theme colors reflect APS Conecta on the login page and header.
- Branding is delivered via Nextcloud theming/config (custom theme in `themes/` or theming app), with **no
  modification of Nextcloud source**.

#### FR-8: es-CL locale & Chilean formats as defaults

A user gets a Spanish (es-CL) UI, America/Santiago timezone, and Chilean date/number/currency formatting as the
instance defaults.

**Consequences (testable):**
- Default language = Spanish; default timezone = America/Santiago.
- Dates, numbers, and currency render in Chilean format; the split holds — **UI Spanish, code/identifiers
  English**. `[ASSUMPTION: es-CL is approximated via Nextcloud's `es`/`es_419` where a discrete es-CL locale is
  unavailable; exact locale handling settled in architecture.]`

### 4.3 Identity, Roles & Access Model (RBAC)

**Description:** Access to every feature and folder is governed by **role group**, never by individual. v1
provisions the initial, **provisional and extensible** role taxonomy and the mechanism to place users into one
or more role groups. The taxonomy is shaped around real CESFAM roles even though no staff use v1 — so the
structure the devs iterate on is the right shape from the start.

**Initial role taxonomy (provisional — "leave space for more"):**

- **Dirección / Jefaturas** — Director/a de CESFAM · Subdirector/a Médico o Jefe Técnico · Jefe/a de Sector
  (Gestión MAIS).
- **Profesionales clínicos** — Médico General / Médico de Familia · Cirujano Dentista · Químico Farmacéutico
  (Director Técnico de Farmacia) · Enfermera/o · Matrona/Matrón · Kinesiólogo/a · Psicólogo/a · Trabajador/a
  Social (Asistente Social) · Nutricionista · Terapeuta Ocupacional / Fonoaudiólogo/a.
- **Técnicos (TENS / TONS)** — TENS – Procedimientos / Vacunatorio · TENS – Farmacia / PNAC (Entrega de Leche)
  · TONS (Técnico en Odontología).
- **Administrativos y soporte** — Administrativo SOME (Sector / Transversal) · Encargado/a OIRS · Encargado/a de
  Estadística (REM) · Conductor (Ambulancia / Vehículo de Traslado) · Auxiliar de Servicio (Aseo / Mantención /
  Estafeta).

**Functional Requirements:**

#### FR-9: Provision the role-group taxonomy

An administrator has the initial role groups provisioned (the taxonomy above), organized so coarse categories
are usable for group-level access.

**Consequences (testable):**
- Each listed role exists as a group; adding a new role group requires **no redesign** (extensible).
- Categories are represented such that "all clinical professionals" style grants are expressible.
  `[ASSUMPTION: categories are modeled as groups (or group naming convention); flat-vs-nested mechanism settled
  in architecture.]`

#### FR-10: Group-based, extensible access

A developer/administrator grants access to folders and features **per role group, never per individual**, and
can extend the taxonomy without reworking existing grants.

**Consequences (testable):**
- No access rule targets an individual user; all target role groups.
- Adding a role group and granting it access does not disturb existing groups' access.

#### FR-11: User provisioning & multi-role assignment

An administrator can create a user and assign them to one or more role groups; a person holding two roles
receives the union of those roles' access.

**Consequences (testable):**
- A user assigned to two role groups can reach everything either group can, and nothing more.
- Removing a user from a role group revokes exactly that group's access.

### 4.4 Document Home & Permissioned Structure (Spine A)

**Description:** Spine A's structure: one organized, permissioned home for the CESFAM's documents, replacing
WhatsApp/pendrive/Drive sprawl. v1 ships a **fuller first-cut** tree across **four areas** — **Transversal**
(all-staff shared knowledge, incl. *Actas de reuniones* per program), **Programas** (one folder per program,
owned by its Jefatura), **Unidades** (functional units: SOME, Farmacia, Dental, OIRS, Estadística-REM), and
**Sectores** (the CESFAM's own territorial sectors) — provisioned as group folders with a first-cut access
matrix and a small set of organization conventions. Because no specific CESFAM is chosen yet, the **program
list and the sector names are CESFAM-specific and left open/parameterizable** — provisional placeholders the
team fills per deployment. It is explicitly the initial structure devs (and later the CESFAM) refine; the final
validated **access matrix** comes later.

**Initial tree (first-cut):**

```
/
├─ Transversal/                 (all-staff readable — shared knowledge)
│   ├─ Protocolos/
│   ├─ Flujogramas/
│   ├─ Documentación/
│   ├─ Registro de redes/
│   └─ Actas de reuniones/      (per program: Salud Mental, Infantil, Adulto, …)
├─ Programas/                   (one folder per program — owned by its Jefatura)
│   ├─ Salud Mental/
│   ├─ Infantil/
│   ├─ Adulto · Adulto Mayor/
│   ├─ Cardiovascular · ECICEP/
│   └─ … (program list is CESFAM-specific — parameterizable)
├─ Unidades/                    (functional units)
│   ├─ SOME/
│   ├─ Farmacia/
│   ├─ Dental/
│   ├─ OIRS/
│   ├─ Estadística-REM/
│   └─ Dirección/
└─ Sectores/                    (CESFAM territorial sectors — names OPEN: colour/number/name)
    ├─ «Sector 1»/
    ├─ «Sector 2»/
    └─ … (mixed-role team space; named per CESFAM)
```

**First-cut access matrix (provisional — category granularity + role-specific ownership):**

| Folder | Read | Write / Manage |
|---|---|---|
| Transversal/Protocolos, Flujogramas, Documentación | All staff | Dirección/Jefaturas |
| Transversal/Registro de redes | All staff | Dirección/Jefaturas + Trabajador/a Social |
| Transversal/Actas de reuniones/«programa» | All staff | Dirección/Jefaturas + that program's Jefatura/team |
| Programas/«programa» | That program's assigned roles + Dirección/Jefaturas | That program's Jefatura (+ team) |
| Unidades/SOME | Dirección/Jefaturas | Administrativo SOME |
| Unidades/Farmacia | Dirección/Jefaturas | Químico Farmacéutico + TENS – Farmacia/PNAC |
| Unidades/Dental | Dirección/Jefaturas | Cirujano Dentista + TONS |
| Unidades/OIRS | Dirección/Jefaturas | Encargado/a OIRS |
| Unidades/Estadística-REM | **Dirección/Jefaturas only** | Encargado/a de Estadística (REM) |
| Unidades/Dirección | Dirección/Jefaturas | Dirección/Jefaturas |
| Sectores/«sector» | That sector's team + Dirección/Jefaturas | That sector's team |

*(**Write/Manage implies Read** — the Read column lists *additional* readers beyond a folder's managers.
Restricted areas — e.g. Estadística-REM — are read-narrow by default. The **program → roles** assignment and
the **sector → team** assignment are CESFAM-specific and provisional; per-role refinements beyond this first
cut are deferred to the CESFAM-validated matrix.)*

**Functional Requirements:**

#### FR-12: Provision the hybrid permissioned tree

An administrator has the hybrid four-area tree — **Transversal · Programas · Unidades · Sectores** —
provisioned as group folders, matching the first-cut layout above.

**Consequences (testable):**
- The tree exists as group folders reproducibly seeded by fixtures (FR-4).
- Adding/renaming a top-level area does not require rebuilding the instance.

#### FR-13: Apply the first-cut access matrix

Access to each folder is wired to role groups per the first-cut matrix, so a user sees and edits exactly what
their role(s) permit.

**Consequences (testable):**
- A user in only *Profesionales clínicos → Médico* can read `Transversal/Protocolos` but cannot write it, and
  cannot see `Unidades/Farmacia` content.
- The **Encargado/a de Estadística (REM)** can manage `Unidades/Estadística-REM`; other non-Dirección roles
  cannot read it.
- Every access grant targets a role group (satisfies FR-10).

**Out of Scope (this FR):** the final CESFAM-validated access matrix; per-individual exceptions.

#### FR-14: Organization conventions

The Document Home carries a small, documented set of naming/placement conventions so the structure stays tidy
as content grows.

**Consequences (testable):**
- A minimal convention set exists — a file/folder **naming pattern**, where a document **belongs** (which
  area/folder), and a **versioning approach** (one live copy over duplicated files, addressing "no single
  trusted version") — documented in-repo and surfaced in the relevant folders (e.g. a README/convention note).
- `[NON-GOAL for MVP]` automated enforcement / AI auto-sorting of documents — that is a roadmap AI-layer
  capability, not v1.

### 4.5 Live Collaborative Editing (Collabora / Nextcloud Office)

**Description:** Documents are edited live, in the browser, inside Nextcloud — the capability that makes the
Document Home a working replacement for emailing files around. Collabora / Nextcloud Office runs as part of the
stack so multiple users co-edit the same document with changes converging.

**Functional Requirements:**

#### FR-15: Integrated office editing in-browser

A user can open and edit office documents (text, spreadsheet, presentation) directly in the browser within
Nextcloud.

**Consequences (testable):**
- Opening a supported document launches the in-browser editor against the running stack (Collabora / NC
  Office reachable from the instance).
- Create-new works for at least text, spreadsheet, and presentation document types.

#### FR-16: Concurrent live co-editing

Two or more users can edit the same document simultaneously and see each other's changes converge without
overwriting.

**Consequences (testable):**
- Two sessions editing one document both persist their edits; no lost-update on concurrent edit.
- Presence/cursors of co-editors are visible.

#### FR-17: Chilean/OSS format support

A user can work with the common office formats the CESFAM already uses, edited/saved without a paid license.

**Consequences (testable):**
- Open-document and MS formats (odt/docx, ods/xlsx, odp/pptx) open and save in-browser.
- The editing stack is OSS and self-hosted — **no paid license** (satisfies the OSS-first constraint).

## 5. Non-Goals (Explicit)

What APS Conecta Gestión is **not**, and what v1 will **not** do — so no epic, ticket, or PR quietly adds a
"nearby" thing:

- **Not an operations/admin system.** No **turnos**, **ausencias**, **remuneraciones/finanzas**, or enterprise
  **HR/RRHH**. This is process- and knowledge-management for staff working on their own data.
- **Not a clinical/patient system.** **No patient or clinical data** ever; dev uses synthetic fixtures only.
- **v1 is not the live staff rollout.** No production deployment to real CESFAM users, no change-management
  program, and no end-user **tutorials/training** in v1 — those belong to the later production version.
- **No AI layer (Layer 3) in v1.** Document auto-organization, protocol-expiry alerts, cross-reference error
  detection, and program analysis via local models are roadmap. `[NOTE FOR PM: the AI assistant is the
  headline of the long-term vision — deferred, not dropped.]`
- **No Layer-2 custom apps in v1.** The **REM app** (and any other custom CESFAM app) is roadmap.
  `[NOTE FOR PM: REM is the first planned custom app and relates to the existing `rem-analyzer`; revisit right
  after the foundation lands.]`
- **No structured-data stack in v1.** Nextcloud **Tables**, **full-text search**, **Paperless-ngx**, and
  **Analytics/reporting** — including **reporte de datos** and **análisis de problemas** — are roadmap
  features, added later one at a time. `[NOTE FOR PM: this structured, searchable, analyzable database is the
  brief's **core bet** — the point where the data itself becomes the value. Deferred to keep v1 a solid
  foundation; emphatically not dropped.]`
- **No automated enforcement of organization conventions in v1.** Conventions are documented/human-followed;
  auto-sorting is an AI-layer capability.
- **No validated adoption/wellbeing measurement in v1.** Instruments like the **Maslach Burnout Inventory
  (Chile-validated)**, an **Intranet Satisfaction Questionnaire**, or **TAM** are for later/advanced versions,
  once real staff use the product (see §7).
- **Not a Nextcloud source fork.** White-label only, via supported theming and config.

## 6. MVP Scope

### 6.1 In Scope

The **developer-facing v1**: a runnable, debuggable, white-label foundation plus the initial Spine A document
structure.

- **Foundation / Epic 0** (FR-1…FR-6): one-command local bring-up (NC 33 + PostgreSQL 16 + Redis), live PHP
  debugging, smoke/test gate, synthetic fixtures, repo-as-SSOT onboarding, custom app/theme live-mounts.
- **White-label branding & locale** (FR-7…FR-8): APS Conecta identity; es-CL / America-Santiago / Chilean
  formats as defaults.
- **Identity, roles & access** (FR-9…FR-11): the provisional, extensible role taxonomy (4 categories, ~21
  roles); group-based access; user provisioning with multi-role.
- **Document Home / Spine A** (FR-12…FR-14): the first-cut hybrid tree (Transversal · Programas · Unidades ·
  Sectores) as group folders; the first-cut access matrix; organization conventions.
- **Live collaborative editing** (FR-15…FR-17): Collabora / Nextcloud Office integrated; concurrent co-editing;
  OSS format support, no paid license.

### 6.2 Out of Scope for MVP

- **Live staff rollout · tutorials · change management** — deferred to the production version (v1 is
  dev-facing). `[NOTE FOR PM: the pilot's adoption story is load-bearing for the project — revisit as the
  immediate next milestone after v1.]`
- **Validated measurement instruments** (Maslach BI-Chile, Intranet Satisfaction Questionnaire, TAM) — later
  versions, instruments not yet chosen.
- **AI layer (Layer 3)** — roadmap; local models on own data, rules-governed.
- **Custom Layer-2 apps (REM app, others)** — roadmap; built one at a time on the foundation.
- **Structured-data stack** — Nextcloud Tables, full-text search, Paperless-ngx, Analytics/reporting —
  roadmap.
- **Final CESFAM-validated access matrix** and concrete **program/sector naming** — the v1 tree is a
  parameterizable first cut; the validated matrix follows once a specific CESFAM is engaged.
- **Automated convention enforcement / document auto-sorting** — AI-layer, roadmap.

## 7. Success Metrics

*v1 is developer-facing, so v1 success is measured against the developers and the foundation working — not
staff adoption. Each SM cross-references the FR(s) it validates.*

**Primary**

- **SM-1: Reproducible bring-up.** All **3/3 developers** go from clean clone to a running instance with one
  command on their own machine (cross-OS). Validates FR-1 (and the portability NFR).
- **SM-2: Debug + gate loop.** A developer can hit a breakpoint in the running instance, run the smoke/test
  gate to green, and enable a trivial custom app placed in `apps/`. Validates FR-2, FR-3, FR-6.
- **SM-3: Initial structure stands up.** Fixtures seed the role taxonomy, the hybrid tree, and the access
  matrix; a spot-check confirms RBAC holds (a single-role user sees exactly its permitted folders, and nothing
  restricted). Validates FR-4, FR-9–FR-14.
- **SM-4: Live co-editing works.** Two sessions co-edit one document in a common office format (e.g. docx/odt)
  and changes converge with no lost update. Validates FR-15, FR-16, FR-17.
- **SM-5: Self-serve onboarding.** A person following only the repo reaches a running instance without tribal
  knowledge. Validates FR-5.

**Secondary**

- **SM-6: Branding & locale correct.** The instance presents as APS Conecta with Spanish/es-CL and
  America-Santiago defaults. Validates FR-7, FR-8.

**Counter-metrics (do not optimize)**

- **SM-C1: Taxonomy restraint.** Growth in the number of folders / access rules / roles *beyond the first cut*
  is **not** progress before real staff validate it — resist elaborating the matrix in the dark. Counterbalances
  SM-3.
- **SM-C2: Scope restraint.** Roadmap features shipped to "look done" (Tables, REM app, search, Analytics, AI)
  count **against** v1, not for it. Counterbalances the urge to show breadth over a solid foundation.

**Forward-looking measurement (deferred — not v1 targets).** Later/advanced production versions will measure
real adoption and staff impact with **validated instruments** — candidates include the **Maslach Burnout
Inventory (Chile-validated)**, an **Intranet Satisfaction Questionnaire**, and the **Technology Acceptance
Model (TAM)**. The specific instruments are **not yet chosen** (see Open Questions). Because this is novel work
with no known CESFAM precedent, designing that measurement is itself a later research task — v1 deliberately
sets no adoption/wellbeing targets.

## 8. Cross-Cutting NFRs

*System-wide qualities not tied to a single feature. FRs inherit these.*

- **NFR-1 · Portability & reproducibility.** The dev stack runs on any developer's machine, cross-OS, from
  committed config — `host.docker.internal` resolves cross-OS; **nothing VPS-specific** (Tailscale, absolute
  host paths) in the core compose. Two developers on different OSes get the same running instance.
- **NFR-2 · Security & data protection.** Self-hosted; **no patient/clinical data**; secrets and `.env` never
  committed (restricted env files, mode-600 discipline); **synthetic fixtures only**; RBAC (FR-10) is the
  primary access control. Real data and secrets never enter git, Docker volumes, or Syncthing.
- **NFR-3 · OSS-first & license clarity.** All components are **open-source, self-hosted, and free — no paid
  licenses**; prefer the most permissive licenses that allow free modification; copyleft cores (Nextcloud
  AGPL, Collabora, and future Paperless-ngx GPL) are accepted for self-hosting. An explicit **License outline**
  enumerating every app/stack/dependency license is a committed SSOT artifact.
- **NFR-4 · Language split.** All **user-facing UI is Spanish (es-CL)**; all **code, backend, identifiers,
  comments, and docs are English** — consistently.
- **NFR-5 · White-label maintainability (no fork).** Nextcloud is consumed via the **official image**;
  customization is confined to `apps/` (→ `custom_apps`), `themes/`, and config; Xdebug is a **derived
  dev-only image**, not a fork — keeping Nextcloud upgrades tractable.
- **NFR-6 · Footprint (dev-scale).** v1 targets local dev on an ordinary laptop; no production performance
  budgets are set here — sizing, high-availability, and backup targets are a later (production) concern.

## 9. Constraints & Guardrails

- **Privacy.** Internal operations only; **no patient/clinical data, ever**. Dev uses synthetic fixtures; real
  data and secrets stay out of git, Docker volumes, and Syncthing.
- **Security.** RBAC as the primary control (least-privilege role groups); secrets discipline (NFR-2);
  self-hosted, no third-party data egress in v1.
- **Cost.** OSS-first, **zero paid licenses**; self-hosted; free tier of any tooling. Paid options are named
  only as a last resort when no free+OSS alternative exists.

## 10. Data Governance & Legal (Chile)

*The suite serves a Chilean CESFAM; data, dates, money, and formats are Chilean. First-class and tracked from
the start via a committed **Legal SSOT artifact**, even though v1's exposure is low (dev-facing, no patient
data).*

- **Locale & formats.** es-CL; timezone **America/Santiago**; currency **CLP ($)**; Chilean date/number and
  identifier formats (e.g. **RUT**).
- **Schedules.** Any cron jobs, deadlines, and reporting cycles align to the Chilean calendar (working days,
  **feriados**) and timezone.
- **Legal compliance.** Chilean data-protection/security law — **Ley 19.628** and the newer **Ley 21.719** —
  plus any primary-health/**MINSAL** requirements relevant to internal ops. The **Legal SSOT artifact** carries a
  **compliance checklist** reviewed whenever a feature touches **data, formats, or scheduling**.
- **Standards fit.** REM and program formats follow Chilean primary-care (**APS/MINSAL**) conventions — load-
  bearing when the roadmap REM app arrives; noted here so the foundation does not contradict it.

## 11. Integration & Dependencies

- **Collabora / Nextcloud Office** — service dependency for live collaborative editing (FR-15–FR-17); part of
  the dev stack.
- **Core stack** — **Nextcloud 33** (official image), **PostgreSQL 16**, **Redis**. Exact pins and topology are
  ratified by `bmad-architecture` (already boot-checked: NC 33.0.6 + PG 16 come up clean).
- **GitHub** — the **project SSOT** and the manager of developer access/collaboration (repo-first, repo
  canonical). Distinct from **product content** — the CESFAM's documents/data live in Nextcloud, not GitHub.
- **Context7 MCP** — reference documentation (Nextcloud admin/dev/OCP, Vue kit) is pulled **live** and never
  hardcoded (see `README.md`). A dev-tooling dependency, not a runtime one.

## 12. Rollout (deferred — production version)

v1 is developer-facing; there is no staff rollout in scope. Recorded here so the boundary is explicit: the
**immediate next milestone after v1** is the production version — phased onboarding of real staff off
WhatsApp/pendrive/Drive, role-group provisioning for real users, **change management**, **end-user tutorials**,
and **validated adoption/wellbeing measurement** (§7). v1's job is to make that rollout *buildable*, not to
perform it.

## 13. Open Questions

1. **Which CESFAM is the pilot target?** Determines the concrete **sector names**, **program list**, and the
   exact **role set** — all left parameterizable in v1.
2. **Which validated instruments** (Maslach BI-Chile / Intranet Satisfaction Questionnaire / TAM / other), and
   at which version, for later adoption/wellbeing measurement? (Novel work — no known CESFAM precedent.)
3. **Final CESFAM-validated access matrix**, including **program → roles** and **sector → team** assignments —
   pending a specific CESFAM.
4. **RBAC category modeling** — flat groups vs nested groups vs naming convention for the four categories
   (architecture decision; see Assumptions).
5. **es-CL locale handling** in Nextcloud — discrete es-CL vs `es`/`es_419` fallback (architecture).
6. **Collabora deployment shape** — bundled CODE vs separate Collabora Online service (architecture).
7. **License outline** — enumerate every component/dependency license and confirm copyleft acceptance per item
   (committed SSOT artifact).
8. **Production concerns** — hosting, sizing, backup, RTO/RPO — out of v1; to be defined for the production
   version.

## 14. Assumptions Index

*Every `[ASSUMPTION]` from the document, plus the explicitly provisional decisions, surfaced for confirmation:*

- **§4.2 / FR-8** — es-CL is approximated via Nextcloud's `es`/`es_419` where a discrete es-CL locale is
  unavailable; exact handling settled in architecture.
- **§4.3 / FR-9** — the four role **categories** are modeled as groups (or a group naming convention); the
  flat-vs-nested mechanism is settled in architecture.
- **Provisional (stated in-text, pending a specific CESFAM):** the **role taxonomy** (~21 roles, "leave space
  for more"); the **first-cut access matrix**; the **program list** and **sector names** (parameterizable
  placeholders). All are first cuts the team refines with the CESFAM later.
