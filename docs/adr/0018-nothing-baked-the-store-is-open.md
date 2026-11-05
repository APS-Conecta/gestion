<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0018 — Nothing is baked; the store is open

Accepted, 2026-11-05. Part of #278.

## Context

The Nextcloud image is Upstream's with the one-click-instance user-cap removal on top, and nothing
else ([ADR-0026](0026-upstream-plus-the-keep-list.md)). Upstream's image keeps the app store open, and
AIO's update machinery updates the store apps. The suite's own and fork apps come from their pinned App releases
([ADR-0017](0017-apps-install-from-their-own-releases.md)), and two fork apps, IntraVox and files_fulltextsearch,
share their id with a store app.

## Decision

**No image carries an app.** Nothing of the suite's is built into the Nextcloud image.

**The store is open, as in vanilla.** Administrators can install and update any store app from the Apps page, and
store apps update the vanilla way: AIO's update machinery runs `occ app:update --all` on an upgrade and, when the daily
backup runs with automatic updates on, every Saturday. The default store apps arrive the vanilla way too: vanilla's
startup-apps switch, `NEXTCLOUD_STARTUP_APPS`, which the Provisionador gives AIO's start, installs them at Nextcloud's
first start.

**A store update never replaces a pinned app.** Each own and fork app's folder carries a `.git` folder, so Nextcloud
takes it for an app installed from git, for which it offers and applies no store update (`Installer::isUpdateAvailable`):
not on the Apps page, not through `occ app:update`, not through AIO's update.

## Consequences

- The store's own `signature.json` stays true for store apps (unmodified upstream, nothing patches
  them), so the integrity check stays green by construction. An App release carries no `signature.json`, so Nextcloud
  checks no pinned app's files against one.
- A store app can move between suite releases; a pinned app moves only with a suite release.
- A first boot needs the app store reachable from the server, as vanilla's does.
- The acceptance harness proves the rule on every test build: after AIO's store update, every pinned app still runs
  its pin.
