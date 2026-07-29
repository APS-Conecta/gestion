# APS Conecta — Gestión

Internal management / intranet suite for a Chilean CESFAM (primary-healthcare centre), built as a
**white-label Nextcloud** deployment (official image, **no source fork**), self-hosted via Docker.

> **Status: ✅ v1 done (Foundation + Spine A).** Epics 0–4 are merged — dev stack + debugger +
> quality gate + provisioning, es-CL locale, roles/access, the four-area document
> tree, and live office editing — and the browser acceptance run passed on **2026-07-24**
> (see *Current state* below). No patient data — dev uses **synthetic fixtures only**.

## What this is (and isn't)

- **Is:** staff-facing internal operations (documents, coordination) on **Nextcloud 34 + PostgreSQL 18 +
  Redis 8**, run locally per developer via Docker Compose, with a self-hosted **Euro-Office** office suite.
- **Isn't:** a clinical/patient-records system. **No patient data** — dev uses **synthetic fixtures only**.

## Quickstart

Everything below was run on a clean checkout; each step names where it runs and how to know it worked.
**Prerequisites:** Docker Engine 24+ with Compose v2, `make`, and `git`. All commands run on the **host**
from the repo root unless noted.

1. **Clone and enter the repo.**
   ```bash
   git clone git@github.com:APS-Conecta/gestion.git apsconecta-gestion
   cd apsconecta-gestion
   ```

