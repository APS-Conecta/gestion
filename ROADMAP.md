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
   **Done:** the theme (`server.css`, woff2 fonts, brand images, `defaults.php`), the `15-branding`
   provisioning phase, and a `make test` guard asserting every asset `server.css` references exists.

   **Close-out plan.** Ordered so the one item that can still invalidate a decision is settled before
   anything is written on top of it. Verification is browser-driven; gates are written *after*
   observing, so they encode reality rather than guesses.

   Two projects are in play. This repo holds everything that runs on the server. The **brand kit** is
   a separate sibling folder (`../APS Conecta Nextcloud/`, MIT, not under git) holding the design
   tokens, logos and the living brandbook, which the public apsconecta.cl site also consumes. The rule
   throughout: *runs on the server → `gestion/`; feeds a designer or the website → the kit.*

   *There is no de-risking spike.* One was planned, to establish how brand images reach Nextcloud.
   Reading the shipped source in the pinned image settled it without running anything — see
   ADR-0001 § Corrections — so the spike collapsed into P1. Nothing remaining can invalidate a
   decision; what is left is verification and bug-fixing.

   - [ ] **P1 — Verification, single pass.** `make up && make seed`. `15-branding.sh` has never
         executed, so expect a fix-and-rerun cycle before anything is judged. Then, browser-driven:
         registration took (`logoMime`/`faviconMime`/`backgroundMime` all set, and `make seed` twice
         is stable); the variable map vs NC34 via the ADR-0001 console snippet; "Nextcloud" leaks on
         login/header/Settings; `apple-itunes-app` / `1125420102` (a number — `grep Nextcloud` misses
         it); Appearance selector absent; `/apps/theming/manifest`; PWA at 360 px;
         `document.fonts.check()` for the brand fonts; `occ app:list` + `grep -L currentColor` for
         clashing icons. Recorded as a GIF, mirroring the 2026-07-24 run.
         **Judgement call carried into this phase:** `background` is the whole-UI background, not
         just the login screen. Look at it behind a real file list and dashboard and decide whether
         the gradient survives an 8-hour shift. Fallback is one line:
         `theming:config background backgroundColor` — which also drops the branded login, since
         both are the same key.
   - [ ] **P2 — Fold results into docs.** Resolve ADR-0001's Pending section with what was observed.
         Retire `PLAN-IMPLEMENTACION.html` + `doc-page.js`, salvaging its §2 (how Nextcloud theming
         works) and §3 (the four-layer model) into a short `docs/THEMING-MODEL.md` — the rest
         duplicates MAPEO/BRANDING/LICENSING/ROADMAP, and that duplication is what caused the drift.
         Move first, then fix in place: `MAPEO.md` → beside `server.css`, `INSTALACION-NEXTCLOUD.md`
         → `docs/BRANDING.md`; then correct the stale lines there and in the kit's `README.md`,
         `README-BRANDING.md` and `sistema-diseno.html`. Moving first keeps the corrections from
         being made twice.
   - [ ] **P3 — Governance.** Define `AD-1/2/5/9/10` — cited in six files, defined in none; `docs/adr/`
         is now their home. Give `ADR-iconos` a home or point it at ADR-0001. Push
         `feat/brand-server-theme` and open the PR against `main`.
   - [ ] **P4 — Gates.** Grep the `/status.php` body `scripts/smoke.sh` already fetches for
         `Nextcloud`, catching the `productName` leak in ~2 lines. Promote the drift snippet to a
         script only if P1 showed real NC34 divergence.
   - [ ] **P5 — Kit loose ends.** `theme-custom.css` (obsolete, untracked — delete or keep) and which
         of `logo-header.svg` / `logo-header-oficial.svg` is canonical.
3. **Epic retrospectives** (optional).

## Future

Post-v1 roadmap (from the brief/PRD): white-label **branding** *(now in progress as Epic 5, above)* ·
Nextcloud **Tables** → **REM app** (first Layer-2 custom app) → full-text **search** → **Paperless-ngx** →
**Analytics** → local **AI** layer.
