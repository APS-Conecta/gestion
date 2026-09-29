# The welcome screen — operator and editor guide

The welcome screen is the intranet surface every staff member lands on: the IntraVox app
rendering the pages seeded by `provisioning/phases/41-intravox.sh` from the payload under
`provisioning/intravox/es/`. This document is for the two people who will touch it after the
seed: the **operator** (who runs `make seed` and reads the gates) and the **editor** (who
publishes news and avisos). Spanish strings are quoted as they appear on screen.

## What seeds, and when

Phase 41 runs on every `make seed`, on every clinic, ungated — the welcome structure is not a
fixture. In order it: runs the engine's own setup (groups `IntraVox Admins/Editors/Users` + the
`Intranet` group folder — the engine's mount, named by `IV_MOUNT` and told to the engine before
setup, ADR-0020 — no content), maps registry groups into engine groups (all-staff →
Users; cat-jefaturas + role-oirs → Editors; adds-only, never removes), renders the tree the site
**declared** (`SITE_WELCOME`, below) with the clinic's identity substituted, imports what is
declared and missing, and writes the page ACLs for the team pages it just created.

**Converging, not import-once** (`docs/adr/0019-the-welcome-tree-is-declared-and-converged-per-section.md`):
every seed adds the declared sections and team pages that do not exist yet and leaves everything
that exists exactly as found. The first seed stages the whole rendered tree, a later one only the
new sections and team pages; either is copied into the Nextcloud container and imported there as
`www-data` with `occ intravox:import /tmp/intravox-welcome-es --language es --user admin
--skip-existing` — the one managed content path (editors' ZIP imports are a different door), and
the engine is told never to overwrite. A second `make seed` logs `welcome: section noticias
exists` for each row and writes nothing. Everything staff create or edit under the tree is data
and survives every re-seed — and so does what they delete: a seeded page removed from an existing
section stays removed. The home page, the menu and the footer are rendered on the first seed
only; after that they are yours to edit.

## Declaring the tree

`sites/<slug>/site.sh` carries one row per section, in the order they appear in the menu:

```bash
SITE_WELCOME=(
  'noticias|wall'      # section|flag — wall = fixed structure, empty = editable
  'vida-cesfam|'
  'documentos|wall'
)
```

`scripts/deis.py` writes this default for a new site. Sections are folders of the library under
`provisioning/intravox/es/sections/`; `equipos` is the one section that is generated instead of
copied — declare `'equipos|wall'` and the seed renders the «Guía de equipos» hub plus one page per
`SITE_TEAMS` entry, each linking the team's own folder and readable by that team and the
jefaturas. A role-restricted page (OIRS, Estadística REM) is a team row you add by hand, e.g.
`'role-oirs|OIRS'`; its page links the one declared folder named after it (`Unidades/OIRS`), and a
team whose folder the site does not declare stops the seed. The Documentos page links exactly `SITE_SUBFOLDERS`; the menu and the footer
list the declared sections and nothing else; the home page's quick-access row is three fixed app
tiles (Recepción y admisión → the Transversal folder, Gestión y turnos, Teléfonos y anexos)
followed by one tile per declared section. A row the library does not know, an unknown flag, or a
page that would link a folder the site does not have stops the seed with a `FATAL` line before
anything is imported. What `wall` does is described under «Walls» below.

**A site file written before this block existed** stops `make seed` with
`FATAL: sites/<slug>/site.sh must set SITE_WELCOME`. Add the block above by hand — `deis.py`
never rewrites an existing site file. On an instance already seeded with the old fixed tree,
`equipos` is live: declare `'equipos|wall'` to keep converging its team pages, or leave it out and
`make divergence` lists it; nothing is deleted either way.

**Adding a section later:** add the row, `make seed`. The seed logs `welcome: section <name>
created — add its menu entry and home tile by hand` — the menu and home page are staff data by
then, so the seed does not touch them; add the entry in the admin menu editor. **Removing a
row** changes nothing on the instance: `make divergence` lists the section as live but
undeclared, and a person deletes the folder if that is intended.

**Walls.** A section declared `wall` is fixed structure: the seed stamps `"protected": true` on
its structure — the section's hub, every seeded page that has sub-pages (noticias' «Avisos», which
the home's Avisos list reads), and for `equipos` the hub plus every team page — and the engine
refuses to delete or move such a page: the page menu and the tree do not offer it, and a direct
request answers `PAGE_PROTECTED`. A wall is still editable, its title included, but its folder
cannot be renamed (the seam and the home's news widgets find a section by its folder), and
restoring an older version keeps the wall. The seeded example posts («Aviso de
ejemplo», «Bienvenida», «Cómo publicar») are not walls: like every post staff create later they
are ordinary pages an editor can delete. The marker is per page, never a folder rule (the
review's «seam writes no-delete ACL rules» was not followed — a group-folder rule would inherit
onto every staff post in `noticias`, and nobody but administrators can delete under the seeded
ACLs anyway). Removing a wall is a two-step for an administrator, on purpose: in the container,
`occ intravox:protect <uniqueId> --off --user admin` (a version is snapshotted first), then delete
or move the page; `--on` restores it and `--status` shows the state. An instance seeded before
walls existed has no marker on its pages (the seed never rewrites an existing page): raise each
with `occ intravox:protect <uniqueId> --on --user admin`. The marker lives in the page JSON, so
administrator tools that work below the page API ignore it: the **Files app** (a group-folder
admin can still delete the folder — the recovery procedure below relies on exactly that), a ZIP
import with overwrite, and the admin clean-start reset.

## Renaming the storage folder on an existing install

New installs get the folder name from `IV_MOUNT` (`scripts/env.sh`, default «Intranet»;
overridable in `.env`): phase 41 writes it into the engine (`occ config:app:set intravox
groupfolder_name`) before `intravox:setup` creates the mount, and every page's «Abrir en
Archivos» (page menu ⋯) and the sidebar's Location link open the page's folder under that name.
The seeded pages that say where content lives (Bienvenida, Cómo publicar) name the same folder:
render.py substitutes `IV_MOUNT`. An install seeded before this existed carries the engine's
default, `IntraVox`, and **the seed refuses to run against it** (`FATAL: the engine's group folder
is still named 'IntraVox' …`) — seeding would create a second, empty mount; `make divergence`
says the same instead of offering to delete it. The same refusal holds when `IV_MOUNT` later
changes on an install whose folder already carries the previous name, and for a value the engine
would refuse (empty, or with a `/`). Rename once, by hand, in this order, with no `make seed` in
between. The commands
run in the Nextcloud container as `www-data` (`occ` below). Steps 0–3 rehearsed end to end — rename,
rollback, forward again — on a throwaway Nextcloud 34 instance running the welcome-folders p5
engine (2026-09-29): their expected lines below are what it printed, and the page tree was
identical before and after each direction. Not yet run on the lab or a clinic.

0. Before anything: `occ intravox:reindex --user admin --dry-run` and note N in
   `Would index N of M page file(s) across K language(s).`
1. `occ config:app:set intravox groupfolder_name --value Intranet`. Expected: `Config value
   'groupfolder_name' for app 'intravox' is now set to 'Intranet', stored as … in fast cache`.
   From this moment the engine looks for «Intranet», so pages can answer *IntraVox folder not
   found* until step 2 — do it right away.
2. `occ groupfolders:list` → note the id of the folder mounted as `IntraVox`; then
   `occ groupfolders:rename <id> Intranet` (silent on success). Expected: the list shows
   `Intranet`. For a few seconds the web server can still answer with the previous name (the
   rehearsal's page tree said *IntraVox folder not found* once, then was identical) — reload;
   no restart is needed.
3. `occ intravox:reindex --user admin`. Expected: `Indexed N of M page file(s) across K
   language(s).` with the same N as step 0 — the index rows written under the old name are
   retired.
4. `make seed`. Expected: `welcome: section … exists` for every row, nothing created.

Rollback is the same three commands with `IntraVox`, plus `IV_MOUNT=IntraVox` in `.env` so the
seed agrees. Staff see the new name in Files at once; the page links follow the configured name
without a cache flush.

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

- The default declaration seeds 8 fixed pages; `equipos` adds one hub + one page per `SITE_TEAMS`
  entry (12 at the pilot = **21** with equipos declared).
- Drafts count. Trash does not (empty it when deleting for real).
- Editors creating content should publish under the existing folders (news, avisos, team
  folders) rather than new top-level folders.

## Recovery — when a section is broken

There is no whole-tree recovery any more, and no reason for one: the seed converges per section.

1. In the browser, as a group-folder admin, open Files → `Intranet` → `es` → the section's folder
   and choose **⋯ → Descargar**. Expected: a ZIP of the section lands in your downloads — your
   copy of every staff edit inside it, which the next step discards.
2. Same place, **⋯ → Eliminar** on that folder only. Expected: the folder disappears from `es/`
   (it sits in the trash bin for the usual retention; nothing else under `es/` changes). If the
   menu offers no delete, you are not a group-folder admin — ask one.
3. On the host, from the repo root: `make seed` (`NC_CONTAINER=…` as for every seed on the compose
   lab). Expected in the log: `welcome: section <name> created` (its «add its menu entry» hint
   does not apply here — the menu still points at the section's stable id) and, for `equipos`,
   one `team page … created` + three `acl: … rule created` per team. If it prints
   `welcome: section <name> exists` instead, the folder is still there — the trash bin does not
   count, the marker is `es/<name>/<name>.json` itself.

Template evolution follows one rule: **an existing section is never re-imported**. An edited
library page, a new sub-page or a new image under `provisioning/intravox/es/sections/<name>/`
reaches only instances that do not have that section yet, and a page or image staff deleted
inside an existing section stays deleted. Changed templates ship as new sections — or, on one
instance, through the recovery above, which discards that section's staff edits.

## Team changes

Teams come from `SITE_TEAMS` in `sites/<slug>/site.sh`, and team pages exist only when
`equipos` is declared in `SITE_WELCOME`. A new team's page + ACL rules arrive with the next
`make seed` (the page is created, the rules ride its creation); a content-only fix on an existing
team page is an ordinary edit. A team removed from `SITE_TEAMS` keeps its page until a person
deletes it — `make divergence` does not (yet) list team pages, only sections.
`docs/adr/0016-personal-layer-stays-page-level.md` records why the personal layer stays
page-level.

## Divergence tolerances

`make divergence` tolerates, by design: the three engine groups (`IntraVox Admins/Editors/
Users`) and the engine's group folder named by `IV_MOUNT` (`Intranet`, ADR-0020) — both created
by the engine's setup, mapped by phase 41
(`docs/adr/0015-welcome-content-seeds-through-an-ungated-own-app-phase.md`). They appear in no
site file and no phase-20 registry. A live `IntraVox` folder while `IV_MOUNT` says otherwise is
reported as the storage root under its old name — rename it (above), never delete it.

## Promotion Milestone

The app ships lab-only until promotion: `defaultapp` stays `dashboard,files`, the app is not in
`OWN_APPS`, no vendored tarball. The promotion commit (after validation and pilot sign-off) is
a documented checklist — see `docs/adr/0014-intravox-is-the-default-landing-app.md` and the
plan's Promotion Milestone appendix: tag → tarball + VENDOR → OWN_APPS line → LICENSING row →
`defaultapp` flip → uninstall self-test → browser-open proof first.
