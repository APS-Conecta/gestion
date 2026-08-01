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
   Leave `SITE` for step 3 — it names the clinic this stack serves.

3. **Choose your CESFAM.** One clinic ships as a working reference: **CESFAM Los Castaños**, in
   `sites/los-castanos/site.sh`. To run it as-is, set `SITE=los-castanos` in `.env` and skip to step 4.

   For any *other* clinic, the DEIS register ships too and you pick from it:
   ```bash
   scripts/deis.py cesfam "la florida"        # search: type, comuna, name — accent-blind
   scripts/deis.py 114302 --new mi-cesfam     # writes sites/mi-cesfam/site.sh
   ```
   *Expected:* the second command asks for your **sectors** and **programs** — one per line, blank
   line to finish — because no register knows them. Then set `SITE=mi-cesfam` in `.env`.
   Everything else about the clinic (folders, the access matrix) is in that file, and it is yours to
   edit.

   *If you skip this*, `make install` stops before starting anything. It prints the two commands
   above when `SITE` names a clinic that has no `sites/<slug>/site.sh`; when `SITE` is unset
   entirely it points you back at `.env`, which is this step's other half.

4. **Install it.** One command: it starts the stack, waits for Nextcloud's own installer to finish,
   provisions everything, and health-checks the result.
   ```bash
   make install
   ```
   *Expected:* one line per phase, then a summary naming your clinic and its counts:
   ```
   ▸ stack
   ▸ provisioning — full log: .install.log
       security
       jobs
       …
   ✓ CESFAM Los Castaños — 7 teams, 14 group folders, 29 grants
     health: PASS
     http://localhost:8180
   ```
   **Run it again** whenever you edit `sites/<slug>/site.sh` or `git pull` — it converges, and
   everything already applied is skipped in seconds. It deliberately does **not** move the Nextcloud
   image or app versions; those stay separate, deliberate acts.
   *If a phase fails*, the last 20 log lines are printed and the whole command is the retry.

5. **Open the app.**
   Browse to **`http://localhost:8180`** (the `HTTP_PORT` from your `.env`) and sign in with the
   `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` you set. You now have a running instance.

To stop: `make down` (keeps your data volumes). That's the whole loop.

## Make targets

Run **`make help`** — it reads the Makefile, so it cannot drift. (A hand-copied table used to live
here and had already lost four targets.)

**Step-debugging:** `make up-dev`, then in VS Code run the committed **"Listen for Xdebug"** config
(`.vscode/launch.json`, port 9003) and send a request carrying the Xdebug trigger.

**Office suite:** `make office-eurooffice` brings up Euro-Office, wires the Nextcloud Office connector, and
runs an editing smoke that also audits the image (OSS, no paid licence).

**Live editing acceptance (Epic 4) — done.** Run in a browser on **2026-07-24** (issue #30, since closed;
the standing runbook `docs/ACCEPTANCE-EDITING.md` was retired with it). In-browser render, create/edit/save
round-trip, live co-editing convergence and cursor presence all passed; edits were confirmed inside the
*stored* file bytes, not just on screen. `make office-smoke` remains the machine
gate for the pipe and the OSS/no-paid-licence claim.

**Which formats you can actually edit.** OOXML — `docx`, `xlsx`, `pptx` — opens and edits normally.
**ODF — `odt`, `ods`, `odp` — is editable too, through conversion, so expect some formatting loss on
save**: the connector declares those `lossy-edit` rather than `edit`. Enabled deliberately (#45,
B-007) because the alternative — converting to `.docx` by hand — loses the same fidelity and leaves a
duplicate file behind, which [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) § *Una sola copia viva*
exists to prevent. Set by `provisioning/phases/14-office.sh`, never in the admin UI (AD-2).

## Where things live

