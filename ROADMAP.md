# Roadmap — APS Conecta Gestión

Status doc, repo-first SSOT. This file is the narrative — where we are and where we're going;
architecture in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Where we are

**v1 feature-complete (Foundation + Spine A).** Planning (brief → PRD → architecture → epics/stories →
sprint plan, 2026-07-18/19) plus Epics 0–4 are done and merged (PRs #7–#21) on Nextcloud 34.0.1 + PG18:

- **Epic 0 — Foundation & dev environment:** portable Compose stack, the Euro-Office office backend,
  Xdebug dev profile, the `make seed`/`smoke`/`test` gate, the phase-structured idempotent
  provisioning framework, synthetic fixtures, repo-as-SSOT onboarding, and live app/theme mounts.
- **Epic 1 — Localization:** es-CL locale defaults (`10-locale` phase). White-label branding is **not
  applied in v1** — the instance runs the default Nextcloud theme until a brand guide + CLI-uploadable
  logo/favicon exist.
- **Epic 2 — Roles & access:** the group registry (all-staff · 4 categories · 21 roles · team
  placeholders) + synthetic fixture users including a multi-role demo.
- **Epic 3 — Document Home / Spine A:** the 12-folder four-area tree (Transversal · Programas · Unidades ·
  Sectores) + the first-cut allow-only access matrix + Spanish conventions.
- **Epic 4 — Live collaborative editing:** native to the office backend; `make office-formats` audits the
  OSS/no-paid-licence image.

Org governance is in place: `LICENSE` (proprietary) + `docs/LICENSING.md`, `.github/` scaffolding
(CODEOWNERS, PR + issue templates, `SECURITY.md`), and `CONTRIBUTORS.md`. Work is tracked on the
[Projects board](https://github.com/orgs/APS-Conecta/projects/5).

## Next

1. **Human acceptance run** of [`docs/ACCEPTANCE-EDITING.md`](docs/ACCEPTANCE-EDITING.md) against a live
   Euro-Office backend — the one v1 step that can't be driven headlessly.
2. **Epic retrospectives** (optional).

## Future

Post-v1 roadmap (from the brief/PRD): white-label **branding** (once a brand guide lands) · Nextcloud
**Tables** → **REM app** (first Layer-2 custom app) → full-text **search** → **Paperless-ngx** →
**Analytics** → local **AI** layer.
