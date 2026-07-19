# APS Conecta — Gestión

Internal management / intranet suite for a Chilean CESFAM (primary-healthcare centre), built as a
**white-label Nextcloud** deployment (official image, **no source fork**), self-hosted via Docker.

> **Status: 🚧 Planning → Build.** Repository foundation in place; dev-stack boot-checked on Nextcloud 34.
> The **product brief**, **PRD (v1)**, **architecture**, and **epics & stories** are done — v1 is the
> *developer-facing* Foundation (Epic 0) + the initial Spine A document structure the devs build on.
> **Implementation of Epic 0 (Foundation & Dev Environment) is next.** See
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/planning/epics.md`](docs/planning/epics.md),
> [`ROADMAP.md`](ROADMAP.md).

## What this is (and isn't)

- **Is:** staff-facing internal operations (documents, coordination, announcements) on Nextcloud 34 +
  PostgreSQL + Redis, run locally per developer via Docker Compose.
- **Isn't:** a clinical/patient-records system. **No patient data** — dev uses **synthetic fixtures only**.

## How we build it

Driven by the **standard BMad Method** (v6.10.0). Planning artifacts are the committed **single source of
truth** under [`docs/planning/`](docs/planning/); architecture lands in `docs/ARCHITECTURE.md`. Start with
the `bmad-help` skill to see the next step.

The **local dev/debug environment** (Docker Compose + Xdebug + VS Code config + `make` targets) is
delivered as **Epic 0 (Foundation)** — the onboarding quickstart appears here once that lands.

## Contributing & conventions

See [`CONTRIBUTING.md`](CONTRIBUTING.md) — branching, review gate, principles (DRY/SOLID/YAGNI), the
language split (**code in English, UI in Spanish**), and the documentation references.

## Reference docs (pulled live via Context7 MCP — never hardcode)

| Topic | Context7 library ID |
|---|---|
| Nextcloud admin / deploy | `/websites/nextcloud_server_admin_manual` |
| Nextcloud app development | `/websites/nextcloud_server_developer_manual` |
| Nextcloud PHP / OCP API | `/websites/nextcloud-server_netlify_app` |
| Nextcloud Vue UI kit | `/nextcloud-libraries/nextcloud-vue` |
| BMad Method (full) | https://docs.bmad-method.org/llms-full.txt |
