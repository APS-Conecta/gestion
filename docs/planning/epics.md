---
stepsCompleted: ["step-01-validate-prerequisites", "step-02-design-epics", "step-03-create-stories", "step-04-final-validation"]
inputDocuments:
  - docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md
  - docs/planning/prds/prd-apsconecta-gestion-2026-07-18/addendum.md
  - docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md
  - docs/ARCHITECTURE.md
---

# APS Conecta Gestión v1 - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for **APS Conecta Gestión v1**, decomposing the
requirements from the PRD and the Architecture spine into implementable stories. v1 is **developer-facing**:
Foundation (Epic 0) + the initial Spine A document structure the three developers build on. No UX contract
exists (UX/tutorials are a production-version deliverable).

## Requirements Inventory

### Functional Requirements

FR-1: A developer can bring the full stack (Nextcloud 34 + PostgreSQL 18 + Redis + office suite) up locally from a clean clone with one documented command, reaching a running Nextcloud in the browser.
FR-2: A developer can step-debug the running Nextcloud (breakpoints, variable inspection) from their editor against the containerized PHP.
FR-3: A developer can run one command that verifies the stack is healthy and runnable (the local smoke/test gate).
FR-4: A developer can seed the instance with deterministic synthetic fixtures (users, role groups, folder structure) — no real data.
FR-5: A new developer can read the repository and self-serve everything needed to run, extend, and contribute (repo-as-SSOT onboarding).
FR-6: A developer can add custom apps and theme code in the repo and see changes live (`apps/`→`custom_apps`, `themes/` bind-mounted).
FR-7: An administrator sees the instance white-labeled as APS Conecta (name, logo, theme colors) via supported theming — no source fork.
FR-8: A user gets a Spanish (es-CL) UI, America/Santiago timezone, and Chilean date/number/currency formats as instance defaults.
FR-9: An administrator has the initial role-group taxonomy provisioned (the ~21-role registry across 4 categories), extensible without redesign.
FR-10: Access is granted per role group (never per individual), and adding a role group does not disturb existing grants.
FR-11: An administrator can create a user and assign one or more role groups; a multi-role user receives the union of access.
FR-12: An administrator has the hybrid four-area tree (Transversal · Programas · Unidades · Sectores) provisioned as group folders.
FR-13: Access to each folder is wired to role groups per the first-cut access matrix (a single-role user sees exactly its permitted folders).
FR-14: The Document Home carries a documented set of organization conventions (naming/placement rules + a one-live-copy versioning norm).
FR-15: A user can open and edit office documents (text, spreadsheet, presentation) directly in the browser within Nextcloud.
FR-16: Two or more users can co-edit the same document simultaneously with changes converging (no lost update; co-editor presence visible).
FR-17: A user can work with common office formats (odt/docx, ods/xlsx, odp/pptx) edited/saved in-browser with no paid license.

### NonFunctional Requirements

NFR-1: Portability & reproducibility — the core compose runs on any developer machine and OS from committed config; `host.docker.internal` resolves cross-OS; nothing VPS-specific or absolute-path-bound.
NFR-2: Security & data protection — self-hosted; no patient/clinical data ever; secrets and `.env` never committed; synthetic fixtures only; RBAC is the primary access control.
NFR-3: OSS-first & license clarity — all components open-source, self-hosted, free (no paid licenses); an explicit License-outline SSOT artifact enumerates every dependency license.
NFR-4: Language split — all user-facing UI is Spanish (es-CL); all code, backend, identifiers, comments, and docs are English.
NFR-5: White-label maintainability (no fork) — Nextcloud runs from the official image; customization is confined to `apps/`, `themes/`, and config; Xdebug is a derived dev-only image.
NFR-6: Footprint (dev-scale) — v1 targets local dev on an ordinary laptop; production sizing, HA, and backups are deferred.

### Additional Requirements

*From the Architecture spine (AD = architecture decision). These govern how the FRs/NFRs are implemented; each story must obey the ADs it touches.*

