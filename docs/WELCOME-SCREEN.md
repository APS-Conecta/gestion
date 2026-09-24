# The welcome screen — operator and editor guide

The welcome screen is the intranet surface every staff member lands on: the IntraVox app
rendering the pages seeded by `provisioning/phases/41-intravox.sh` from the payload under
`provisioning/intravox/es/`. This document is for the two people who will touch it after the
seed: the **operator** (who runs `make seed` and reads the gates) and the **editor** (who
publishes news and avisos). Spanish strings are quoted as they appear on screen.

## What seeds, and when

Phase 41 runs on every `make seed`, on every clinic, ungated — the welcome structure is not a
fixture. In order it: runs the engine's own setup (groups `IntraVox Admins/Editors/Users` + the
`IntraVox` group folder, no demo content), maps registry groups into engine groups
(all-staff → Users; cat-jefaturas + role-oirs → Editors; adds-only, never removes), imports the
`es` page tree with the clinic's identity substituted (name, short name, comuna, servicio), and
writes the page ACLs for the restricted pages.

**Import-once:** the import guard is the presence of `es/home.json` in the IntraVox group
folder. A second `make seed` logs `welcome: es tree already imported` and writes nothing.
Everything staff create or edit under the tree is data and survives every re-seed.

## The editorial workflow

1. **Draft** — an Editor creates a page under `noticias/` (news), `noticias/avisos/` (avisos)
   or the team's own folder under `equipos/` (team news), and leaves it in draft.
2. **Review** — Dirección or OIRS reviews before publication.
3. **Publish** — the page appears in the news areas that read its folder: the homepage's
   «Avisos» list and «Noticias» carousel, the «Noticias» hub, or the team page's news widget.

**Avisos expire editorially** — there is no auto-expiry. When an aviso lapses (the campaign
ended, the deadline passed), an Editor flips it back to draft. The duty is written into the
seeded guide «Cómo publicar» and modelled by the seed «Aviso de ejemplo»; review your avisos
weekly.

**Photographs** require documented consent before publication. No patient photos, no staff
photos without authorization («Las fotografías se publican con consentimiento del equipo»).
The seeded «Vida CESFAM» images are placeholders.

## Page budget

The engine keeps a working set of pages; this deployment budgets **≤ 50**:

- 19 fixed seeded pages + one per `SITE_TEAMS` entry (12 at the pilot = **31**).
- Drafts count. Trash does not (empty it when deleting for real).
- Editors creating content should publish under the existing folders (news, avisos, team
  folders) rather than new top-level folders.

## Recovery — when the tree must be reseeded

The documented recovery for a broken or half-imported tree:

1. As a group-folder admin, delete the `es` tree inside the `IntraVox` group folder
   (export anything you want to keep first — **staff edits under `es/` are lost**).
2. `make seed` — the tree returns with the clinic's identity and the seed pages.

Template evolution (an edited payload in `provisioning/intravox/es/`) does **not** flow to
already-seeded instances — import-once is deliberate. Changed templates ship as **new pages**;
only the recovery reseeds the fixed tree.

## Team changes

Teams come from `SITE_TEAMS` in `sites/<slug>/site.sh`. A new team's page + ACL rules arrive
only through the recovery path above (the import is one-shot); a content-only fix on an
existing team page is an ordinary edit. `docs/adr/0016-personal-layer-stays-page-level.md`
records why the personal layer stays page-level.

## Divergence tolerances

`make divergence` tolerates, by design: the three engine groups (`IntraVox Admins/Editors/
Users`) and the `IntraVox` group folder — both created by the engine's setup, mapped by
phase 41 (`docs/adr/0015-welcome-content-seeds-through-an-ungated-own-app-phase.md`). They
appear in no site file and no phase-20 registry.

## Promotion Milestone

The app ships lab-only until promotion: `defaultapp` stays `dashboard,files`, the app is not in
`OWN_APPS`, no vendored tarball. The promotion commit (after validation and pilot sign-off) is
a documented checklist — see `docs/adr/0014-intravox-is-the-default-landing-app.md` and the
plan's Promotion Milestone appendix: tag → tarball + VENDOR → OWN_APPS line → LICENSING row →
`defaultapp` flip → uninstall self-test → browser-open proof first.
