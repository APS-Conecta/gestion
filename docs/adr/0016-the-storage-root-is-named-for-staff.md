<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0016 — The storage root is named for staff, and the engine resolves it by configuration

Accepted, 2026-09-28.

## Context

A reader or editor following any link had no way to learn that the content is editable files in a group
folder, because nothing in the content said so, and the folder they would browse was titled «IntraVox», an app
name, not something staff recognise as «our pages». The engine hard-coded that name in ten places, two of them
the path strippers that would silently break on a rename.

## Decision

1. **The engine resolves the mount by configuration.** One app value, `groupfolder_name`, default `IntraVox`
   so no existing install moves; one class (`MountName`) behind every resolver, the one path stripper, and the
   Files links every page carries.
2. **The seam names the root «Intranet»** (`IV_MOUNT`) and tells the engine before the mount exists. Group
   names (`IntraVox Admins/Editors/Users`) are unchanged: they are groups, not the folder, and nobody browses
   them.
3. **An existing install renames by a runbook, never by the seed.** Three commands the platform already has
   (`config:app:set` → `groupfolders:rename` → `intravox:reindex`), documented in
   [IntraVox](https://aps-conecta.github.io/documentation/desarrollo/intravox.html); the seed refuses to run
   while a folder under the old name exists (the engine's default, or the name it was told before `IV_MOUNT`
   changed), because setup would otherwise create a second, empty mount beside the real one.
4. **Content says where it lives.** Bienvenida and Cómo publicar name the folder (`IV_MOUNT`, substituted at
   render) and the page menu's «Abrir en Archivos»; the storage stays a group folder, because the per-page ACL
   model rides on it.

Rejected: an `occ intravox:rename-mount` command (three lines of shell wrapped in eighty of PHP); keying the
engine on the folder id (a multi-site registry is a different decision); moving pages out of the group folder
(orphans the per-page ACL).

## Consequences

- A clinic's staff open Files and see «Intranet» beside their sector folders; every page is one click from its
  folder.
- A rename is one variable on the seam and one app value in the engine and, for an install that predates it,
  one deliberate runbook (`groupfolders:rename` included).
- The engine's tests pin the default, the configured value, and the stripper under both names; the seam's gate
  pins that both readers share `IV_MOUNT` and that the sandbox derives the folder from the same appconfig row.
