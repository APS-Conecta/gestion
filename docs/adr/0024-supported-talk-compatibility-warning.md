<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0024 — Supported Talk compatibility with an optional warning

Accepted, 2026-10-31. Part of #187 and #175.

Spreed 24.0.6 reports an optional `changed-users` warning for the latest official signaling
release, 2.1.1. Upstream [supports existing backends without this optimization](https://github.com/strukturag/nextcloud-spreed-signaling/issues/1283#issuecomment-5569150803);
its [implementation remains unmerged](https://github.com/strukturag/nextcloud-spreed-signaling/pull/1175).
Readiness retains the official release and reports this compatibility warning explicitly,
rather than adopting unpublished server code to remove it.

Accept native success or the complete native English/Spanish optional-warning message naming
only `changed-users`. Every other warning or error fails. The native key, verified HTTP, JSON,
required-feature and clock checks precede that warning. Because it returns before the Talk
cache check, additionally require the native `MemcacheConfigured` check to succeed and the
distributed backend to be the suite's Redis. Public suite-CA welcome verification remains
mandatory. This is compatible with an optional warning; it is not native severity `success`.

Remove the exception when an official supported release implements the feature, the suite pins
that release, and native acceptance confirms severity `success`. Browser-call acceptance
remains separate; these diagnostics do not certify a WebSocket or media round-trip.
