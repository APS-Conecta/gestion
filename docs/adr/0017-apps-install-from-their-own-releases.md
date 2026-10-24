<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0017 — Apps install from their own releases

Accepted, 2026-10-24.

## Context

Own and fork apps were hand-built tarballs committed to the old gestion and baked into the Nextcloud
image: a new app version needed a manual rebuild of the whole suite, and installs shipped stale
versions (territorio was baked at 0.74.0 while 0.80.0 was already released). The suite's own
releases contain no apps on purpose ([ADR-0001](0001-two-signing-keys.md) split the keys for
exactly this), so the apps need their own channel.

## Decision

Every own and fork app installs **at run time, from its own repo's newest GitHub Release compatible
with the running Nextcloud**. The Provisionador's execution resolves it, downloads it without a
token, verifies it against `apps.pub`, installs it, and records the tag in the per-server lock file
(`/opt/aps-conecta/apps.lock.json`, inside the backup scope). Territorio is the first app on this
path (#33); each app switches as its first signed release lands, by turning on `release` in its
suite-manifest row (#34–#38).

The rules that make it safe and boring:

- **The normal path makes no GitHub API call.** The resolver follows the `/releases/latest`
  redirect — one HEAD, no body, no token. Only an incompatible latest makes it fall back to one
  releases-API call (newest first, non-prerelease, `GITHUB_TOKEN` when set), so GitHub's
  unauthenticated rate limit never bites a normal install.
- **The lock wins.** A row already recorded installs from the lock and downloads nothing: a repair
  never turns into an upgrade. A missing stored tarball re-downloads the *locked* tag. Candidates
  never fall below the lock; a `pin` takes exactly that tag.
- **Proven before unpacked.** The SHA256SUMS signature against `apps.pub` (signify — the same apt
  package the clinic verifies a suite release with), the hashes of the tarball and of `info.xml`,
  one top directory equal to the app id with nothing outside it, no `appinfo/signature.json`, and
  the tag equal to the version `info.xml` declares. Any refusal stops the install with one Spanish
  line naming the app and the retry command.
- **Review mode downloads nothing.** Only the execute path (`--paso generar`: the wizard's
  «Revisar y ejecutar», the silent install, the weekly reponer) runs the fetch leg.
- **The seed never downloads.** Phase 12 installs what the lock names, from the verified tarball
  stored beside it (`/opt/aps-conecta/apps/<id>/<tag>.tar.gz`); acquisition is the fetch leg's job,
  and convergence stays the seed's.

Until the bake is removed (#42), rows without the switch — and a release row on a server whose
wizard step has not run yet — still install from the vendored bake.

## Consequences

- A fresh install gets the newest compatible versions; a repeated provisioning is byte-stable and
  downloads nothing.
- The lock and the fetched tarballs ride the daily backup (the wizard wires `/opt/aps-conecta` into
  the backup scope), so a restored server re-installs its exact app versions with no downloads.
- A compromised app repo can sign an app, never a suite release ([ADR-0001](0001-two-signing-keys.md));
  and only releases signed with the app key install.
- `actualizar` (#46) is the only path that moves the lock deliberately: backup first, app by app,
  the lock promoted only when everything succeeded.
