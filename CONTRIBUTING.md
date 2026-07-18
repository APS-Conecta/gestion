# Contributing — APS Conecta Gestión

Three developers collaborate here. This file is the operational contract; keep it current.

## Principles (non-negotiable)

- **DRY** — one source per fact/behaviour, no duplication.
- **SOLID** — single responsibility, clear boundaries, decoupled, self-documenting.
- **KISS + YAGNI (ponytail)** — the simplest thing that works; delete over add; no speculative abstraction.
- **Language split** — **code, backend, identifiers, comments, and these docs in English**; **all
  user-facing UI text in Spanish** (`es`, Chile).
- **Data** — internal ops only, **no patient/clinical data**. Dev uses **synthetic fixtures only**; real
  data and secrets never enter git, Docker volumes, or Syncthing.

## Workflow (GitHub Flow)

1. Branch off `main` (short-lived): `feat/…`, `fix/…`, `docs/…`, `chore/…`.
2. Commit with **Conventional Commits** (`feat:`, `fix:`, `docs:`, `chore:`, `test:`…).
3. Open a PR → **1 human approval required** before merge. This gate is by **team convention** (GitHub
   free plan does not enforce branch protection on private repos) — respect it.
4. AI-assisted PRs must be **labeled** and disclose AI involvement in the description.
5. CI is deferred; the gate is local `make test` + `make smoke` (arrives with Epic 0).

`CODEOWNERS` auto-requests reviewers. Prefer small, reviewable PRs.

## Planning (BMad Method)

Planning is driven by the **standard BMad Method**; run the `bmad-help` skill to find the next step.
All artifacts are committed under `docs/planning/` — the repo is the SSOT, GitHub is its mirror. BMad runs
via Claude Code; `.claude/skills/` is regenerable (`bmad install`) and gitignored.

## Local dev environment

> **Delivered in Epic 0 (Foundation).** Portable, machine-agnostic Docker Compose (Nextcloud 33 +
> PostgreSQL + Redis) with Xdebug + VS Code config + a `Makefile`. Each dev runs it **locally**. The
> quickstart (`clone → cp .env.example .env → make up → http://localhost:${HTTP_PORT}`) and per-OS notes
> land here once that epic ships.

## Reference docs

Pull current docs from **Context7 MCP** (never hardcode) — see the table in [`README.md`](README.md).
