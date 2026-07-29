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
  applied in v1** — the instance ran the default Nextcloud theme. The condition stated here was "a brand
  guide + CLI-uploadable logo/favicon", and the brand guide landed.
  *(This line used to add that CLI-uploadable images "turned out not to exist on NC34" — that was
  wrong: `occ` sets all four image keys, it just needs an absolute path. Epic 5 ships them as theme
  files for a different reason: brand fonts need `@font-face` paths a theme serves. See ADR-0001
  § Corrections.)*
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
it: ODF (`odt`/`ods`/`odp`) was view-only. Since fixed — **ODF now edits through conversion, with the
formatting loss that implies** (issue #45).

## Next

1. **ODF — decided and shipped.** Lossy ODF editing is on, scripted in `make office-eurooffice`
   (#45 / B-007). The remaining office item is #50: whether `es_419` resolves to the `es-ES`
   document template or falls back to `en-US`.
2. **Epic 5 — white-label branding** ✅ **closed 2026-07-27.** The brand guide landed, which was the condition
   this was deferred on, so it opens as the first post-v1 increment — v1 stays exactly as accepted on
   2026-07-24. Branding ships as the `themes/apsconecta/` **server theme**, superseding AD-6's
   config-only rule; reasoning in [`docs/adr/0001-server-theme-for-branding.md`](docs/adr/0001-server-theme-for-branding.md).
   **Shipped:** the theme (`server.css`, woff2 fonts, brand images), the `15-branding` provisioning
   phase, `side_menu`, and two gates — every asset `server.css` references must exist *and* every
   theme SVG must parse, plus a `/status.php` branding check in `make smoke`. There is no
   `defaults.php` and no per-app icon directory; both turned out to be unnecessary.
   Working rules for anyone touching this: [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md).

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

   - [x] **P1 — Verification, single pass.** ✅ **Done 2026-07-27 on live NC 34.0.1.** The branding
         is live: violet header, Fraunces + Nunito Sans actually applied, all four images registered
         (`*Mime` = `image/svg+xml`), no `productName` leak in `status.php`, **no iOS banner**,
         themed webmanifest, and it renders **light even under a dark-mode OS**, so `enforce_theme`
         holds. *(Two conclusions from this pass were later overturned: the absent iOS banner was
         read as validating `defaults.php`, but a config key does the same job and the file is now
         deleted; and "the background reads as a subtle wash" was judging `server.css`'s own light
         gradient — the brand background image was covered and had never been visible at all.)*
         Two bugs fixed en route (`26dd40f`): a pre-existing `lib.sh` phase-killer where a
         query-before-set read of an *unset* key aborted the phase silently under `pipefail`+`set -e`,
         and `disable-user-theming` rewriting itself every seed. Three new items fell out — P1.5 below.
   - [x] **P1.5 — Decide what the theme still owns.** ✅ **Done 2026-07-27.** Owner call:
         *shrink `server.css` to what lands.* The `:root` block is deleted — measured 7 of 30
         variables arriving, and two of them (`--color-error`/`--color-success`) were in slots NC34
         documents as element **backgrounds**, so the brand values there were wrong, not merely
         overridden. What remains: `@font-face`, `--font-face` (the one documented typography
         variable, set with `!important` because four component-scoped NC rules read it and outrank
         any `body` selector), Fraunces on element selectors, the header gradient, focus rings and
         the high-contrast block. The header logo is fixed: `logoheader` now points at a
         **mark-only** `logo-header.svg` (the 62×44 slot rendered the full lockup's wordmark at
         ~4 px). `MAPEO.md` was rewritten to describe reality and moved beside `server.css`.
         Dead code removed: `body.aps-hc` (stamped by `apsconecta_tablero`, an app that exists
         nowhere) and a dangling "B10 regression" citation (`BUGS.md` defines B-001…B-007).
   - [x] **P2 — Fold results into docs.** ✅ Done. New [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md)
         (rules + full knob inventory + verification). `MAPEO.md` → `themes/apsconecta/`,
         `INSTALACION-NEXTCLOUD.md` → [`docs/BRANDING.md`](docs/BRANDING.md). Deleted from the kit:
         `PLAN-IMPLEMENTACION.html`, `doc-page.js`, `README-BRANDING.md`, `theme-custom.css`.
         ADR-0001 gained a second Corrections entry and its Pending section is closed.
   - [x] **P4 — Gates.** ✅ Done, both verified in each direction. `scripts/smoke.sh` greps the
         `/status.php` body it already fetched for `Nextcloud`. `scripts/test.sh` now *parses*
         every theme SVG — added after a malformed one (double hyphen in an XML comment) was
         served with a 200 and rendered nothing while every gate stayed green.
   - [x] **P5 — Kit loose ends.** ✅ Done. `theme-custom.css` deleted. Canonical header art is
         `themes/apsconecta/core/img/logo/logo-header.svg`; the kit's `logo-header.svg` is design
         reference only.
   - [x] **P3 — Governance.** ✅ Done. [`docs/adr/0000-inherited-decisions.md`](docs/adr/0000-inherited-decisions.md)
         defines `AD-1/2/4/5/6/7/9/10` in one file — they were cited in ~19 places and defined in
         none. No citation was rewritten. `ADR-iconos`, cited with no home, is folded into ADR-0001
         § *Per-app icons*.

   **Fixed along the way, not originally planned:**
   - **Black text and inverted icons over the violet backdrop** — the bug that prompted this pass.
     Root cause was a config contradiction, not CSS: `background_color` was `#ffffff` while the
     background image is violet, and `CommonThemeTrait.php:82` derives the backdrop text colour
     (and `:83` the icon inversion) from *that value*, not from the image. Now `#5315a8`.
   - **The brand background image had never been visible.** `server.css` painted a light gradient
     over `body`/`#content` that covered it completely; P1's "reads as a subtle wash" was judging
     our own gradient. The wash is deleted, so `background.svg` finally shows.
   - **`defaults.php` deleted.** ADR-0001 kept it for `getiTunesAppId()`, claiming no config key
     could do it. False: `occ config:system:set customclient_ios_appid ""` does exactly that, and
     the opcache container restart — the ADR's headline accepted cost — went with it.
   - **A latent `lib.sh` bug:** `config_system_set`/`app_config_set` could not set a key *to* an
     empty string, because an unset key and an empty one read back identically, so the guard
     skipped the write. It silently no-op'd the iOS-banner fix. Now the read's exit status is
     checked.
   - **`side_menu` installed** for sidebar navigation, via `ensure_app` in the same phase.
   - **Zero per-app icon overrides needed** — measured; and ADR-0001's "lacks `currentColor`" half
     of the clash criterion was itself wrong.

   - [x] **P6 — The three loose ends, closed 2026-07-28.** They had been carried as prose in this
         file and in PR #47's *Not done*, with no issue holding them, so they were cleared before
         merge rather than after.
         - **The `eurooffice` name.** Fixed for the sidebar entry and page title. The reason this
           file previously gave for not fixing it was wrong: it is not reachable by l10n at all —
           `lib/AdminSection.php`'s `getName()` returns a bare literal with no `t()` call. Two
           line-scoped `sed`s in `make office-eurooffice`, plus an unconditional gate in
           `office-smoke.sh`, because `sed` exits 0 on no-match and would fail silently. No
           container restart needed (`opcache.validate_timestamps=On`). Vendoring the app into git
           was rejected on measurement: 11 MB, 410 files, and it would pin the version. The
           settings *page body* keeps ~20 upstream strings — B-008, deliberate.
         - **Responsive at 360 px.** Verified; the theme passes. `resize_window` is a no-op under
           this window manager — which is exactly why the previous pass could not confirm it — so
           the width is now checked before judging, with a 360 px same-origin iframe as the
           substitute. The one clipped heading is Nextcloud's designed `text-overflow`: it clips
           with the stock font stack too, so it is not attributable to Fraunces.
         - **Backdrop contrast sweep.** Zero findings across six surfaces; every text on violet is
           white at 10.29:1 or 5.91:1. Recorded in `docs/THEMING-MODEL.md` §5 **as a sample, not a
           proof**, with its uncovered surfaces named. Two product-name leaks turned up instead and
           went to B-008 — one of them on `/settings/user`, so user-visible, not admin-only.
3. **Epic retrospectives** (optional).

## Future

Post-v1 roadmap (from the brief/PRD): white-label **branding** *(shipped as Epic 5, above)* ·
**REM app** (first Layer-2 custom app — **in progress**) → full-text **search** → **Paperless-ngx** →
**Analytics** → local **AI** layer.

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
