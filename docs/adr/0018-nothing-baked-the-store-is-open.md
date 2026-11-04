<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0018 — Nothing is baked; the store is open

Accepted, 2026-11-04. Part of #278.

## Context

The Nextcloud image is Upstream's with the one-click-instance user-cap removal on top, and nothing
else ([ADR-0026](0026-upstream-plus-the-keep-list.md)). Upstream's image keeps the app store open, and
AIO's update machinery updates the store apps.

## Decision

**No image carries an app.** The suite's own and fork apps arrive from their own releases
([ADR-0017](0017-apps-install-from-their-own-releases.md)); nothing of the suite's is built into
the Nextcloud image.

**The store is open, as in vanilla.** Administrators can install and update any store app, and
store apps update the vanilla way: AIO's update machinery runs `occ app:update --all` on an
upgrade and, when the daily backup runs with automatic updates on, every Saturday.

## Consequences

- The store's own `signature.json` stays true for store apps (unmodified upstream, nothing patches
  them), so the integrity check stays green by construction.
- A store app can move between suite releases. Keeping the own and fork apps at their pins when the
  store updates is the apps work in #289.
- A first boot needs the app store reachable from the server, as vanilla's does.
