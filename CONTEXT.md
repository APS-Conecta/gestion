<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# APS Conecta Gestión

The suite repo: the bootstrap, the AIO fork, the Provisionador, the host CLI and the suite manifest.

## Language

**Upstream**:
`nextcloud/all-in-one` at the release this repo last merged.

**Keep-list**:
The declared list of every place this repo differs from upstream, each with its reason.

**Suite**:
«APS Conecta Gestión», everything one establishment installs.

**Establishment** (establecimiento):
One CESFAM, CECOSF or SAPU, with one installation of the suite.

**Suite release**:
A published version of the suite repo: the bootstrap, our images, theme and data, plus the exact versions and
checksums of every official image and app it installs. It carries no app files.

**Bootstrap** (instalador de una línea):
The one-line command that installs the suite on a plain server.
_Avoid_: installer script, one-liner

**Coolify install** (instalación por Coolify):
The suite added as a resource on a Coolify server. It installs the same suite release as the bootstrap.

**Nightly update** (actualización nocturna):
The server moving itself to the newest suite release, right after its nightly backup.

**APS name** (nombre APS):
The establishment's address under `gestion.apsconecta.cl`, given by APS's name service. The default when the
establishment has no domain of its own.
_Avoid_: free domain, dedyn name

**Own domain** (dominio propio):
A domain the establishment already holds, used instead of the APS name.

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
A GitHub Release of an own or fork app. A suite release pins its tag and checksum.

**Suite manifest** (`aps/provisionador/apps.json`):
The list of the apps the suite installs beside its components' own: each own and fork app at the tag and checksum of
the App release it pins, and the default store apps. The install steps and the acceptance checks read it, and the pin
tool (`aps/release/pin.py`) writes its pins.

**Comuna data** (datos comunales):
Territorio's records of the establishment's comuna, its unidades vecinales and its health establishments. The install
cuts them from the national masters the suite release pins by checksum (`aps/comunas/packages.json`).

**Provisionador**:
The single web wizard that runs the install. During the install the operator uses no other page.

**Install step** (paso de instalación):
One idempotent part of «Instalar», a module that declares the steps it needs. A failed or waiting step shows in red
with its reason, and «Reintentar» runs only those again.

**End-of-install check** (revisión final):
The comparison of the running suite with what each install step declared. «Listo» needs every step green and this
check clean.

**Brand token file** (ficha de tokens de marca):
`themes/apsconecta/core/css/tokens.css` — the ONE committed source of the palette and the font
pairing. The server theme, the branding phase, the Provisionador's UI and AIO's page read it; no
other file may carry a brand hex.
