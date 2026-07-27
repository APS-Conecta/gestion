# Roadmap — APS Conecta Gestión

Status doc, repo-first SSOT. This file is the narrative — where we are and where we're going;
architecture in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Where we are

**v1 feature-complete (Foundation + Spine A).** Planning (brief → PRD → architecture → epics/stories →
sprint plan, 2026-07-18/19) plus Epics 0–4 are done and merged (PRs #7–#21) on Nextcloud 34.0.1 + PG18:

- **Epic 0 — Foundation & dev environment:** portable Compose stack, the Euro-Office office backend,
  Xdebug dev profile, the `make seed`/`smoke`/`test` gate, the phase-structured idempotent
  provisioning framework, synthetic fixtures, repo-as-SSOT onboarding, and live app/theme mounts.
- **Epic 1 — Localization:** es-CL locale defaults (`10-locale` phase). White-label branding was **not
  applied in v1** — the instance ran the default Nextcloud theme. (The condition stated here was "a brand
  guide + CLI-uploadable logo/favicon". The brand guide landed; CLI-uploadable images turned out not to
  exist on NC34, which is why Epic 5 ships them as theme files instead — see ADR-0001.)
- **Epic 2 — Roles & access:** the group registry (all-staff · 4 categories · 21 roles · team
  placeholders) + synthetic fixture users including a multi-role demo.
- **Epic 3 — Document Home / Spine A:** the 12-folder four-area tree (Transversal · Programas · Unidades ·
  Sectores) + the first-cut allow-only access matrix + Spanish conventions.
- **Epic 4 — Live collaborative editing:** native to the office backend; `make office-formats` audits the
  OSS/no-paid-licence image.

Org governance is in place: `LICENSE` (proprietary) + `docs/LICENSING.md`, `.github/` scaffolding
(CODEOWNERS, PR + issue templates, `SECURITY.md`), and `CONTRIBUTORS.md`. Work is tracked on the
[Projects board](https://github.com/orgs/APS-Conecta/projects/5).

The **browser acceptance run passed on 2026-07-24** against a live Euro-Office backend (documentserver
9.3.1.37): in-browser render, create/edit/save round-trip, co-editing convergence and cursor presence.
That was the last open v1 step, so the standing runbook (`docs/ACCEPTANCE-EDITING.md`) has been retired —
the pipe is proven and `make office-smoke` / `make office-formats` keep it honest. One caveat came out of
it: **ODF (`odt`/`ods`/`odp`) is view-only**; only OOXML edits in place (issue #45).

## Next

1. **Decide on ODF** — accept view-only, or enable lossy ODF editing via `make office-eurooffice`
   (issue #45). Owner call.
2. **Epic 5 — white-label branding** (in progress). The brand guide landed, which was the condition
   this was deferred on, so it opens as the first post-v1 increment — v1 stays exactly as accepted on
   2026-07-24. Branding ships as the `themes/apsconecta/` **server theme**, superseding AD-6's
   config-only rule; reasoning in [`docs/adr/0001-server-theme-for-branding.md`](docs/adr/0001-server-theme-for-branding.md).
   - Done: the theme (server.css, woff2 fonts, brand images, `defaults.php`), the `15-branding`
     provisioning phase, a `make test` guard that every asset `server.css` references exists.
   - Open, all needing a running stack: whether theme images beat the Theming app's DB values;
     which app icons clash (`occ app:list` + grep for `currentColor`); and a `productName` leak
     check in `scripts/smoke.sh`.
3. **Epic retrospectives** (optional).

## Future

Post-v1 roadmap (from the brief/PRD): white-label **branding** *(now in progress as Epic 5, above)* ·
Nextcloud **Tables** → **REM app** (first Layer-2 custom app) → full-text **search** → **Paperless-ngx** →
**Analytics** → local **AI** layer.
