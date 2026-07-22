---
title: "Product Brief — APS Conecta Gestión"
status: ready
created: 2026-07-18
updated: 2026-07-18
---

# Product Brief: APS Conecta — Gestión

> **Status: ready.** The WHAT for the APS Conecta Gestión rebuild — feeds the PRD (the HOW).

**Naming & brand.** *APS Conecta* is the umbrella **brand/project**; ***APS Conecta Gestión*** is **this
app** — the management app. The white-label Nextcloud carries the **APS Conecta** brand, and future sibling
apps may live under it.

## Executive Summary

APS Conecta — Gestión is the **centralized, secure intranet for a Chilean CESFAM's clinical and
management staff**. Today the CESFAM's information lives in scattered **Excel, Word, and PowerPoint files**
across WhatsApp, email, pendrives, and Google Drive — the management/communication chain is broken,
nothing is live-editable, and data is lost. Built white-label on **Nextcloud (Hub)**, Gestión does two
things: (1) gives documents a secure, permissioned, **live-collaborative** home; and (2) — the core bet —
turns the CESFAM's own data into a **structured, searchable database** that can be **analyzed** and used
to **run processes** (gestionar procesos), instead of one-off office files. It deliberately is **not** an
HR, finance, or shift/absence system. First delivery is a **live pilot at a real CESFAM**.

## The Problem

The management/communication chain is broken. Information lives on **WhatsApp, email, pendrives, folders,
Google Drive** — every file and datum in **its own Excel / Word / PowerPoint**. No live editing; no single
trusted version; data is **unstructured and unsearchable**, so it can't be analyzed or used to drive
processes. For a CESFAM, that doesn't work.

## The Solution

A white-label **Nextcloud Hub** as the single secure home, on two tracks:

**A. Documents (mostly vanilla Nextcloud — Layer 1).** Files + **Collabora / Nextcloud Office** for live
editing, organized in a **permissioned** folder/group structure with **role-differentiated access**. Plus
a set of **organization rules/conventions** to keep it tidy (and, later, an **AI workflow to auto-sort and
organize** documents).

**B. Structured, searchable data (the core bet).** The CESFAM's own data as a **structured, searchable
database**, analyzable and process-driving. Assembled from complementary pieces:
- **Nextcloud Tables** — structured rows/fields (one piece, not the whole thing).
- **Full-text search** — findable content (needs a search backend).
- **Nextcloud Analytics** (candidate) — dashboards/reporting over the data.
- **Paperless-ngx** (candidate) — turn PDFs into **searchable, structured, interpretable** data (OCR →
  vectors), feeding the database. Enables things like *"when do protocols expire?"* and *"what
  errors/inconsistencies exist across protocols on cross-reference?"* (interpretation = AI, later).
- **REM analysis** — the **first real custom app** (Layer 2, did not exist before; relates to the
  existing `rem-analyzer`). The sharp end of "deterministic data for analytics."

Process areas served: protocolos, flujogramas/workflows, actas de reuniones, documentación, registro de
redes, análisis de REM, datos estadísticos, gestión de programas (cardiovascular, ECICEP), reporte de
datos, análisis de problemas.

## Who This Serves

CESFAM staff with **differentiated roles and access**: **Dirección, Subdirección, SOME, Jefaturas,
Médicos, Matronas, TENS, Administrativos, Farmacia.** Deployed as a **live pilot at a real CESFAM**.

## Success Criteria

**Milestone 1 — Foundation (first success, = Epic 0).** The complete repo + **Nextcloud 34 Docker image**
+ installation exist and run, set up so the **3 devs can read and work on apps and code** (build, run,
debug, test the environment locally). This is the first definition of success.

**Milestone 2 — Documents pilot (Spine A).** A white-label Nextcloud where CESFAM staff keep protocolos,
actas, and documentación in **one secure, permissioned place** with **role-based access** and **live
collaborative editing** (Collabora / NC Office) — and actually use it there instead of WhatsApp,
pendrives, and Google Drive. Success = staff adoption for real documents during the live pilot.

## Scope

**In (v1):**
1. **Foundation (Epic 0):** complete repo + Nextcloud 34 Docker image + install + local dev environment
   (read/build/run/debug/test apps and code).
2. **Spine A — documents:** vanilla Nextcloud + **Collabora / NC Office** live editing + **role-based
   access** + an organized, permissioned folder/group structure. That is the whole pilot feature set.

**Later (roadmap — built as Nextcloud official apps, custom apps, or workflows, one at a time):**
Nextcloud **Tables** (structured registries) → **REM app** (first custom Layer-2 app) → **full-text
search** → **Paperless-ngx** (PDF→searchable/vector) → **Analytics/reporting** → **AI layer** (local
models: auto-organize docs, protocol-expiry alerts, cross-reference error detection, program analysis).

**Out (explicit non-goals):** turnos, ausencias, financial administration, enterprise HR/RRHH. Process &
knowledge management, not operations/admin.

## Cross-cutting requirements

- **GitHub is the project SSOT:** the repository holds **all project structure, documentation** (planning,
  architecture, onboarding, license outline) **and manages developer access/collaboration**. Repo-first
  (repo canonical); everything the 3 devs need to read and work lives there. *(Distinct from the product's
  content — the CESFAM's documents and data live in Nextcloud, not GitHub.)*
- **Role-based access control** across files and apps.
- **OSS-first, self-hosted, free, license-clear:** most (ideally all) components are **open-source and
  self-hosted** — **no paid licenses**. Prefer the **most open/permissive licenses that allow free
  modification**; where a core component is copyleft (Nextcloud = AGPL, Paperless-ngx = GPL) that is
  accepted for self-hosting. An **explicit license outline** across all apps, code, stacks, and
  dependencies is a committed SSOT artifact.
- **Language:** final users are **Spanish speakers** — **all user-facing UI in Spanish (es-CL)**; all
  **code, backend, identifiers, and technical artifacts in English**, consistently.
- **AI layer — deferred (roadmap), an AI *assistant*:** for **gestión de procesos**, **ordenar
  documentos**, and **análisis y cruce de datos** — running **local models on the CESFAM's own data** to
  keep it secure. Governed by a rules set; functionality **expands over time**. Not in v1.

## Legal & Localization (Chile)

The suite serves a **Chilean CESFAM** — data, money, dates, and all formats are **Chilean (South
America)**. This is a first-class, tracked concern with its own committed **Legal** SSOT artifact.

- **Locale/formats:** Spanish `es-CL`; timezone **America/Santiago**; currency **CLP ($)**; Chilean date,
  number, and identifier formats (e.g. **RUT**).
- **Schedules:** cron jobs, deadlines, and reporting cycles aligned to the Chilean calendar (working days,
  feriados) and timezone.
- **Legal compliance:** Chilean law on data protection and security (e.g. **Ley 19.628** and the newer
  **Ley 21.719**), plus any primary-health / MINSAL requirements relevant to internal ops. A **Legal
  compliance checklist** is maintained and reviewed when features touch data, formats, or scheduling.
- **Standards fit:** REM and program formats follow Chilean primary-care (APS/MINSAL) conventions.

## Vision

A CESFAM whose knowledge and processes live in one secure, **structured, searchable** place — where an
**AI layer running locally on the CESFAM's own data** auto-organizes documents, flags expiring protocols,
finds cross-reference errors, and assists program analysis.
