# APS Conecta — Gestión

Internal management / intranet suite for Chilean primary-healthcare establishments — CESFAM and the
rest of the APS network — built as a **white-label Nextcloud** deployment (official image, **no
source fork**), self-hosted via Docker. Each install serves **one establishment**, named in that
install's configuration — the product names none, ships none, and `sites/` is where your own values
land.

> **Status: ✅ v1 done (Foundation + Spine A).** Epics 0–4 are merged — dev stack + debugger +
> quality gate + provisioning, es-CL locale, roles/access, the four-area document
> tree, and live office editing — and the browser acceptance run passed on **2026-07-24**.

## What this is (and isn't)

- **Is:** staff-facing internal operations (documents, coordination) on **Nextcloud 34 + PostgreSQL 18 +
  Redis 8**, with a self-hosted **Euro-Office** office suite and **Talk** for staff chat and calls.
  Two ways to run it: a developer's machine via Docker Compose (this README's Quickstart), or a
  clinic via **APS Conecta Gestión AIO**, installed by **[instalador](https://github.com/APS-Conecta/instalador)**
  — the all-in-one installer, which also owns the provisioning pipeline that configures an instance
  ([`INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md) is its runbook).
  This repository is the suite's **definition**: the vendored apps, the server theme, the DEIS register
  and the data packages the installer reads, plus the dev stack.
- **Isn't:** a clinical/patient-records system. **No patient data** — dev uses **synthetic fixtures only**.

## Quickstart

Each step names where it runs and how to know it worked. Steps 3 and 4 were rewritten when the install
half moved to instalador and have not been re-run since: `make up` itself is unchanged.
**Prerequisites:** Docker Engine 24+ with Compose v2, `make`, and `git`. All commands run on the **host**
from the repo root unless noted.

1. **Clone and enter the repo.** This is the development quickstart: `main` is the development trunk
   and is not what goes live. A clinic installs a signed release package from
   [instalador](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md), never a clone
   of this repository (ADR-0005).
   ```bash
   git clone git@github.com:APS-Conecta/gestion.git apsconecta-gestion
   cd apsconecta-gestion
   ```

2. **Create your local env file** (gitignored — never committed).
   ```bash
   make setup
   ```
   *Expected:* it generates all four secrets — admin password, PostgreSQL, `OFFICE_JWT_SECRET`,
   fixture password — writes them to `.env` and sets it to mode 600, so only your account can read
   it. Hex values, because Compose interprets `$` and a generated `$` would break the file.

   **Your admin password lives in that file and nowhere else** — why there is no rendered copy is in
   [`CONTRIBUTING.md`](CONTRIBUTING.md) § *Local dev environment*. Read it once into your password
   manager:
   ```bash
   grep '^NEXTCLOUD_ADMIN_PASSWORD=' .env
   ```
   It **refuses** if `.env` already exists: Nextcloud reads the admin password only when it first
   installs itself, so rewriting the file on a live stack changes no login and only makes the file
   disagree with the database.

3. **Choose your establishment** (only if you will provision this stack with instalador). **None
   ships.** The product names no establishment, so a clone carries none: you pick yours from the
   DEIS register of Chilean primary-care establishments, which *does* ship.
   ```bash
   scripts/deis.py                                     # search, then pick a number from the list
   scripts/deis.py cesfam <comuna>                     # or filter — every term must match, accent-blind
   scripts/deis.py <codigo> --new mi-establecimiento   # writes sites/mi-establecimiento/site.sh
   ```
   Any primary-care establishment in the register works — CESFAM, PSR, CECOSF, CGR, CGU, COSAM,
   SAPU, SAR or SUR. The `cesfam` above is a search *word*, not a required type.

   *Expected:* the last command asks for your **sectors** and **programs** — one per line, blank
   line to finish — because no register knows them. The file it writes is **gitignored**, like
   `.env`: your configuration stays yours. instalador reads it (`aps-conecta install --sitio`); this
   repository does not provision.

4. **Start the stack.**
   ```bash
   make up
   ```
   *Expected:* the five services (Nextcloud, PostgreSQL, Redis, cron, Euro-Office) start and the command
   returns once Nextcloud has finished installing itself. *If it fails*, `docker compose logs nextcloud`
   names why. The stack is **not provisioned**: no groups, folders, branding or locale are applied here
   (that is instalador's pipeline, [`INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md)),
   so what you get is a bare Nextcloud 34 with `apps/` and `themes/` live-mounted.

5. **Open the app.**
   Browse to **`http://localhost:8180`** (the `HTTP_PORT` from your `.env`) and sign in with the
   `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` you set.

To stop: `make down` (keeps your data volumes). That's the whole loop.

## Running a clinic — the installer (AIO)

A clinic does not run the dev stack. It runs **APS Conecta Gestión AIO**: one `docker run` from the
published suite tag, the branded es-CL wizard, and the `aps-conecta` host bundle driving the
provisioning phases over `docker exec` — all of it in [instalador](https://github.com/APS-Conecta/instalador),
which absorbed the install half of this repository and holds the only live copy. The whole path —
preflight, wizard, Provisionador, timers, backups — is
[`INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md) (English
runbook) with the Spanish walkthrough in [`GUIA-CLINICA.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/GUIA-CLINICA.md).
One establishment per install (D13). A release packages the content of this repository at its tag
(`provisioning/apps`, `provisioning/data`, `sites`, `themes/apsconecta`); a clinic installed from an
older gestion clone moves with [`MIGRATION.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/MIGRATION.md).

## Make targets

Run **`make help`** — it reads the Makefile, so it cannot drift. (A hand-copied table used to live
here and had already lost four targets.)

**Step-debugging:** `make up-dev`, then in VS Code run the committed **"Listen for Xdebug"** config
(`.vscode/launch.json`, port 9003) and send a request carrying the Xdebug trigger.

**Office suite:** Euro-Office comes up with the stack (#81); wiring its connector is instalador's provisioning.
`make office-down` stops just the document server when you want the ~2.5 GB back.

**Live editing acceptance (Epic 4) — done**, in a browser on **2026-07-24**
([#30](https://github.com/APS-Conecta/gestion/issues/30), closed). What was run and what it proved:
[`ROADMAP.md`](ROADMAP.md) § *Where we are*.

**Which formats you can actually edit.** OOXML — `docx`, `xlsx`, `pptx` — opens and edits normally.
**ODF — `odt`, `ods`, `odp` — is editable too, through conversion, so expect some formatting loss on
save**: the connector declares those `lossy-edit` rather than `edit`. Enabled deliberately (#45,
B-007) because the alternative — converting to `.docx` by hand — loses the same fidelity and leaves a
duplicate file behind, which [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) § *Una sola copia viva*
exists to prevent. Set by instalador's office phase, never in the admin UI (AD-2).

## Where things live

| Path | What |
|---|---|
| `compose.yaml` | Every service — nextcloud/db/redis/cron + `eurooffice` (no longer a profile, #81). All four images pinned by digest (#109). |
| `compose.dev.yaml`, `Dockerfile.dev`, `dev/xdebug.ini` | The derived Xdebug dev image (AD-10). |
| `.env.example` | Template for your gitignored `.env`. **Never commit `.env`.** |
| `Makefile` | The dev lifecycle (`make help`). |
| `scripts/` | `env-init.sh` (`make setup`) + `wait-ready.sh` + `env.sh` (shared preamble), `test.sh` (the gate), `deis.py` (searches and refreshes the DEIS register, writes a site file; **this copy is canonical** — the register lives here — and instalador's `scripts/deis.py` follows it), and the drift tooling: `image-digests.sh` + `app-versions.sh` (is anything we pinned behind upstream), `release-manifest.sh` (the machine-readable union of everything a release pins), `check-org-drift.sh` (the org boilerplate drift gate, also run by instalador's CI). |
| `provisioning/` | The suite's **data**: `apps/` (per app: the vendored tarball, its `VENDOR` file and its patches — [ADR-0002](docs/adr/0002-app-patches.md)) and `data/` (the data-package manifest and the comuna reference). The provisioning pipeline that applies it is instalador's. See [`provisioning/README.md`](provisioning/README.md). |
| `sites/` | The DEIS register of primary-care establishments, tracked — it is what you pick from. Your `<slug>/site.sh` (teams, folders, ACL matrix, identity) lands here and is **gitignored**: it depends on which establishment you install, so it is install-local like `.env`. **No establishment ships**; write yours with `scripts/deis.py`. |
| `apps/`, `themes/` | Live-mounted. `apps/` is gitignored and holds the apps unpacked from the tarballs committed in `provisioning/apps/`, patched at seed time ([ADR-0002](docs/adr/0002-app-patches.md)); `themes/apsconecta/` is the white-label server theme. |
| `docs/ARCHITECTURE.md` | The architecture overview (design SSOT). |
| [`INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md) · [`GUIA-CLINICA.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/GUIA-CLINICA.md) | In instalador: the clinic runbook (English) · the Spanish clinic-IT guide — the installer era's operator docs. |
| `ROADMAP.md` · `BUGS.md` | Roadmap narrative · known bugs. Work in progress is on the [Projects board](https://github.com/orgs/APS-Conecta/projects/5). |
| `LICENSE` · [`docs/LICENSING.md`](docs/LICENSING.md) | Our code's license (AGPL-3.0-or-later) · full third-party license audit. |
| `CONTRIBUTING.md` · `AGENTS.md` · `CONTRIBUTORS.md` | Contribution rules + how we track work · AI-agent invariants · the team. |
| `.github/` | `CODEOWNERS`, PR + issue templates, `SECURITY.md`. |

## Developing — how to implement a feature

The paradigm is **vanilla Nextcloud + configuration-as-code, no fork**: the platform owns runtime and data;
this repo adds only *declarative* customization (the suite's apps, its server theme, the register and
data packages) — **no core patch** — and the running instance is a disposable *projection* of that
recipe. The only thing that changes instance state is the installer's idempotent provisioning, which
lives in [instalador](https://github.com/APS-Conecta/instalador). Never hand-click configuration into
the running app; if it isn't scripted, it isn't real.

### The loop

1. Edit what this repository owns — `themes/`, `provisioning/apps/` (a tarball, its `VENDOR` file and
   patches), the register under `sites/`, `provisioning/data/`, or the dev stack (`compose*.yaml`).
2. `make up` (or `make up-dev` for Xdebug on `:9003`) to see a theme or app edit live in the dev stack.
3. `make test` — the local quality gate. Green before a PR — CI runs the same script.
4. Open a PR — see [`CONTRIBUTING.md`](CONTRIBUTING.md) (GitHub Flow, Conventional Commits,
   `ai-assisted`, self-review); work is tracked on the
   [Projects board](https://github.com/orgs/APS-Conecta/projects/5).

### A feature = one provisioning phase — in instalador

Features that configure an instance (groups, folders, ACLs, branding, locale, the office connector,
the welcome tree) are numbered phase scripts in **instalador's** `provisioning/phases/`, run in fixed
order and written with query-before-create guards so a re-run converges instead of duplicating. Add or
change one there, and read its README. Nothing in this repository applies configuration.

### Custom apps & themes

`apps/` (→ `custom_apps`) and `themes/` are **bind-mounted for live edit** — no rebuild, no fork; `make up`
runs `make fix-mount-perms` so the container (uid 33) can write them. A custom app talks to Nextcloud **only
through OCP public APIs (`OCP\…`)** — never patch core (AD-9) — carries an `appinfo/info.xml`
(`min-version="34"`), and is enabled with `occ app:enable <id>`. **Five own apps live here** —
`epidemiologia`, `farmacia`, `territorio`, `intravox` and `estadistica` — unpacked by the installer
from their own vendored tarballs like every other app
([ADR-0003](docs/adr/0003-this-stack-ships-a-custom-app.md), reversing AD-1) — so an install still needs no
network. On a development machine the same directory is a git clone instead, and instalador's provisioning
leaves it alone. All of `apps/` is gitignored either way. White-labeling ships as the **`themes/apsconecta/`
server theme** — AD-6's config-only rule is superseded by
[ADR-0001](docs/adr/0001-server-theme-for-branding.md). How the theming actually behaves (and why most of
it is config rather than CSS) is [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md); How to apply the brand to an instance, step by step, is [`docs/BRANDING.md`](docs/BRANDING.md).
Neither is a hosting guide: the clinic hosting runbook is
[`INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md) (the AIO installer era); the dev stack stays this
README's Quickstart.

### The office backend

Euro-Office (AD-5) is part of the stack, not an add-on: #81 dropped its compose profile, so a clinic can
open a document. The editing smoke and the image-provenance audit (OSS, no paid licence) run in
instalador's gate.

### Guardrails you must not break

Defined once in [`AGENTS.md`](AGENTS.md) (the invariants) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
(the design paradigm). Read them before you touch the stack.

## Contributing & conventions

See [`CONTRIBUTING.md`](CONTRIBUTING.md) — GitHub Flow + the PR review gate, principles
(DRY/SOLID/YAGNI), the language split (**code in English, UI in Spanish**), and the documentation rules.

## How we build it

The committed **single source of truth** for the design is [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
(the architecture overview); the code itself (`compose.yaml` here, and the provisioning phases in instalador) is
authoritative for behavior. Status narrative lives in [`ROADMAP.md`](ROADMAP.md).

## Reference docs (pulled live via Context7 MCP — never hardcode)

| Topic | Context7 library ID |
|---|---|
| Nextcloud admin / deploy | `/websites/nextcloud_server_admin_manual` |
| Nextcloud app development | `/websites/nextcloud_server_developer_manual` |
| Nextcloud PHP / OCP API | `/websites/nextcloud-server_netlify_app` |
| Nextcloud Vue UI kit | `/nextcloud-libraries/nextcloud-vue` |
