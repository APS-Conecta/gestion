# AGENTS.md — APS Conecta Gestión (canonical repo rules)

Rules for any AI agent (e.g. Claude Code) working in this repo. `CLAUDE.md` imports this file.

## What this project is

White-label **Nextcloud 34** suite for Chilean CESFAMs — internal ops, one establishment per install,
named in that install's configuration and never in the product. Official Docker image, **never a
Nextcloud source fork**. Stack: Nextcloud + **PostgreSQL** + **Redis** + a `cron` container for background
jobs + the **Euro-Office** document server (not opt-in since #81; see `docs/ARCHITECTURE.md` § Stack).
Internal ops only, **no patient data**.

## How we work

- **Design SSOT:** architecture in `docs/ARCHITECTURE.md`; the code (`provisioning/phases/`,
  `compose.yaml`) is authoritative for behavior. Repo-first SSOT (repo wins; any wiki mirrors).
- **Principles:** DRY · SOLID · KISS/YAGNI (ponytail — minimal, delete over add). Defined here; `CONTRIBUTING.md` is the operational contract (workflow, docs rules, secrets handling).
- **Language split:** code/backend/docs in **English**; user-facing UI in **Spanish**. A doc is
  Spanish only when its reader is, or when Spanish is its subject: `docs/CONVENTIONS.md` (clinic
  staff read it) and [analizador-rem's `docs/GLOSARIO.md`](https://github.com/APS-Conecta/analizador-rem/blob/main/docs/GLOSARIO.md)
  (a glossary *of* Spanish domain terms). `docs/BRANDING.md`
  and `themes/apsconecta/MAPEO.md` were exempt as "authored with the brand kit" and were translated
  on 2026-08-09: both are read by whoever deploys or edits the theme, which is a developer.
- **Coordination:** GitHub Flow, PR + 1 approval (convention gate), private repo. Conventional Commits.
  `main` is the trunk; a **release is a tag**, and a clinic installs from one (ADR-0005).

## How we write

- Code, comments, docs and commits in English. UI text in Spanish.
- A comment gives the rule and the reason, once. If it is longer than the code it guards, cut it.
- No comment repeats the code. No comment restates a doc — link the doc.
- Plans and instructions are numbered steps, one action per step.

## Invariants

- **Portability:** the dev stack must run on any dev's machine (local Docker). Nothing VPS-specific
  (Tailscale, absolute paths) in the core compose. `host.docker.internal` must work cross-OS.
- **Secrets/data:** never commit `.env`, secrets, real data, or Docker volumes. Synthetic dev fixtures only.
  The rule covers the **whole working root**, not only what git tracks — an identifiable clinical
  extract sitting beside the clones is exposure whether or not it was committed, and
  `repo-docs/config.json` aims the documentation audit at that root, so "not in git" is not a
  boundary. Real extracts, credentials and `.env` copies belong **outside** the root entirely.
  Every "no patient data" claim in this repository is a claim about the software and its
  repositories; it says nothing about a developer's own working directory, and must not be read as
  if it did.
- **Custom code** lives in `apps/` (→ `custom_apps`) and `themes/`, bind-mounted for live edit. Xdebug is a
  **derived dev-only image**, not a fork.

## Do not touch (sibling projects on the same host)

`/srv/syncthing/CESFAMS` and co-located tenants (Jomy, mailcow, glitchtip, coolify, homepage, syncthing).
This repo is self-contained under its own clone.
