<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0018 — Nothing is baked; the store opens scoped

Accepted, 2026-10-25.

## Context

The bake ([ADR-0017](0017-apps-install-from-their-own-releases.md) called it "the interim") put
VENDOR-pinned tarballs of the store apps — calendar, contacts, groupfolders, notify_push, spreed —
inside the Nextcloud image, assembled from the old gestion's `provisioning/apps` at build time.
That channel bought one thing: with the store baked off, no app could move after the image was
cut. It cost three: a second repository between the suite tag and the release (the gestion freeze
window), a second trust chain (VENDOR sha256 pins, never signed), and a stale version on every
install until someone rebuilt the image.

With every own and fork app on its own signed release ([ADR-0017](0017-apps-install-from-their-own-releases.md)),
the bake's remaining payload was exactly the store apps — the one set whose upstream is the store
itself, and the one set that never needed our signature in the first place.

## Decision

**No image carries an app.** The Nextcloud image carries the apsconecta theme from the tag tree's
own `themes/apsconecta` and nothing else of the suite's. The old vendored-tarball path is deleted
with everything it fed: `scripts/bake.sh`, the gestion clone in the Images workflow, the
`gestion-ref` input, `provisioning/apps` in the composite package, `.paquete.json`'s gestion
provenance, and the old gestion's freeze window in the release ritual.

**The store is closed by default, and opens for one command at a time.** The image sets
`NC_appstoreenabled="0"` as an ENV entry; the shipped server's `Config.php` harvests `NC_`-prefixed
env vars into a cache that outranks `config.php`, so every store leg — occ, cron, the admin UI —
fails fast with no key to forget. The one override rides the same channel in the opposite
direction: a command that prefixes its own `NC_appstoreenabled=1` (an env assignment on the occ
process, `docker exec -e` from the host) opens the store for that process alone and dies with it.

Three openings exist, and only three:

- **The entrypoint installs notify_push and Talk when they are missing** — the two apps a first
  boot needs before provisioning has run (the push sibling's start dies without the binary), and
  the only apps whose install moment is a container boot rather than a provisioning run.
- **Phase 12 installs the store rows** (calendar, contacts, groupfolders) through `occ_store` in
  `provisioning/lib.sh` — the scoped seam, the same per-command open.
- Nothing else. A bare `occ app:install` fails against the image ENV; the acquisition gate's 042
  rows pin that no bare install survives under `provisioning/` and that no update leg ever carries
  the prefix.

**Store apps are installed once, never updated in place.** Convergence for a store row is presence
and enabled state, not a version: nothing in the suite updates a store app, so a warm server keeps
its bytes until the operator acts. This is deliberate — user story 18's "apps change only when I
decide" — and it is the same posture the bake enforced, minus the rebuild.

**Every update path keeps the store closed, and AIO's automatic app updates are off.** The
Saturday `app:update --all` leg is deleted from the entrypoint (not gated: gone), the env that
armed it is no longer passed by the mastercontainer, and the upgrade-path `app:update --all` calls
that remain are inert by construction — the store fetch answers empty with the store off. Apps
move in exactly two ways: a new suite tag for the image-borne halves, and `aps-conecta actualizar`
(#46) for the lock.

## Consequences

- The release chain has one source of truth: the tag. The Images workflow's four real builds check
  out the tag, the Dockerfile copies the theme from it, and the composite package archives it — no
  second repository, no freeze window, no `gestion-ref`.
- A first boot needs the app store reachable from the server (the two entrypoint installs); a
  CESFAM network that blocks `apps.nextcloud.com` will see those two installs fail loudly — the
  acceptance's own arm — rather than a silently degraded push/Talk.
- A store app that goes incompatible with a Nextcloud major upgrade is disabled by the upgrade
  dance, not silently replaced: the repair is a deliberate `occ app:remove` + re-provision (the
  scoped install fires again), or a future `actualizar` extension if operators ask for it.
- The store's own `signature.json` stays true for store apps (unmodified upstream, nothing patches
  them), so the integrity check stays green by construction.
- The clean-boot rehearsal owns the acceptance: nothing baked at first boot, the store apps
  installed, a bare `app:install` refused, and no `UPDATE_NEXTCLOUD_APPS` in the container — the
  acquisition gate's 042 rows pin the same in the tree, on every push and tag.
