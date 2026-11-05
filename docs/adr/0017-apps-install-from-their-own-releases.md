<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0017 — Apps install from their own releases

Accepted, 2026-11-05. Part of #278.

## Context

The suite's own apps (epidemiologia, territorio and files_upload_guard, and the optional farmacia, estadistica and
totem) and its fork apps (IntraVox and files_fulltextsearch) live in APS-Conecta repos, each publishing App releases
on GitHub. A suite release carries no app files, and every establishment that installs it must get the same apps.

## Decision

**Each own and fork app installs from the App release its suite release pins**, at the tag and checksum of the Suite
manifest ([ADR-0001](0001-checksums-instead-of-keys.md)). The Provisionador downloads the app's tarball from the
release's download address, with no token and no API call, refuses it unless its checksum is the pinned one, and puts
it in Nextcloud's apps folder in place of any copy there, which Nextcloud upgrades as it enables the app:

- «Aplicaciones», a core install step, installs the default apps;
- «Aplicaciones opcionales», an optional step, which the runner runs after every core step, installs the optional apps
  ticked at «Revisar», off by default.

An app that fails is named with its reason while the others install, and «Reintentar» installs again. The
end-of-install check confirms that each of them runs its pinned version.

**The pin is the version.** Nothing looks for a newer release and nothing keeps a lock file.

## Consequences

- Every establishment on a suite release runs the same app versions, and a rerun installs the same bytes.
- An app moves only with a suite release that pins its new App release.
- An App release stays on GitHub, at its tag, for as long as a suite release pins it.
