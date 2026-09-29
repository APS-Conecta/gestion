# ADR-0020 — the storage root is named for staff, and the engine resolves it by configuration

- **Status:** accepted (2026-09-28, with the IntraVox Phase 5 plan's approval). Extends
  `0015-welcome-content-seeds-through-an-ungated-own-app-phase.md` (the mount stays a group
  folder) and `0019-the-welcome-tree-is-declared-and-converged-per-section.md` (the seed sets the
  name the way it sets everything else: before the engine runs).
- **Affects:** `scripts/env.sh` (`IV_MOUNT`), `provisioning/phases/41-intravox.sh` (sets the
  engine's `groupfolder_name` before `intravox:setup`, refuses an unrenamed install, looks the
  mount up by the name), `scripts/divergence.sh` (declares it, and reports an unrenamed one
  instead of offering to delete it), `scripts/provisionador.py` (the sandbox derives the folder
  row from the appconfig row), the two seeded pages that tell staff where content lives, and the
  IntraVox engine's `MountName` (one configurable value behind every resolver, the one path
  stripper and the Files links).

## Context

A reader or editor following any link had no way to learn that the content is editable files in
a group folder, because nothing in the content said so — and the folder they would browse was
titled «IntraVox», an app name, not something staff recognise as «our pages» (review L0-02). The
engine hard-coded that name in ten places (L1-01), two of them the path strippers that would
silently break on a rename (L2-03).

## Decision

1. **The engine resolves the mount by configuration.** One app value, `groupfolder_name`,
   default `IntraVox` so no existing install moves; one class (`MountName`) behind every
   resolver, the one path stripper, and the Files links every page now carries.
2. **The seam names the root «Intranet»** (`IV_MOUNT`) and tells the engine before the mount
   exists. Group names (`IntraVox Admins/Editors/Users`) are unchanged: they are groups, not the
   folder, and nobody browses them.
3. **An existing install renames by a runbook, never by the seed.** Three commands the platform
   already has (`config:app:set` → `groupfolders:rename` → `intravox:reindex`), documented in
   `docs/WELCOME-SCREEN.md`; the seed refuses to run while the old name exists, because setup
   would otherwise create a second, empty mount beside the real one.
4. **Content says where it lives.** Bienvenida and Cómo publicar name the folder and the page
   menu's «Abrir en Archivos»; the storage stays a group folder — the per-page ACL model rides
   on it.

Rejected: an `occ intravox:rename-mount` command (three lines of shell wrapped in eighty of PHP);
keying the engine on the folder id (a multi-site registry is a different decision); moving pages
out of the group folder (orphans the RESTRICTED_PAGES permissions).

## Consequences

- A clinic's staff open Files and see «Intranet» beside their sector folders; every page is one
  click from its folder.
- A rename is one variable on the seam and one app value in the engine — and, for an install
  that predates it, one deliberate runbook (`groupfolders:rename` included).
- The engine's tests pin the default, the configured value, and the stripper under both names;
  the seam's gate pins that both readers share `IV_MOUNT` and that the sandbox derives the folder
  from the same appconfig row.
