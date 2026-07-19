# Contributing — APS Conecta Gestión

A three-person team collaborates here — an owner (product, requirements, UAT sign-off) and two developers
(see [`CONTRIBUTORS.md`](CONTRIBUTORS.md)). This file is the operational contract; keep it current.

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
4. AI-assisted PRs must be **labeled** (`ai-assisted`) and disclose AI involvement in the description.
5. CI is deferred; the gate is **local `make test`** (static checks + smoke) — run it before opening a PR.

`CODEOWNERS` auto-requests reviewers. Prefer small, reviewable PRs.

## Planning (BMad Method)

Planning is driven by the **standard BMad Method**; run the `bmad-help` skill to find the next step.
All artifacts are committed under `docs/planning/` — the repo is the SSOT, GitHub is its mirror. BMad runs
via Claude Code; `.claude/skills/` is regenerable (`bmad install`) and gitignored.

## Local dev environment

Portable, machine-agnostic Docker Compose (Nextcloud 34 + PostgreSQL 18 + Redis 8) with Xdebug, VS Code
config, and a `Makefile`; each dev runs it **locally**. The step-by-step quickstart and the full `make`
reference live in **[`README.md`](README.md#quickstart)** — one owner per fact; don't duplicate them here.
Two invariants when you touch the stack: nothing VPS-specific or absolute-pathed in the core compose
(`host.docker.internal` must work cross-OS), and **all desired state goes through `make seed`** — never
hand-click config into the running instance (AD-2).

**Secrets:** all passwords live in your gitignored `.env` (copy from `.env.example`). For a single
readable sheet of every stack credential (Nextcloud admin, PostgreSQL, Collabora, Euro-Office JWT, fixture
users), run **`make credentials`** → writes `CREDENTIALS.local.md` (gitignored, mode 600, generated from
`.env` — never hand-edit; re-run after a rotation). Never commit `.env` or that file.

## Documentation rules

Docs must let someone **rebuild** the system, not just read about it. When you write or change a doc:

1. **Numbered steps, one action each** — the exact copyable command.
2. **Every step states its expected output and what to do if it fails.** A step you can't verify isn't one.
3. **Every command says where it runs** — host, or which container and as which user.
4. **Never assert what you haven't run.** If it's untested, the doc says so *there*, not in a preface.
5. **One owner per fact.** Others link; they don't repeat. A second copy desyncs the day it's written.
6. **Prefer generated over hand-written** (e.g. `make help` is the target list; don't copy it).
7. **Don't copy a gate's count into prose** — say what the gate *proves*; let it print the number.

And the guard that keeps it honest: **if a doc mentions something retired, it must acknowledge somewhere that
it is** (dated history — ADRs, changelogs — is exempt; its date is the label).

## Reference docs

Pull current docs from **Context7 MCP** (never hardcode) — see the table in [`README.md`](README.md).
