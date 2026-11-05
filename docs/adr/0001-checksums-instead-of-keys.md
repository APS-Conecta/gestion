<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0001 — Checksums instead of keys

Accepted, 2026-11-05. Part of #278.

## Context

A suite release installs its own and fork apps from their App releases on GitHub
([ADR-0017](0017-apps-install-from-their-own-releases.md)). A server must install exactly the bytes the suite
release was tested with. Signing keys would answer that with a key in every app repo, a key on every server, a signing
tool beside it and a rotation for each.

## Decision

**A suite release pins each App release by its checksum.** The Suite manifest (`aps/provisionador/apps.json`) holds,
for each own and fork app, its App release's tag and the SHA-256 checksum of its tarball, and a suite release installs
the manifest of its own commit. The Provisionador downloads the tarball from GitHub and installs it only when its
checksum is the pinned one; a download that does not match is refused with its reason, and nothing of it is
installed.

**No signing keys.** No key, signify or minisign is on a server or in a release. The suite release itself reaches a
server as the Bootstrap it publishes, which pulls our mastercontainer by digest.

**The pin tool**, `aps/release/pin.py`, writes an app's pin from its GitHub Release: the release's tag and the
checksum GitHub gives its tarball.

## Consequences

- A new App release reaches a server only through a suite release that pins it, after the release gate.
- An App release whose tarball changes after it was pinned is refused everywhere; a new pin is a reviewed commit.
- An app repo publishes its App releases with no secret of the suite's.
