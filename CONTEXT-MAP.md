# CONTEXT-MAP

This repo has **multiple bounded contexts** (a white-label suite + per-app custom code). Domain language
is scoped per context so one app's terms never pollute another's. This map points to where each context's
glossary and decision records live.

| Context | Glossary | Decisions | Notes |
|---|---|---|---|
| **Suite (APS Conecta Gestión)** | PRD §3 — `docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md` | Architecture spine `AD-1..AD-11` — `docs/planning/architecture/…/ARCHITECTURE-SPINE.md` | Suite-wide, committed SSOT. |
| **Data-protection law** (suite-wide) | legal terms in the app contexts that use them | `docs/legal/` — full texts of Ley 21.719 + Ley 19.628 (verified-complete + raw XML) | Applies to *any* app storing personal data; reused by every context. |
| **Libro de Actas** (Layer-2 app) | `docs/apps/libro-actas/CONTEXT.md` | `docs/apps/libro-actas/adr/`, spec in `docs/apps/libro-actas/specs/`, compliance map `docs/apps/libro-actas/compliance-ley-21719.md` | First custom app. Runtime code will live in `apps/libro_actas/`. |

## Rules

- A term defined in a **context** glossary is authoritative for that context only.
- Suite-wide terms live in the PRD §3 glossary; don't duplicate them into a context.
- When a second app needs a term currently sitting in an app context (e.g. the legal terms in
  `libro-actas/CONTEXT.md`), **promote** it to a suite-wide glossary rather than copy it.
- New contexts (e.g. the roadmap REM app) get their own row + `docs/apps/<app>/CONTEXT.md`.