- AR-1 (AD-1, NFR-5): No fork — Nextcloud from the **official image**; changes only in `apps/` (custom_apps), `themes/`, or config; no core patch, no `defaults.php` overrides.
- AR-2 (AD-2): **One idempotent `occ` provisioning script** is the single writer of desired state — idempotent-by-guard (query-before-create; `groupfolders:create` is not idempotent by name), fixed **phase order** (branding/locale → groups → group folders → ACLs → user→group membership → sample-content fixtures), and a **structure-vs-fixtures ownership partition**.
- AR-3 (AD-3): Data ownership — Nextcloud data volume (content), PostgreSQL (metadata), Redis (cache/locks); repo owns recipe + config only; no product data/secrets in git.
- AR-4 (AD-4 + Group Registry): RBAC via **Group Folders**, group-only principals. Canonical registry: 21 `role-*` IDs + slugs + role→category map; `cat-*` categories; **`all-staff` (every user)**; parameterizable `prog-*` / `sector-*` team groups. Mount model: Transversal = 1 group folder; each program/unit/sector = its own group folder. ACL = **allow-refinement, no DENY rules**.
- AR-5 (AD-5, AD-11): Office editing via a **standalone document-server container**, **switchable between Collabora CODE** (`collabora/code` via `richdocuments`/WOPI) **and Euro-Office** (`ghcr.io/euro-office/documentserver` via the `eurooffice` connector/JWT) — separate containers, **exactly one active at a time**; the built-in `richdocumentscode` is **not installed**. (Both images support arm64 for Apple-Silicon devs.)
- AR-6 (AD-6): Branding via `occ theming:config` (name/logo/favicon/primary_color/background_color/slogan/url/background) + `disable-user-theming yes`; assets bind-mounted local files.
- AR-7 (AD-7): `default_language=es_419` + `default_locale=es_CL` set via `occ`, **unlocked** (not forced).
- AR-8 (AD-8): Portable compose; **container↔container via compose service names** (`http://collabora:9980`, `http://nextcloud`); `host.docker.internal` only host↔container (Linux: `extra_hosts: host.docker.internal:host-gateway`). WOPI uses three distinct URLs.
- AR-9 (AD-9): Custom-code boundary (future) — apps in `apps/`→`custom_apps`, depend on Nextcloud only via OCP public APIs; core never depends on a custom app.
- AR-10 (AD-10): Xdebug as a **derived dev-only image/profile** (`compose.dev.yaml`), never in the base image.
- AR-11 (Stack, verified 2026-07-19): `nextcloud:34-apache` · `postgres:18-alpine` · `redis:8-alpine` (AGPL) · office servers `collabora/code` **or** `ghcr.io/euro-office/documentserver` · `richdocuments` + `eurooffice` + `groupfolders` apps (NC34 line). No formal starter template — the starter is the official NC34 image + Docker Compose.
- AR-12 (Conventions): Makefile targets `up` (services only, no seed) · `down` · `seed` (idempotent provisioning) · `smoke`/`test` (gate); `.env.example` → `.env` (gitignored).
- AR-13 (Deferred pointers): committed **License-outline** artifact (NFR-3; incl. Redis 8 AGPL vs Valkey BSD) and the **Legal/Chile data-governance SSOT** (Ley 19.628/21.719, MINSAL) — tracked from the start; low v1 exposure.

### UX Design Requirements

None — no UX design contract exists for v1 (developer-facing; end-user tutorials/journeys are a production-version deliverable).

### FR Coverage Map

