<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0026 — Route the suite IP inside client network namespaces

Accepted, 2026-11-02. Part of #267 and #265.

IP installations retain one public HTTPS identity, including server-side Talk requests and
callbacks. The owner chose suite-scoped routing over modifying host firewall policy. The AIO
controller reconciles only that IP's TCP port 443 to Apache's current suite-network address,
using short-lived helpers with `NET_ADMIN` in each affected client's network namespace.
Helpers reuse the controller's immutable installed image, mount no host files or Docker
socket, and give applications no permanent additional capability. Restarts, recreation and
proxy address changes trigger reconciliation; failed applications are retried.

TLS verification and the public URL remain unchanged. Nextcloud Talk 24.0.6 uses its signaling
URL for both browser and server requests, and its certificate probe uses PHP streams outside
the HTTP client; a separate internal URL or HTTP-proxy-only workaround does not cover those
paths. Native readiness and two-client browser media acceptance remain required: a successful
route or welcome response alone does not establish a working Talk call.
