<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0023 — The search provider is a fork app until the store ships its fix

Accepted, 2026-11-05. Part of #278.

The store's search provider `files_fulltextsearch` 34.0.2 regex-escapes a canonical staff UID before using it for
native user and file lookup. A by-IP install
([run 41188524928](https://github.com/APS-Conecta/gestion/actions/runs/41188524928)) confirms the exact uploaded
document and body term are indexed, then receives no matching result for dotted non-admin `beto.prueba` within 30
seconds. The [upstream stable34 correction](https://github.com/nextcloud/files_fulltextsearch/pull/463), commit
`26bd54ddcec5e26b1e5e905d7417910d2a6a0baf`, is merged but unpublished.

So `files_fulltextsearch` is a fork app: `APS-Conecta/files-fulltextsearch` keeps the app ID, namespace, NC34
compatibility, licence and interface, and its one runtime change is the upstream fix. The Suite manifest pins its App
release like every fork app's ([ADR-0017](0017-apps-install-from-their-own-releases.md)), the apps step installs it in
place of the store copy that AIO's full-text search installs, and no store update replaces it
([ADR-0018](0018-nothing-baked-the-store-is-open.md)). The base search app and the Elasticsearch connector stay store
apps that come with their component ([ADR-0020](0020-component-apps-come-with-their-component.md)). Core and store
packages are not patched.

Waiting for an upstream publication would leave normal staff identities without the required search result. Renaming
staff or accepting a non-exact result would not implement the product contract.

Returning to the store requires a supported NC34 publication containing the fix and a deliberate, tested move through
a suite release. Before retiring the fork, prove on that package that a dotted non-admin staff UID (such as
`beto.prueba`) gets the exact uploaded document as its search result for a term in its indexed body; installation
never switches channels automatically.