FR-1: Epic 0 — one-command local bring-up
FR-2: Epic 0 — live PHP step-debug
FR-3: Epic 0 — smoke/test gate
FR-4: Epic 0 — synthetic fixtures mechanism (sample content grows with Epics 2–3)
FR-5: Epic 0 — repo-as-SSOT onboarding
FR-6: Epic 0 — custom app/theme live mounts
FR-7: Epic 1 — white-label APS Conecta branding
FR-8: Epic 1 — es-CL language/locale defaults
FR-9: Epic 2 — provision role/category/team groups (Group Registry)
FR-10: Epic 2 — group-based, extensible access
FR-11: Epic 2 — user provisioning + multi-role union
FR-12: Epic 3 — provision the hybrid four-area Group Folders tree
FR-13: Epic 3 — apply the first-cut access matrix
FR-14: Epic 3 — organization conventions
FR-15: Epic 4 — in-browser office editing
FR-16: Epic 4 — concurrent co-editing
FR-17: Epic 4 — OSS format support

*NFRs are cross-cutting: NFR-1 portability (Epic 0), NFR-2 security/no-patient-data (all), NFR-3 OSS-first (all/stack), NFR-4 language split (Epic 1 + all), NFR-5 no-fork (all), NFR-6 dev footprint (Epic 0/4). ARs bind to the epics whose FRs they govern.*

## Epic List

### Epic 0: Foundation & Local Dev Environment
A developer can bring the full white-label stack (Nextcloud 34 + PostgreSQL 18 + Redis + office suite) up locally on any OS with one command, step-debug the running PHP, run a green smoke/test gate (including an **office editing smoke** — Collabora or Euro-Office), and extend it via live-mounted `apps/`/`themes/`. Epic 0 delivers the **provisioning framework** — a phase-structured `provisioning/` directory of numbered, separate phase files (`10-branding`, `20-groups`, `30-folders`, `40-acl`, `50-users`, `60-fixtures`), idempotency-guard helpers, and `make seed` wiring — so later epics **append a phase file** rather than editing one monolithic script. FR-4 here = the fixtures *mechanism* + sample users seeded into `all-staff`; per-epic seed content lands with Epics 2–3.
**FRs covered:** FR-1, FR-2, FR-3, FR-4 (mechanism), FR-5, FR-6
**Governing ARs:** AR-1, AR-2 (phase-file framework + idempotency guards), AR-3, AR-8 (incl. office editing smoke), AR-10, AR-11, AR-12

### Epic 1: White-label Identity & Localization
The instance presents as APS Conecta in Chilean Spanish — branding (name, logo, colors) via `occ theming:config` and es-CL language/formatting defaults — as the first provisioning phase every later capability inherits.
**FRs covered:** FR-7, FR-8
**Governing ARs:** AR-6, AR-7

### Epic 2: Roles & Access Model
The CESFAM's role, category, and team groups exist (the canonical Group Registry); an administrator can create users and assign one or more roles; access is granted per group and is extensible without redesign.
**FRs covered:** FR-9, FR-10, FR-11
**Governing ARs:** AR-4 (registry + group provisioning), AR-2

### Epic 3: Document Home (Spine A)
Staff have one organized, permissioned home: the four-area hybrid tree (Transversal · Programas · Unidades · Sectores) provisioned as Group Folders with the first-cut access matrix and documented organization conventions, so each role sees exactly its permitted folders. *(Builds on Epic 2 — groups must exist to bind ACLs.)*
**FRs covered:** FR-12, FR-13, FR-14
**Governing ARs:** AR-4 (mount model + ACL), AR-2

### Epic 4: Live Collaborative Editing
Staff open and co-edit office documents (text/spreadsheet/presentation) live in the browser via the active standalone office server (Collabora or Euro-Office), with concurrent changes converging and common formats supported — no paid license.
**FRs covered:** FR-15, FR-16, FR-17
**Governing ARs:** AR-5, AR-8 (connector networking), AR-13

### Sequencing & dependencies
- **Epic 0** is foundational — every later epic needs its provisioning framework, gate, and stack.
- **Epic 4** (editing) depends only on Epic 0 (stack + office server), independent of RBAC/folders — build it **right after Epic 0** to de-risk the office/connector integration early.
- **Epics 1 & 2** are parallelizable (branding phase file vs groups phase file — no shared edits).
- **Epic 3** is strictly **after Epic 2** (its folder ACLs bind the `all-staff` / role / team groups Epic 2 creates).
- No epic edits another epic's provisioning phase file, so parallel epics don't conflict.

