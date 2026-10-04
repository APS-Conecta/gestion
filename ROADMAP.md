# Roadmap — APS Conecta Gestión

Status doc, repo-first SSOT. This file is the narrative — where we are and where we're going;
architecture in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Where we are

**v1 feature-complete (Foundation + Spine A).** Planning (brief → PRD → architecture → epics/stories →
sprint plan, 2026-07-18/19) plus Epics 0–4 are done and merged (PRs #7–#21) on Nextcloud 34.0.1 + PG18.
An install stands up a **named clinic** — `make setup`, then `make install` against the clinic declared
in `sites/<slug>/site.sh` — on that clinic's host or on a developer's machine:

- **Epic 0 — Foundation & dev environment:** portable Compose stack, the Euro-Office office backend,
  Xdebug dev profile, the `make seed`/`smoke`/`test` gate, the phase-structured idempotent
  provisioning framework, synthetic fixtures, repo-as-SSOT onboarding, and live app/theme mounts.
- **Epic 1 — Localization:** es-CL locale defaults (`10-locale` phase). White-label branding was out of
  scope *at the time*, pending a brand guide; it landed, and **Epic 5 shipped the branding on
  2026-07-27** — see *Done* below.
- **Epic 2 — Roles & access:** the group registry (all-staff · the four categories · the shared roles ·
  team placeholders) + the clinic's standing leadership accounts, where every jefe de sector holds a
  role, a sector team and a category at once.
- **Epic 3 — Document Home / Spine A:** the four-area tree (Transversal · Programas · Unidades ·
  Sectores), sized per clinic by `sites/<slug>/site.sh`, + the first-cut allow-only access matrix +
  Spanish conventions.
- **Epic 4 — Live collaborative editing:** native to the office backend; `make office-smoke` audits the
  OSS/no-paid-licence image.

Org governance is in place: `LICENSE` (AGPL-3.0-or-later since 2026-08-07, ADR-0010) +
`docs/LICENSING.md`, `.github/` scaffolding
(CODEOWNERS, PR + issue templates, `SECURITY.md`), and `CONTRIBUTORS.md`. Work is tracked on the
[Projects board](https://github.com/orgs/APS-Conecta/projects/5).

The **browser acceptance run passed on 2026-07-24** against a live Euro-Office backend (documentserver
9.3.1.37): in-browser render, create/edit/save round-trip, co-editing convergence and cursor presence.
That was the last open v1 step, so the standing runbook (`docs/ACCEPTANCE-EDITING.md`) has been retired —
the pipe is proven and `make office-smoke` keeps it honest. One caveat came out of
it: ODF (`odt`/`ods`/`odp`) was view-only. Since fixed — **ODF now edits through conversion, with the
formatting loss that implies** (issue #45).

## Next

**The installer run** ([#199](https://github.com/APS-Conecta/gestion/issues/199)) — an install a clinic
can run end to end without a developer. Laps L1–L3 shipped (see *Done*); the rest, in order:

1. **L4 AIO fork** — one patch per finding: identity, the IP path and its certificate (R22), the
   wizard's own page in Spanish (R25, R27, R48), refusals, Talk off by default.
2. **L5 Map** — the basemap as a registry step, the Centro picker, same-origin `/tiles/`.
3. **L6 Docs** — `docs/INSTALLER.md` ⇄ the clinic guide, mirrored step for step.
4. **L7 Run acceptance** — a release candidate installed on three boxes by the rehearsal harness.
   It carries:
   - the two-line bootstrap on a pristine Ubuntu 24.04 box (from L2);
   - the printed link opened from another LAN machine, and a real browser run ending with an empty
     divergence report (from L3);
   - Talk and its recording measured under load (#206).

Also open: **Epic retrospectives** (optional).

## Done

| When | What | Where it lives now |
|---|---|---|
| 2026-07-24 | v1 accepted — browser acceptance run passed | this file, § *Where we are* |
| 2026-07-24 | **ODF editing** (#45 / B-007) — lossy, via OOXML conversion | `provisioning/phases/14-office.sh` |
| 2026-07-27 | **Epic 5 — white-label branding.** Server theme (`server.css`, woff2 fonts, brand images), the `15-branding` phase, `side_menu`, and gates for every referenced asset + every theme SVG parsing. No `defaults.php`, no per-app icon directory — both turned out unnecessary. | [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md), [`ADR-0001`](docs/adr/0001-server-theme-for-branding.md) |
| 2026-07-27 | **ADR-0000** — `AD-1` … `AD-10` defined, so every citation resolves | [`docs/adr/0000-inherited-decisions.md`](docs/adr/0000-inherited-decisions.md) |
| 2026-07-29 | **ADR-0002** — app edits move from `sed` to committed `*.patch` files | [`docs/adr/0002-app-patches.md`](docs/adr/0002-app-patches.md) |
| 2026-07-29 | **Nextcloud Tables dropped from the chain** (#24) — the REM app owns its own schema, so Tables had no dependent | this file, § *Future* |
| 2026-07-30 | **Home affordance** — the header lockup plus the word INICIO, gated above 600 px *(superseded by the header rework below)* | `themes/apsconecta/core/css/server.css` |
| 2026-07-30 | **Post-v1 hardening** — session posture, cron scheduling, app policy, empty user skeleton | phases `05`, `06`, `16`, `15` |
| 2026-07-30 | **One clinic, one data file** (#78) — groups, folders and ACLs stop being shell; a clinic is declared in `sites/<slug>/site.sh`, written from the DEIS register | `sites/<slug>/site.sh`, `scripts/deis.py` |
| 2026-08-01 | **`make setup` + `make install`** (#80, #79) — the four secrets are generated instead of hand-typed, then one command boots, provisions and converges a named clinic | `scripts/env-init.sh`, `scripts/install.sh` |
| 2026-08-01 | **Header rework** (#84/#102) — the header carries the instance (mark · home icon · clinic name); the platform lockup moved to the side menu and INICIO was retired | `themes/apsconecta/core/css/server.css` |
| 2026-08-01 | **Every image pinned by digest** (#109), with a weekly drift check | `scripts/image-digests.sh` |
| 2026-08-01 | **`SITE_ROLES`** (#103) — a clinic can declare roles the shared registry does not name | `provisioning/phases/20-groups.sh` |
| 2026-08-01 | **Vendored app tarballs** (#98) — nothing in an install reads the app store | `provisioning/apps/` |
| 2026-08-01 | **Divergence report** (#85) — names what is live but no longer declared, and never deletes it | `scripts/divergence.sh` |
| 2026-08-01 | **The six read-only grants** (#116) — the access matrix gets a second level, read as well as manage | `provisioning/phases/40-acl.sh` |
| 2026-08-01 | **Weekly app-version check** (#117) — `make install` re-imposes the vendored tarball, and CI reports when one is behind | `scripts/app-versions.sh`, `.github/workflows/image-digests.yml` |
| 2026-09-22 | **AIO installer suite 0.3.0** (#187) — the Provisionador, the translated QA suite's gestion side, the host bundle, the CI gate stack, tiles+datos, the migration tool and docs | `provisionador/`, [`docs/INSTALLER.md`](docs/INSTALLER.md), release 0.3.0 |
| 2026-09-24 | **Welcome screen (IntraVox) as phase 41** — engine setup + es payload + page ACL, telemetry pin, divergence tolerances | `provisioning/phases/41-intravox.sh`, ADRs 0014–0017; deferred ideas ledger in the program docs |
| 2026-09-25 | **Org-wide hardening program (12 phases)** — postures, drift gates, manuals under version control, org CI template; validated pass | `.github/workflows/ci.yml`, `docs/adr/`, validation in the org artifacts repo |
| 2026-09-28 | Welcome tree declared per site and converged per section — IntraVox review Phase 3: `SITE_WELCOME`, one renderer, `occ intravox:import --skip-existing`, the ten static team pages retired; review Phases 4 (walls) and 5 (discoverability) are next | `docs/adr/0019-the-welcome-tree-is-declared-and-converged-per-section.md`, `provisioning/intravox/render.py`, `docs/WELCOME-SCREEN.md` |
| 2026-09-29 | **Storage root named for staff** — IntraVox review Phase 5: `IV_MOUNT` → engine `groupfolder_name`, the seed refuses an unrenamed install, «Abrir en Archivos» on every page, the «dónde vive» note seeded | [`ADR-0020`](docs/adr/0020-the-storage-root-is-named-for-staff.md), [`docs/WELCOME-SCREEN.md`](docs/WELCOME-SCREEN.md) |
| 2026-10-01 | **Installer L1 — the Nextcloud container resolved once** (#200, closes #197, PR #207) — `nc_container`/`is_aio` in `scripts/env.sh` replace a template default, 4 restated defaults and 7 detection copies; **Clean boot green end to end on AIO** for the first time since 2026-09-21, after the run exposed and fixed B-030 (IntraVox group map order), B-031 (smoke check 15 on Nextcloud 34, now developer-only), B-032 (`seed-idempotent`'s leftover fixture account) and B-033 (the harness's tiles surface) | `scripts/env.sh` § 3, [`BUGS.md`](BUGS.md) B-029–B-033 |
| 2026-10-02 | **Installer L2 — the silent install core** (#201, PRs #209–#216) — one step registry behind `aps-conecta` (welcome + nine numbered steps, Spanish operator text); the two-line root bootstrap (`preparar`/`descargar`); the AIO wizard drive moved into the CLI (`asistente-aio`); `install --sitio --planilla` with zero prompts, one Spanish line per phase — **Clean boot now installs through it**; staff land in their category group by role and every cargo account gets a sealed first password; `temporizadores` on Santiago time; `aps-conecta estado` and the admins' login notice on drift, proven on real systemd in CI | [`host/aps-conecta`](host/aps-conecta), [`docs/INSTALLER.md`](docs/INSTALLER.md) §2–§6, [`BUGS.md`](BUGS.md) B-034 |
| 2026-10-03 | **Installer L3 — the web installer** (#202, PRs #220–#224) — one HTTPS LAN link with the token in its fragment, the installer exiting after a green run; the same numbered steps in the browser: «Elegir el centro» over the whole DEIS register, «Iniciar la suite» (the five apps, Talk sized to the server, the AIO wizard pre-filled with the daily backup, the containers followed by name), «Cargar equipos y personas» (a re-submit conflict, the centre's CSV template, the valid groups), «Revisar y ejecutar» in clinic terms followed by polling; Playwright walks every screen; Clean boot measures the idle suite (~1.1 GiB) | [`scripts/provisionador.py`](scripts/provisionador.py), [`docs/GUIA-CLINICA.md`](docs/GUIA-CLINICA.md) §3–§4, [`docs/INSTALLER.md`](docs/INSTALLER.md) §4 |

The reasoning behind each of these lives with the thing it describes — the ADR, the phase file, or
the stylesheet. It is not restated here; this table is an index, not a second copy.

## Future

Post-v1 roadmap (from the brief/PRD): white-label **branding** *(shipped as Epic 5, above)* ·
**Estadística** → full-text **search** → **Paperless-ngx** → local **AI** layer.

**Estadística takes both the REM app's slot and Analytics'**, because they turned out to be one
app: the center's REM figures beside the national and peer figures, and the Metas Sanitarias month
by month, in [its own repository](https://github.com/APS-Conecta/estadistica). Its M1, the REM
pillar, is **shipped**: promoted to `OWN_APPS` at v0.1.0, it installs from a vendored tarball.
From this repo it needs only its establishment: phase 16 writes it and `scripts/divergence.sh`
reads it back ([ADR-0013](docs/adr/0013-the-establishment-is-instance-configuration.md), as amended).

**Production posture is deferred until a target host exists** — TLS/HSTS, SMTP, 2FA enforcement, the
AppAPI daemon and the server id, all held with their measurements in
[#75](https://github.com/APS-Conecta/gestion/issues/75). They are what admin › Overview reports on a
dev box, and none is a code defect. The deferral itself is stated in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) § *Environments*; the issue holds the specifics so they
resurface when there is a machine instead of being rediscovered on that page.

**Nextcloud Tables is no longer in the chain** (#24, closed 2026-07-29). It was queued as the
substrate for the REM app; that premise was wrong — a custom app owns its own schema through
Nextcloud's mapper layer and never references Tables.

**The installer CA's own lifecycle.** The CA made at the first install signs the suite's leaf by IP
and lasts 3650 days; nothing renews it, and a missing one stops the run rather than being made again
(staff devices trust it). Its renewal, a planned rotation with the devices re-importing, is future
work, years out.

Estadística builds REM, and this repo owns only the platform it installs onto
([`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) § *Extension boundary*).
