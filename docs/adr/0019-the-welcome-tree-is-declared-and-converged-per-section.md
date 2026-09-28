# ADR-0019 — the welcome tree is declared per site and converged per section

- **Status:** accepted (2026-09-27, with the IntraVox Phase 3 plan's approval; decision 3's
  "later seeds stage only what is new" added 2026-09-28 at implementation, by the owner).
  Supersedes the import-once decision (D2) of
  `0015-welcome-content-seeds-through-an-ungated-own-app-phase.md`; that record stays as written.
- **Affects:** `sites/<slug>/site.sh` (`SITE_WELCOME`), `scripts/deis.py` (its writer),
  `provisioning/seed.sh` (its guard), `provisioning/intravox/render.py` (the renderer),
  `provisioning/intravox/es/` (now a section library), `provisioning/phases/41-intravox.sh`
  (steps 4–5), `scripts/divergence.sh` (the report), and the IntraVox engine's
  `occ intravox:import --skip-existing` (`ManagedTreeImporter`).

## Context

ADR-0015 seeded one fixed tree into every clinic and guarded it whole: once `es/navigation.json`
existed the phase never touched the tree again, and the only way to change its shape was to
delete `es/` and reseed — losing every staff edit underneath. Three things were wrong with that,
found by the 2026-09-27 architecture review of the welcome program (L0-01, L0-05, L0-06, L0-07,
L1-07, L1-08):

- the developer never chose what existed — every clinic got `equipos` with ten hand-written team
  pages beside the dynamic `SITE_TEAMS` pages, and quick-access links that assumed the pilot's
  folder tree;
- structure could not evolve without data loss, because the guard was all-or-nothing;
- the engine's importer overwrote every existing page whenever it ran, so a missing marker was
  one reseed away from flattening editorial work while every gate stayed green.

ADR-0015's principle — staff edits are page data, never overwritten — was right. Its mechanism
(import once, guard the whole tree) was what made structure frozen.

## Decision

1. **The tree is declared per site.** `SITE_WELCOME=( 'section|flag' … )` in `sites/<slug>/site.sh`
   names the sections that exist, in order. `scripts/deis.py` writes the default —
   `noticias|wall`, `vida-cesfam|`, `documentos|wall` — and writes no `equipos`: a clinic declares
   it (`'equipos|wall'`) and gets the hub plus one page per `SITE_TEAMS` entry. The flag is the
   protection attribute (`wall` = fixed structure, empty = editable); Phase 4 of the same review
   enforces it. `seed.sh` refuses a site file that leaves `SITE_WELCOME` unset.
2. **One renderer.** `provisioning/intravox/render.py` turns the declaration, the identity block,
   `SITE_TEAMS` and `SITE_SUBFOLDERS` into the staged tree: sections are copied from the library
   (`provisioning/intravox/es/sections/<name>/`), the Documentos links are the declared subfolders,
   the menu and the footer list exactly the declared sections, and the home page's quick-access
   row is three fixed app tiles (Recepción → the Transversal folder, Gestión y turnos, Teléfonos)
   plus one tile per declared section. It fails closed —
   an unknown flag, an undeclared section, a team whose folder the site does not declare, a
   Files link to a folder the site does not have, a page that is not JSON — with one `FATAL`
   line. Every site value is JSON-escaped on the way in, so a name with a quote renders as itself. The hand-written team pages are gone: a team
   page is a declared entry.
3. **Per-section convergence.** The marker of a section is its own hub page
   (`es/<section>/<section>.json`); of a team page, `es/equipos/<gid>/<gid>.json`; of the core
   files, `es/navigation.json` as before. The first seed imports the whole rendered tree; a
   later seed imports only what is new — the new sections, and a new team's page — always with
   `occ intravox:import --skip-existing`. What is declared and missing is created (and logged
   `created`); what exists is left exactly as found (logged `exists`), and so is what staff
   deleted inside an existing section: re-importing a whole section would re-create a seeded page
   someone removed on purpose, so an existing section is never re-imported. A section live on
   disk but absent from the declaration is reported by `scripts/divergence.sh` — never deleted.
4. **Core files render once.** `home.json`, `navigation.json` and `footer.json` are staff-editable
   after the first seed, so a section declared later is imported and the seed asks for its menu
   entry and tile by hand. Nothing is merged into staff data.
5. **The engine never overwrites on the managed path.** `--skip-existing` is the engine-side
   guarantee, unit-tested; the seam always passes it and fails loudly on an engine that lacks it.
   `occ intravox:import` is the one managed content path; editors' ZIP/Confluence imports are a
   different audience with their own conventions and stay separate.

## Consequences

- Adding a section or a team is one line in the site file and a `make seed`; nothing else on the
  instance changes — a sample page staff deleted stays deleted. Removing a row changes nothing on the instance until a person deletes the
  folder; `make divergence` names it.
- ACL rules for a team page are written when that page is created, never rewritten: the team
  reads it, `cat-jefaturas` reads it (the oversight the retired restricted pages had, now every
  team page's), everyone else is denied. A seed that dies between import and rules leaves that
  page without them — the recovery is per page, not delete-`es/`-and-reseed.
- Site files written before this decision must gain the `SITE_WELCOME` block by hand
  (`deis.py` refuses to rewrite an existing site); the lab box declares `equipos` to keep converging
  its existing team pages, or leaves it undeclared and reads the divergence note.
- Fresh clinics seed fewer pages (no `equipos` unless declared); the ≤ 50 page budget stands.
- Library changes do not reach an existing section: an edited page, a new sub-page or a new image
  in `provisioning/intravox/es/sections/<name>/` lands only on instances that do not have that
  section yet. Template evolution ships as new sections.
- `docs/WELCOME-SCREEN.md` § "What seeds, and when", "Recovery" and "Team changes" describe the
  converging seed; the import-once wording there is retired.