## Epic 0: Foundation & Local Dev Environment

Delivers the runnable, debuggable, portable stack + the provisioning framework later epics build on.

### Story 0.1: Portable core Compose stack

As a developer,
I want to bring up Nextcloud 34 + PostgreSQL 18 + Redis with one command on any OS,
So that I can start working without hand-assembling services.

**Acceptance Criteria:**

**Given** a clean clone and `cp .env.example .env`
**When** I run the single documented bring-up command (`make up`)
**Then** Nextcloud, PostgreSQL 18, and Redis start and Nextcloud is reachable at the documented local URL
**And** `occ status` reports `installed: true` against PostgreSQL, with Redis active for caching/locking

**Given** a Linux host
**When** a container needs to reach a host-published port
**Then** `host.docker.internal` resolves via `extra_hosts: host.docker.internal:host-gateway`
**And** the core compose contains no absolute host paths and nothing VPS-specific

### Story 0.2: Dual office suite — Collabora + Euro-Office, switchable, with editing smoke

As a developer,
I want each office backend (Collabora CODE and Euro-Office) as its own standalone container reachable from Nextcloud Office through its own connector, switchable one-at-a-time, each with a smoke check,
So that we can trial both suites and pick the best, with the editing pipe proven before feature work.

**Acceptance Criteria:**

**Given** the compose defines an `office` profile per backend (`collabora` → `collabora/code`; `eurooffice` → `ghcr.io/euro-office/documentserver`)
**When** I bring up one profile
**Then** exactly one office server container runs, the built-in `richdocumentscode` app is NOT installed, and each backend is reached from Nextcloud Office via its own connector app (`richdocuments` for Collabora, `eurooffice` for Euro-Office) pointed at that server's own URL

**Given** I run `make office-collabora`
**When** it completes
**Then** the `collabora/code` container is up, the `richdocuments` connector is enabled and configured to `http://collabora:9980`, the `eurooffice` connector is disabled, container↔container uses compose service names, the WOPI allow-list includes the compose subnet, and dev runs with `--o:ssl.enable=false`

**Given** I run `make office-eurooffice`
**When** it completes
**Then** the Euro-Office `documentserver` container is up, the `eurooffice` connector is enabled and configured to that server's URL with a shared `OFFICE_JWT_SECRET`, and the `richdocuments` connector is disabled — so exactly one backend claims docx/xlsx/pptx (no MIME conflict, AD-11)

**Given** the active backend's editing smoke runs
**When** it opens a scratch document as admin
**Then** the document loads in that backend's editor and the smoke passes (and fails on connector/host errors)

### Story 0.3: Xdebug derived dev profile

As a developer,
I want to step-debug the running Nextcloud from my editor,
So that I have a real feedback loop for building and verifying.

**Acceptance Criteria:**

**Given** the dev profile (`compose.dev.yaml`) is enabled
**When** I set a breakpoint and issue a matching request
**Then** the breakpoint is hit with variable inspection available

**Given** the base image
**When** the dev profile is built
**Then** Xdebug is layered in a derived dev-only image — never baked into the base image or committed core

### Story 0.4: Makefile targets + smoke/test gate

As a developer,
I want `make` targets for the lifecycle and a smoke/test gate,
So that the local quality gate is one command.

**Acceptance Criteria:**

**Given** the repo
**When** I inspect the Makefile
**Then** `up`, `down`, `seed`, `smoke`, `test` targets exist and are documented
**And** `up` starts services only (no seeding) while `seed` runs provisioning

**Given** a healthy stack
**When** I run `make smoke`
**Then** it returns zero; and against a broken stack it returns non-zero

### Story 0.5: Provisioning framework

As a developer,
I want a phase-structured, idempotent provisioning framework,
So that later epics append a phase file instead of editing one monolithic script.

**Acceptance Criteria:**

