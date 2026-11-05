<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0020 — Component apps come with their component

Accepted, 2026-11-05. Part of #278.

Talk, the Euro-Office connector, the full-text search apps, the antivirus app and notify_push are store apps that AIO
installs with its own components: each comes with its component's switch, which the components step sets
([ADR-0021](0021-the-full-suite-by-default.md)), and notify_push with AIO's notify-push container. AIO's Nextcloud
container installs each at its start and updates it the vanilla way
([ADR-0018](0018-nothing-baked-the-store-is-open.md)). The Suite manifest does not list them, and the Provisionador
installs none of them.

The exception is full-text search's files provider, files_fulltextsearch: it is a fork app
([ADR-0023](0023-the-search-provider-is-a-fork-app-until-the-store-ships-its-fix.md)), so the Suite manifest pins it
and the apps step installs its App release in place of the store copy AIO installed.
