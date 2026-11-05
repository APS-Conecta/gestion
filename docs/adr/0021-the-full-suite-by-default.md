<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0021 — The full suite by default

Accepted, 2026-11-04. Part of #278.

Every establishment receives Office (Euro-Office), Talk, full-text search, previews (Imaginary),
antivirus (ClamAV) and AppAPI through HaRP. The install switches each of them on through AIO's own
switches and asks no component questions. Afterwards, AIO's page keeps vanilla's options form, as
upstream ships it ([ADR-0026](0026-upstream-plus-the-keep-list.md)). Farmacia, Estadística and
Tótem remain optional apps. Talk recording is on for a server that passes the recording threshold,
which the Bootstrap keeps beside its hardware floors (`aps/bootstrap/install.sh`).

Talk, the Office connector and the other component apps use their official store packages
([ADR-0025](0025-use-official-application-packages.md)). Container presence alone is not evidence
that an integration works: readiness and acceptance check each one.