2. **Create your local env file** (gitignored — never committed).
   ```bash
   cp .env.example .env
   ```
   Then **edit `.env`** and replace every `change-me…` placeholder with your own dev values (admin +
   PostgreSQL passwords at minimum; `OFFICE_JWT_SECRET` if you'll run Euro-Office — `openssl rand -hex 32`).
   *The stack boots with the placeholders, but don't leave real deployments on them.*

3. **Start the core stack** (services only — no provisioning, per AD-2).
   ```bash
   make up
   ```
   *Expected:* `db`, `redis`, then `nextcloud` start; on **first boot** the official image auto-installs
   Nextcloud from your `.env` (admin + DB vars). This takes **~1–2 minutes** the first time.
   *If it errors* `No .env found` — you skipped step 2.

4. **Wait until it's ready, then verify.** The HTTP surface comes up a little **after** the install
   finishes, so give it a moment:
   ```bash
   make smoke
   ```
   *Expected:* `PASS: core stack healthy — installed, PostgreSQL ready, Redis PONG, /status.php 200`.
   *If it FAILs right after `make up`* the container is still warming up (`docker compose ps` shows
   nextcloud `health: starting`) — wait until it shows `(healthy)` and re-run. First boot only.

5. **Open the app.**
   Browse to **`http://localhost:8180`** (the `HTTP_PORT` from your `.env`) and sign in with the
   `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` you set. You now have a running instance.

6. **(Optional) Seed synthetic dev data.**
   ```bash
   make seed
   ```
   *Expected:* creates ~4 clearly-synthetic sample users (`dev.*`, "(fixture)") + a sample file,
   idempotently. Re-running never duplicates. No real data, ever.

To stop: `make down` (keeps your data volumes). That's the whole loop.

## Make targets

`make help` is the authoritative list (it reads the Makefile). The ones you'll use:

| Target | What it does |
|---|---|
| `make up` | Start the core stack (services only — no seeding). |
| `make up-dev` | Start with the **Xdebug** derived dev image (step-debugging on port 9003). |
| `make down` | Stop the stack (keeps volumes). |
| `make seed` | Run the idempotent provisioning pipeline (`provisioning/`). |
| `make smoke` | Health-gate the running stack (0 = healthy). |
| `make test` | Local quality gate — static checks + smoke (the CI stand-in). |
| `make office-eurooffice` | Bring up the Euro-Office backend and wire the connector (AD-5). |
| `make office-formats` | Audit the backend: OSS/no-paid-license (Epic 4). |
| `make office-down` | Stop the office backend. |

**Step-debugging:** `make up-dev`, then in VS Code run the committed **"Listen for Xdebug"** config
(`.vscode/launch.json`, port 9003) and send a request carrying the Xdebug trigger.

**Office suite:** `make office-eurooffice` brings up Euro-Office, wires the Nextcloud Office connector, and
runs an editing smoke. `make office-formats` then audits the backend (OSS/no paid license).

**Live editing acceptance (Epic 4) — done.** Run in a browser on **2026-07-24** (issue #30, since closed;
the standing runbook `docs/ACCEPTANCE-EDITING.md` was retired with it). In-browser render, create/edit/save
round-trip, live co-editing convergence and cursor presence all passed; edits were confirmed inside the
*stored* file bytes, not just on screen. `make office-smoke` and `make office-formats` remain the machine
gate for the pipe and the OSS/no-paid-licence claim.

**Which formats you can actually edit.** OOXML — `docx`, `xlsx`, `pptx` — opens and edits normally.
**ODF — `odt`, `ods`, `odp` — opens and renders correctly but is view-only**: the connector declares those
`lossy-edit`/`auto-convert` rather than `edit`, so it will not edit them in place. Use *Archivo → Guardar
copia como* to convert to OOXML first. Whether to enable lossy ODF editing is an open decision — issue #45.

## Where things live

| Path | What |
|---|---|
| `compose.yaml` | Core stack (nextcloud/db/redis) + the `eurooffice` office profile. |
| `compose.dev.yaml`, `Dockerfile.dev`, `dev/xdebug.ini` | The derived Xdebug dev image (AD-10). |
| `.env.example` | Template for your gitignored `.env`. **Never commit `.env`.** |
| `Makefile` | The dev lifecycle (`make help`). |
| `scripts/` | `smoke.sh`, `test.sh`, `office-smoke.sh`, `office-formats.sh` — the gate + office checks. |
| `provisioning/` | The single idempotent provisioning writer: `seed.sh` runner, `lib.sh` guard helpers, `phases/10-60`, and [`provisioning/README.md`](provisioning/README.md). |
| `apps/`, `themes/` | Custom apps / theming, live-mounted (v1 ships none — the Layer-2 seam). |
| `docs/ARCHITECTURE.md` | The architecture overview (design SSOT). |
| `ROADMAP.md` · `BUGS.md` | Roadmap narrative · known bugs. Work in progress is on the [Projects board](https://github.com/orgs/APS-Conecta/projects/5). |
| `LICENSE` · [`docs/LICENSING.md`](docs/LICENSING.md) | Our code's license (proprietary) · full third-party license audit. |
| `CONTRIBUTING.md` · `AGENTS.md` · `CONTRIBUTORS.md` | Contribution rules + how we track work · AI-agent invariants · the team. |
| `.github/` | `CODEOWNERS`, PR + issue templates, `SECURITY.md`. |

## Current state (what `make seed` provisions today)

Config-as-code is applied only by `make seed`, in fixed phase order (`provisioning/README.md`). As of v1
(Epics 0–4 merged), a full `make seed` applies **es-CL locale** (phase 10), the **role/team group
registry** (phase 20), the **four-area Document Home tree + first-cut access matrix** (phases 30–40), and
synthetic **fixture users + a sample file** (phases 50–60). White-label branding is not applied in v1 —
the instance runs the default Nextcloud theme. Live collaborative editing is native to the office backend
(`make office-eurooffice`).
The browser acceptance run passed on 2026-07-24, so v1 is complete; ODF is view-only (see *Office suite*
above).

## Developing — how to implement a feature

The paradigm is **vanilla Nextcloud + configuration-as-code, no fork**: the platform owns runtime and data;
this repo adds only *declarative* customization (config, theming, groups/folders/ACLs) — **no core patch,
zero custom PHP in v1** — and the running instance is a disposable *projection* of the repo's recipe. **The
only thing that changes instance state is `make seed`** — one idempotent `occ` script (AD-2). Never hand-click
configuration into the running app; if it isn't scripted, it isn't real.

### The loop

1. `make up` (or `make up-dev` for Xdebug on `:9003`) — start services. Proves the stack boots.
2. Edit the recipe — a `provisioning/phases/NN-*.sh`, or `apps/` / `themes/`, or `.env`.
3. `make seed` — apply desired state. Idempotent: safe to re-run; it converges. (`SEED_FIXTURES=0 make seed`
   applies structure only, skipping the fixture phases.)
4. `make smoke` / `make test` — health-gate + the local quality gate (the CI stand-in). Green before a PR.
5. Open a PR — see [`CONTRIBUTING.md`](CONTRIBUTING.md) (GitHub Flow, Conventional Commits, `ai-assisted`, 1
   approval); work is tracked on the [Projects board](https://github.com/orgs/APS-Conecta/projects/5).

### A feature = one provisioning phase

Features are applied by numbered scripts in `provisioning/phases/`, run in **fixed order 10 → 60** by
`make seed` (structure 10–40 before fixtures 50–60). **One epic owns one file** (see each file's `# OWNER:`
header) — a new epic adds its own `NN-*.sh` at the right position and `seed.sh` picks it up automatically (it
globs + sorts `phases/[0-9]*.sh`); no central registration, so parallel epics never collide.

Each phase is framed by `phase_begin "NN-name" "…"` … `phase_end`, and its body uses only the
**query-before-create guard helpers** in `provisioning/lib.sh`, so re-running converges instead of duplicating
— e.g. `config_system_set`, `ensure_group`, `ensure_user`, `ensure_app`,
`ensure_groupfolder`, `gf_grant`, `ensure_gf_file`. **Never blind-create.** Verify by re-running `make seed`
(every line should log "exists" / "already =") then `make test`. Full helper list + the contract:
[`provisioning/README.md`](provisioning/README.md).

### Custom apps & themes

`apps/` (→ `custom_apps`) and `themes/` are **bind-mounted for live edit** — no rebuild, no fork; `make up`
runs `make fix-mount-perms` so the container (uid 33) can write them. A custom app talks to Nextcloud **only
through OCP public APIs (`OCP\…`)** — never patch core (AD-9) — carries an `appinfo/info.xml`
(`min-version="34"`), and is enabled with `occ app:enable <id>`. **v1 ships none** (config-as-code only); these
dirs are the Layer-2 roadmap seam (e.g. the REM app). White-labeling ships as the **`themes/apsconecta/`
server theme** — AD-6's config-only rule is superseded by
[ADR-0001](docs/adr/0001-server-theme-for-branding.md). How the theming actually behaves (and why most of
it is config rather than CSS) is [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md); the deploy guide is
[`docs/BRANDING.md`](docs/BRANDING.md). Locale stays in the `10-locale` phase.

### The office backend

`make office-eurooffice` brings up Euro-Office (AD-5), wires its connector, and runs an editing smoke.
`make office-formats` audits the backend.

### Guardrails you must not break

Defined once in [`AGENTS.md`](AGENTS.md) (the invariants) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
(the design paradigm). Read them before you touch the stack.

## Contributing & conventions

See [`CONTRIBUTING.md`](CONTRIBUTING.md) — GitHub Flow + the PR review gate, principles
(DRY/SOLID/YAGNI), the language split (**code in English, UI in Spanish**), and the documentation rules.

## How we build it

The committed **single source of truth** for the design is [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
(the architecture overview); the code itself (`provisioning/phases/`, `compose.yaml`) is authoritative for
behavior. Status narrative lives in [`ROADMAP.md`](ROADMAP.md).

## Reference docs (pulled live via Context7 MCP — never hardcode)

| Topic | Context7 library ID |
|---|---|
| Nextcloud admin / deploy | `/websites/nextcloud_server_admin_manual` |
| Nextcloud app development | `/websites/nextcloud_server_developer_manual` |
| Nextcloud PHP / OCP API | `/websites/nextcloud-server_netlify_app` |
| Nextcloud Vue UI kit | `/nextcloud-libraries/nextcloud-vue` |