| Path | What |
|---|---|
| `compose.yaml` | Core stack (nextcloud/db/redis/cron) + the `eurooffice` office profile. |
| `compose.dev.yaml`, `Dockerfile.dev`, `dev/xdebug.ini` | The derived Xdebug dev image (AD-10). |
| `.env.example` | Template for your gitignored `.env`. **Never commit `.env`.** |
| `Makefile` | The dev lifecycle (`make help`). |
| `scripts/` | `install.sh` (the one command) + `wait-ready.sh`, `test.sh` + `smoke.sh` (the gate), `seed-idempotent.sh`, `office-smoke.sh`, `deis.py`, and `env.sh` (shared preamble). |
| `provisioning/` | The single idempotent provisioning writer: `seed.sh` runner, `lib.sh` guard helpers, `phases/05-60`, `apps/` (per-app patches — [ADR-0002](docs/adr/0002-app-patches.md)), and [`provisioning/README.md`](provisioning/README.md). |
| `sites/` | One `<slug>/site.sh` per CESFAM — its teams, folders, ACL matrix and identity — plus the DEIS register they are picked from. **No clinic is committed** — you write yours with `scripts/deis.py`. |
| `apps/`, `themes/` | Live-mounted. `apps/` holds store-installed apps, patched at seed time and gitignored ([ADR-0002](docs/adr/0002-app-patches.md)); `themes/apsconecta/` is the white-label server theme. |
| `docs/ARCHITECTURE.md` | The architecture overview (design SSOT). |
| `ROADMAP.md` · `BUGS.md` | Roadmap narrative · known bugs. Work in progress is on the [Projects board](https://github.com/orgs/APS-Conecta/projects/5). |
| `LICENSE` · [`docs/LICENSING.md`](docs/LICENSING.md) | Our code's license (proprietary) · full third-party license audit. |
| `CONTRIBUTING.md` · `AGENTS.md` · `CONTRIBUTORS.md` | Contribution rules + how we track work · AI-agent invariants · the team. |
| `.github/` | `CODEOWNERS`, PR + issue templates, `SECURITY.md`. |

## Current state

v1 is complete: the browser acceptance run passed on 2026-07-24, with ODF edits through conversion
(see *Office suite* above). What each provisioning phase does is listed once, in
[`provisioning/README.md`](provisioning/README.md).

## Developing — how to implement a feature

The paradigm is **vanilla Nextcloud + configuration-as-code, no fork**: the platform owns runtime and data;
this repo adds only *declarative* customization (config, theming, groups/folders/ACLs) — **no core patch,
zero custom PHP in v1** — and the running instance is a disposable *projection* of the repo's recipe. **The
only thing that changes instance state is `make seed`**, which `make install` wraps — one idempotent `occ`
script (AD-2). Never hand-click
configuration into the running app; if it isn't scripted, it isn't real.

### The loop

1. Edit the recipe — a `provisioning/phases/NN-*.sh`, `sites/<slug>/site.sh`, `apps/` / `themes/`, or `.env`.
2. `make install` — converge. Same command as the first time; it is idempotent by construction.
   (`make up-dev` first if you want Xdebug on `:9003`; `SEED_FIXTURES=0 make seed` applies structure
   only, skipping the fixture phases; `make seed` is the verbose inner pipeline.)
3. `make smoke` / `make test` — health-gate + the local quality gate. Green before a PR — CI runs the same script.
4. Open a PR — see [`CONTRIBUTING.md`](CONTRIBUTING.md) (GitHub Flow, Conventional Commits, `ai-assisted`, 1
   approval); work is tracked on the [Projects board](https://github.com/orgs/APS-Conecta/projects/5).

### A feature = one provisioning phase

Features are applied by numbered scripts in `provisioning/phases/`, run in **fixed order 05 → 60** by
`make seed` (structure before fixtures). **One epic owns one file** (see each file's `# OWNER:` header) — a
new epic adds its own `NN-*.sh` and `seed.sh` picks it up automatically, so parallel epics never collide.
Its body uses only the **query-before-create guard helpers**, so re-running converges instead of
duplicating. **Never blind-create.** Verify by re-running `make seed` (every line should log "exists" /
"already =") then `make test`.

The phase list, the contract and the full helper list live in
[`provisioning/README.md`](provisioning/README.md) — one owner per fact, so they are not repeated here.

### Custom apps & themes

`apps/` (→ `custom_apps`) and `themes/` are **bind-mounted for live edit** — no rebuild, no fork; `make up`
runs `make fix-mount-perms` so the container (uid 33) can write them. A custom app talks to Nextcloud **only
through OCP public APIs (`OCP\…`)** — never patch core (AD-9) — carries an `appinfo/info.xml`
(`min-version="34"`), and is enabled with `occ app:enable <id>`. **No custom app lives here yet** — `apps/`
currently holds only store-installed upstream apps (gitignored), and the first Layer-2 app, the REM analyzer, has
its own repository. White-labeling ships as the **`themes/apsconecta/`
server theme** — AD-6's config-only rule is superseded by
[ADR-0001](docs/adr/0001-server-theme-for-branding.md). How the theming actually behaves (and why most of
it is config rather than CSS) is [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md); how to apply the
brand to an instance, step by step, is [`docs/BRANDING.md`](docs/BRANDING.md). Neither is a hosting
guide — **there is no deployment documentation, deliberately**: everything operational for a live
deployment is deferred, and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) § *Out of scope for v1*
says what and why. Locale stays in the `10-locale` phase.

### The office backend

`make office-eurooffice` brings up Euro-Office (AD-5), wires its connector, and runs an editing smoke.
It also audits the image provenance (OSS, no paid licence).

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
