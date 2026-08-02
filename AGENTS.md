# AGENTS.md — APS Conecta Gestión (canonical repo rules)

Rules for any AI agent (e.g. Claude Code) working in this repo. `CLAUDE.md` imports this file.

## What this project is

White-label **Nextcloud 34** suite (internal ops for a Chilean CESFAM), official Docker image — **never a
Nextcloud source fork**. Stack: Nextcloud + **PostgreSQL** + **Redis** + a `cron` container for background
jobs + the **Euro-Office** document server (not opt-in since #81; see `docs/ARCHITECTURE.md` § Stack).
Internal ops only, **no patient data**.

## How we work

- **Design SSOT:** architecture in `docs/ARCHITECTURE.md`; the code (`provisioning/phases/`,
  `compose.yaml`) is authoritative for behavior. Repo-first SSOT (repo wins; any wiki mirrors).
- **Principles:** DRY · SOLID · KISS/YAGNI (ponytail — minimal, delete over add). Defined here; `CONTRIBUTING.md` is the operational contract (workflow, docs rules, secrets handling).
- **Language split:** code/backend/docs in **English**; user-facing UI in **Spanish**. Deliberately
  Spanish: `docs/CONVENTIONS.md` (staff-facing), `docs/BRANDING.md` and `themes/apsconecta/MAPEO.md`
  (authored with the brand kit).
- **Coordination:** GitHub Flow, PR + 1 approval (convention gate), private repo. Conventional Commits.

## Invariants

- **Portability:** the dev stack must run on any dev's machine (local Docker). Nothing VPS-specific
  (Tailscale, absolute paths) in the core compose. `host.docker.internal` must work cross-OS.
- **Secrets/data:** never commit `.env`, secrets, real data, or Docker volumes. Synthetic dev fixtures only.
- **Custom code** lives in `apps/` (→ `custom_apps`) and `themes/`, bind-mounted for live edit. Xdebug is a
  **derived dev-only image**, not a fork.

## Do not touch (sibling projects on the same host)

`/srv/syncthing/CESFAMS` and co-located tenants (Jomy, mailcow, glitchtip, coolify, homepage, syncthing).
This repo is self-contained under its own clone.
