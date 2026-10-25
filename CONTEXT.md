<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# APS Conecta Gestión

The suite repo: the bootstrap, the AIO fork, the Provisionador, the host CLI and the suite manifest.

## Language

**Suite**:
«APS Conecta Gestión», everything one establishment installs.

**Establishment** (establecimiento):
One CESFAM, CECOSF or SAPU, with one installation of the suite.

**Suite release**:
A signed version of the suite repo: bootstrap, images, theme and data. It contains no apps.

**Own app**:
An app whose code lives in an APS-Conecta repo.

**Fork app**:
An upstream app kept as an APS-Conecta fork, with our changes as commits.

**Store app**:
An unmodified upstream app from the Nextcloud app store.

**Default app**:
An app installed on every establishment, without a question.

**Optional app** (aplicación opcional):
An app offered in the Provisionador, off by default.

**App release**:
A GitHub Release of an own or fork app with four assets: `<id>.tar.gz`, `info.xml`, `SHA256SUMS` and
`SHA256SUMS.minisig`, signed with the app key (`apps.pub`).

**Suite manifest** (`apps.json`):
The only list of the suite's apps. Every installer step and gate reads it; `scripts/apps.py` validates it.

**Lock file**:
The per-server record of the installed app tags (`/opt/aps-conecta/apps.lock.json`, written by the
app-release resolver and moved only by `aps-conecta actualizar`; see ADR-0017).

**Provisionador**:
The web wizard that runs the install.

**Brand token file** (ficha de tokens de marca):
`themes/apsconecta/core/css/tokens.css` — the ONE committed source of the palette and the font
pairing. The server theme, the wizard's generated block, the branding phase, the Provisionador's
UI and the brand gate read it; no other file may carry a brand hex (row 270).