**Given** `provisioning/`
**When** I inspect it
**Then** it holds numbered phase files (`10-branding`, `20-groups`, `30-folders`, `40-acl`, `50-users`, `60-fixtures`) with no-op stubs plus shared idempotency-guard helpers (query-before-create)

**Given** `make seed`
**When** I run it twice
**Then** it converges idempotently (no errors, no duplicates) and executes phases in the fixed order 10→60

### Story 0.6: Fixtures mechanism + sample users

As a developer,
I want an idempotent fixtures mechanism that creates sample users and content,
So that the environment is populated without any real data.

**Acceptance Criteria:**

**Given** the `60-fixtures` phase
**When** `make seed` runs (and re-runs)
**Then** a small set of synthetic sample users is created idempotently (no duplicates on re-run)

**Given** the fixtures
**When** inspected
**Then** they are clearly synthetic and no real data or secrets are committed or seeded
**And** role/folder-specific seed content is added by Epics 2–3 (this story delivers the mechanism only)

### Story 0.7: Repo-as-SSOT onboarding

As a developer,
I want the repository to teach its own use,
So that a new developer is self-serve.

**Acceptance Criteria:**

**Given** only the repository
**When** a new developer follows the README quickstart (clone → `cp .env.example .env` → `make up` → open URL)
**Then** they reach a running instance on a fresh machine without tribal knowledge

**Given** the repo
**When** a developer looks for guidance
**Then** conventions, the branching/review gate, and "where things live" are documented (README/CONTRIBUTING/docs)

### Story 0.8: Custom app & theme live-mounts

As a developer,
I want `apps/` and `themes/` bind-mounted for live edit,
So that I can extend the instance without rebuilding.

**Acceptance Criteria:**

**Given** the compose
**When** it runs
**Then** `apps/` maps to `custom_apps` and `themes/` to theming, both bind-mounted

**Given** a trivial custom app placed in `apps/`
**When** I reload
**Then** it is discoverable and enable-able in the running instance

## Epic 1: White-label Identity & Localization

The instance presents as APS Conecta in Chilean Spanish — the first provisioning phases.

### Story 1.1: White-label branding phase

As an administrator,
I want the instance branded as APS Conecta,
So that it presents as our suite, not stock Nextcloud.

**Acceptance Criteria:**

**Given** the `10-branding` phase
**When** `make seed` runs
**Then** `occ theming:config` sets name/logo/favicon/`primary_color`/`background_color`/slogan/url from bind-mounted local assets, plus `disable-user-theming yes`

**Given** the login page and header
**When** a user views them
**Then** they show APS Conecta branding, with no Nextcloud source fork and no `defaults.php`

**Given** the branding phase
**When** seed re-runs
**Then** the configuration is idempotent

### Story 1.2: es-CL locale defaults

As a user,
I want a Spanish (es-CL) UI and Chilean formats by default,
So that the instance behaves as a Chilean system.

**Acceptance Criteria:**

**Given** the locale phase
**When** seed runs
**Then** `occ config` sets `default_language=es_419` and `default_locale=es_CL` (unlocked — not forced)

**Given** a new user
**When** they log in
**Then** the UI defaults to Spanish and dates/numbers render in Chilean format (dd-mm-yyyy verified), timezone America/Santiago per-user

**Given** a developer
**When** they wish to switch
**Then** they can still change language/locale (unlocked)

## Epic 2: Roles & Access Model

The CESFAM's group taxonomy exists and users are provisioned into it.

### Story 2.1: Provision the group registry

As an administrator,
I want the role/category/all-staff/team groups provisioned,
So that access can be granted per group.

**Acceptance Criteria:**

**Given** the `20-groups` phase
**When** `make seed` runs
**Then** all 21 `role-*` groups (per the registry IDs), the 4 `cat-*` groups, `all-staff`, and parameterizable `prog-*`/`sector-*` placeholders exist with Spanish display names

**Given** the taxonomy
**When** a new role group is added and granted access later
**Then** existing groups' access is undisturbed (extensible — FR-10)

