<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0020 — Spreed is a fork app with signed releases

Superseded by [ADR-0025](0025-use-official-application-packages.md), 2026-10-31.

Accepted, 2026-10-25.

## Context

After [ADR-0018](0018-nothing-baked-the-store-opens-scoped.md), spreed was the one app still
reaching the Nextcloud app store at a container boot: the entrypoint's scoped
`NC_appstoreenabled=1 occ app:install spreed` on a first boot with Talk on. That install bought
two things — no image rebuild, a working Talk before provisioning ran — and cost the supply-chain
half the doctrine everywhere else already has: the store names no version (a repair could land a
different Talk than yesterday's install), the bytes are verified by Nextcloud's own appstore
chain rather than ours, and a first boot must reach `apps.nextcloud.com` at all.

Meanwhile [ADR-0017](0017-apps-install-from-their-own-releases.md) gives every own and fork app a
deterministic, signed, locked channel — and spreed is the one app in the suite whose upstream we
do not control, which is exactly the app whose bytes we most want to pin.

## Decision

**Talk installs from our fork, never from the store.** `APS-Conecta/spreed` is a fork of
`nextcloud/spreed` with **zero code changes**: it exists to host our App releases, not to carry
patches. Its manifest row is `source: fork` with `release: true`, so the wizard's fetch leg
resolves it like every release row — newest compatible tag via the release redirect, Ed25519
(signature over SHA256SUMS against `apps.pub`), hashes, one top directory, no
`appinfo/signature.json`, tag equal to the version `info.xml` declares — and installs record in
the lock. The resolver honours Talk's own switch: with the wizard's options record saying Talk
off, spreed resolves nothing (the same gate phase 12 reads through `TALK_ENABLED`; an absent
record never turns Talk off — the wizard writes the record before any ejecutar, and a compose
install runs Talk always).

**Each App release is upstream's own release, re-proven and re-signed.** Packaging takes
upstream's newest stable release compatible with the suite's Nextcloud major — resolved from the
appstore record upstream itself publishes, downloaded from upstream's release channel — and
checks it against **upstream's own checksums** (the release asset digest GitHub publishes for
those bytes) before anything moves. The tarball is then repacked with exactly one difference a
release of ours needs: upstream's `appinfo/signature.json` is dropped (a release of ours never
carries one, [ADR-0017](0017-apps-install-from-their-own-releases.md); the appstore signature
would be false over our tarball anyway). The release publishes the four fixed-name assets —
`spreed.tar.gz`, `info.xml`, `SHA256SUMS`, `SHA256SUMS.minisig` — signed inside the fork's
`release` environment with the app key ([ADR-0001](0001-two-signing-keys.md): the app key never
leaves an app repo; the suite repo never sees it). The app's code is untouched, so upstream's
AGPL attribution travels whole.

**The suite release refreshes it.** The release chain gains a spreed step: it dispatches the
fork's refresh with the tag tree's own Nextcloud major, waits bounded for the refreshed release,
and verifies its signature against the tag tree's `apps.pub` — before the suite Release is
created. The refresh is idempotent (a tag that already exists is verified and left alone;
published assets never move), so a suite release that lands between two upstream releases costs
nothing.

**The entrypoint's scoped install is gone.** With Talk's acquisition at the provisioning run,
no boot installs spreed: the entrypoint's Talk block is presence-gated configuration alone
(enable, cert days, TURN/STUN/HPB wiring) — the same shape the Talk-recording block already has.
A first boot with Talk on therefore installs nothing of Talk's; after the fetch leg and phase 12
land the app, the configuration converges at the next boot (the reboot the update-day acceptance
and the daily backup both perform). `notify_push` remains the one app whose install moment is a
container boot, and the store's only scoped opening in the entrypoint.

## Consequences

- A first boot with Talk on no longer needs `apps.nextcloud.com` for Talk — only notify_push's
  install still does. The last first-boot reach into the store is now one app, named and
  deliberate.
- Talk's version is pinned by the lock, moves only through `aps-conecta actualizar` (#46), and a
  repair re-installs the locked bytes — the determinism every other release app already had.
- A Nextcloud major bump needs the fork's refresh to run before the suite release resolves
  spreed for it: the release chain's spreed step makes that ordering mechanical instead of a
  ritual step to remember, and a suite release without a compatible spreed release reds before
  anything is signed.
- Upstream's newest compatible release is adopted at each suite release by construction — a
  deliberate suite tag decides when Talk moves, never the store's quiet drift; between suite
  releases a clinic's Talk stays exactly where its lock pins it.
- The fork carries zero code changes, so pulling upstream (the one-tree doctrine's ordinary
  merge) is the whole maintenance story for the code; the refresh workflow, its vendored copy
  of the suite's resolver (`spreed-refresh.py`) and this suite's manifest row are the only
  things of ours that live there — and the release chain verifies every refresh against the
  suite's own resolver before a suite Release exists, so a drifted copy reds there, never on
  a clinic.
- The first release needs the fork's `release` environment and app-key secrets — owner-only,
  once, like every app repo ([aps/RELEASING.md](../aps/RELEASING.md)); the acquisition gate's
  row 145 pins the tree's half of the migration.
