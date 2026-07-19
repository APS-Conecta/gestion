# APS Conecta — Gestión

Internal management / intranet suite for a Chilean CESFAM (primary-healthcare centre), built as a
**white-label Nextcloud** deployment (official image, **no source fork**), self-hosted via Docker.

> **Status: 🚧 Building Epic 0 (Foundation).** The dev stack, debugger, quality gate, and provisioning
> framework are in place and run locally per developer. Branding, es-CL locale, roles/access, and the
> document-folder tree are **later epics** (see *Current state* below). No patient data — dev uses
> **synthetic fixtures only**.

## What this is (and isn't)

- **Is:** staff-facing internal operations (documents, coordination) on **Nextcloud 34 + PostgreSQL 18 +
  Redis 8**, run locally per developer via Docker Compose, with a switchable office suite (Collabora or
  Euro-Office).
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
   PostgreSQL passwords at minimum; `OFFICE_JWT_SECRET` if you'll trial Euro-Office — `openssl rand -hex 32`).
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
| `make office-collabora` / `make office-eurooffice` | Switch the office backend (exactly one active — AD-11). |
| `make office-down` | Stop both office backends. |

**Step-debugging:** `make up-dev`, then in VS Code run the committed **"Listen for Xdebug"** config
(`.vscode/launch.json`, port 9003) and send a request carrying the Xdebug trigger.

**Office suite:** `make office-collabora` (Collabora CODE, self-signed HTTPS on `:9980`) or
`make office-eurooffice` (Euro-Office). One at a time; each wires its own Nextcloud Office connector and
runs an editing smoke. For in-browser editing, accept Collabora's self-signed cert once at
`https://localhost:9980`.

## Where things live

| Path | What |
|---|---|
| `compose.yaml` | Core stack (nextcloud/db/redis) + office profiles (collabora/eurooffice). |
| `compose.dev.yaml`, `Dockerfile.dev`, `dev/xdebug.ini` | The derived Xdebug dev image (AD-10). |
| `.env.example` | Template for your gitignored `.env`. **Never commit `.env`.** |
| `Makefile` | The dev lifecycle (`make help`). |
| `scripts/` | `smoke.sh`, `test.sh`, `office-smoke.sh` — the gate + office checks. |
| `provisioning/` | The single idempotent provisioning writer: `seed.sh` runner, `lib.sh` guard helpers, `phases/10-60`, and [`provisioning/README.md`](provisioning/README.md). |
| `apps/`, `themes/` | Custom apps / theming, live-mounted (arrives in Story 0.8). |
| `docs/planning/` | Committed SSOT: brief, PRD, architecture, epics, stories, sprint status. |
| `docs/ARCHITECTURE.md` | The architecture overview (spine in `docs/planning/architecture/…`). |

## Current state (what `make seed` provisions today)

Config-as-code is applied only by `make seed`, in fixed phase order (`provisioning/README.md`). **Done:**
the provisioning framework + guard helpers, and the **fixtures** (synthetic users + a sample file, phases
50–60). **Pending later epics — still no-op stubs:** `10-branding` (APS Conecta branding + **es-CL locale**,
Epic 1), `20-groups` (role/team registry, Epic 2), `30-folders`/`40-acl` (document tree + access, Epic 3).
So a freshly-seeded instance has sample users but **not yet** branding, Spanish locale, roles, or the folder
structure — those land as their epics fill their phase file.

## Contributing & conventions

See [`CONTRIBUTING.md`](CONTRIBUTING.md) — GitHub Flow + the PR review gate, principles
(DRY/SOLID/YAGNI), the language split (**code in English, UI in Spanish**), and the documentation rules.

## How we build it

Driven by the **standard BMad Method** (v6.10.0). Planning artifacts are the committed **single source of
truth** under [`docs/planning/`](docs/planning/); architecture in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Start with the `bmad-help` skill to see the next step.

## Reference docs (pulled live via Context7 MCP — never hardcode)

| Topic | Context7 library ID |
|---|---|
| Nextcloud admin / deploy | `/websites/nextcloud_server_admin_manual` |
| Nextcloud app development | `/websites/nextcloud_server_developer_manual` |
| Nextcloud PHP / OCP API | `/websites/nextcloud-server_netlify_app` |
| Nextcloud Vue UI kit | `/nextcloud-libraries/nextcloud-vue` |
| BMad Method (full) | https://docs.bmad-method.org/llms-full.txt |