**Given** the groups phase
**When** seed re-runs
**Then** group creation is idempotent (query-before-create)

### Story 2.2: User provisioning + multi-role membership

As an administrator,
I want to create users and assign one or more role groups,
So that people receive exactly their roles' access.

**Acceptance Criteria:**

**Given** the `50-users` phase
**When** seed runs
**Then** each user is placed into their `role-*`, their `cat-*`, `all-staff`, and any `prog-*`/`sector-*` teams (via `occ group:adduser`)

**Given** a user in two role groups
**When** access resolves
**Then** they receive the union of both roles' access and nothing more

**Given** a user removed from a group
**When** access re-resolves
**Then** exactly that group's access is revoked and the user remains in `all-staff`

## Epic 3: Document Home (Spine A)

The permissioned four-area tree with the first-cut access matrix. *(Builds on Epic 2.)*

### Story 3.1: Provision the four-area Group Folders tree

As an administrator,
I want the hybrid tree provisioned as Group Folders,
So that Spine A's structure exists.

**Acceptance Criteria:**

**Given** the `30-folders` phase
**When** `make seed` runs
**Then** Transversal is one Group Folder and each program/unit/sector is its own Group Folder (the mount model), matching the first-cut layout

**Given** Group Folders cannot nest
**When** the tree is created
**Then** no nested-group-folder assumption is used and a recorded folder-id map makes creation idempotent (no double-create on re-run)

### Story 3.2: Apply the first-cut access matrix

As a staff member,
I want each folder wired to my role groups,
So that I see and edit exactly what my role permits.

**Acceptance Criteria:**

**Given** the `40-acl` phase
**When** seed runs
**Then** each folder is granted to groups per the first-cut matrix using allow-refinement (least at base + explicit allows, and NO DENY rules)

**Given** a single-role Médico user
**When** they browse
**Then** they can read `Transversal/Protocolos` (not write) and cannot see `Unidades/Farmacia`; and the `role-estadistica-rem` user can manage `Unidades/Estadística-REM` while other non-Dirección roles cannot read it

**Given** every access grant
**When** audited
**Then** it targets a group, never an individual

### Story 3.3: Organization conventions

As a staff member,
I want documented organization conventions,
So that the structure stays tidy as content grows.

**Acceptance Criteria:**

**Given** the Document Home
**When** a user looks for guidance
**Then** a documented naming/placement rule set and a one-live-copy versioning norm are surfaced in-repo and in relevant folder READMEs

**Given** v1
**When** conventions are applied
**Then** enforcement is human-followed (no automated/AI auto-sorting)

## Epic 4: Live Collaborative Editing

Staff co-edit office documents live via the active office backend (Collabora or Euro-Office). *(Depends only on Epic 0's stack + office server.)*

### Story 4.1: In-browser office editing

As a staff member,
I want to open and edit office documents in the browser,
So that I stop emailing files around.

**Acceptance Criteria:**

**Given** a supported document in Nextcloud
**When** I open it
**Then** it launches in the active office backend's editor (Collabora or Euro-Office) against the running stack

**Given** the editor
**When** I create a new document
**Then** text, spreadsheet, and presentation documents can be created and edited in-browser

### Story 4.2: Concurrent co-editing

As a staff member,
I want to co-edit a document with colleagues live,
So that we work on one trusted version.

**Acceptance Criteria:**

**Given** two user sessions on the same document
**When** both edit simultaneously
**Then** changes converge with no lost update

**Given** co-editors in one document
**When** they edit
**Then** each sees the others' presence/cursors

### Story 4.3: OSS format support

As a staff member,
I want the common office formats supported without a paid license,
So that our existing files work.

**Acceptance Criteria:**

**Given** odt/docx, ods/xlsx, and odp/pptx files
**When** opened in Nextcloud
**Then** they open and save in-browser

**Given** the editing stack
**When** audited
**Then** it is OSS and self-hosted with no paid license
