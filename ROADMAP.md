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

Org governance is in place: `LICENSE` (proprietary) + `docs/LICENSING.md`, `.github/` scaffolding
(CODEOWNERS, PR + issue templates, `SECURITY.md`), and `CONTRIBUTORS.md`. Work is tracked on the
[Projects board](https://github.com/orgs/APS-Conecta/projects/5).

The **browser acceptance run passed on 2026-07-24** against a live Euro-Office backend (documentserver
9.3.1.37): in-browser render, create/edit/save round-trip, co-editing convergence and cursor presence.
That was the last open v1 step, so the standing runbook (`docs/ACCEPTANCE-EDITING.md`) has been retired —
the pipe is proven and `make office-smoke` keeps it honest. One caveat came out of
it: ODF (`odt`/`ods`/`odp`) was view-only. Since fixed — **ODF now edits through conversion, with the
formatting loss that implies** (issue #45).

## Next

Only one item here is actually pending; everything else that used to sit under this heading has
shipped and moved to **Done** below.

1. **Epic retrospectives** (optional).

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

The reasoning behind each of these lives with the thing it describes — the ADR, the phase file, or
the stylesheet. It is not restated here; this table is an index, not a second copy.

## Future

Post-v1 roadmap (from the brief/PRD): white-label **branding** *(shipped as Epic 5, above)* ·
**REM app** (first Layer-2 custom app — **in progress**) → full-text **search** → **Paperless-ngx** →
**Analytics** → local **AI** layer.

**Production posture is deferred until a target host exists** — TLS/HSTS, SMTP, 2FA enforcement, the
AppAPI daemon and the server id, all held with their measurements in
[#75](https://github.com/APS-Conecta/gestion/issues/75). They are what admin › Overview reports on a
dev box, and none is a code defect. The deferral itself is stated in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) § *Environments*; the issue holds the specifics so they
resurface when there is a machine instead of being rediscovered on that page.

**Nextcloud Tables is no longer in the chain** (#24, closed 2026-07-29). It was queued as the
substrate for the REM app; that premise was wrong. The app owns its own schema — `rem_fact`,
`rem_hoja_status`, `rem_source` through Nextcloud's mapper layer — and never references Tables, so
Tables had no dependent. Adding it would put an app on the instance that nothing needs, on an
instance where `16-app-policy` exists to keep the app surface small.

The **REM app** does not live in this repo: it is [`APS-Conecta/analizador-rem`](https://github.com/APS-Conecta/analizador-rem),
a separate Nextcloud app with its own tests, docs and `docs/ESTADO.md`. Its state belongs there and
is deliberately not mirrored here — one owner per fact. What this repo owns is the platform it
installs onto (`apps/` → `custom_apps`, the extension boundary in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)).
