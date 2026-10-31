<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0023 — Ship the stable34 search identity fix through signed releases

Accepted, 2026-10-31.

The supported store provider `files_fulltextsearch` 34.0.2 regex-escapes a canonical
staff UID before using it for native user/file lookup. The by-IP probe in
[run 41188524928](https://github.com/APS-Conecta/gestion/actions/runs/41188524928)
confirms the exact uploaded document and body term are indexed, then receives no
matching result for dotted non-admin `beto.prueba` within 30 seconds. The
[upstream stable34 correction](https://github.com/nextcloud/files_fulltextsearch/pull/463),
commit `26bd54ddcec5e26b1e5e905d7417910d2a6a0baf`, is merged but unpublished.

Use `APS-Conecta/files-fulltextsearch` for this provider through the existing
signed release, verification and per-server lock channel (ADR-0017). The base
search app and Elasticsearch connector remain store rows. This explicitly amends
the original three-store-row criterion in #185; #241 records the dependency.
The fork preserves the app ID, namespace, NC34 compatibility, licence and
interface. Its runtime correction is the upstream fix. Core and store packages
are not patched, and the existing app-signing identity remains unchanged.

Waiting for an upstream publication would leave normal staff identities without
the required search result. Renaming staff or weakening the exact result probe
would not implement the product contract. The signed fork uses the established
acquisition channel and keeps its small source difference reviewable.

Acceptance keeps the same non-admin upload, indexed body and exact
provider/file-ID/path/type search predicate. Only read searches repeat within a
bounded visibility window; indexing runs once. Release signature/content checks
and both complete installation jobs still gate adoption.

Returning to the store requires a supported NC34 publication containing the fix
and a deliberate, tested channel and lock migration through the normal update
and backup process. Repeat the same acceptance against that package before
retiring the fork; installation never switches channels automatically.
