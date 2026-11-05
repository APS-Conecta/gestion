<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0027 — The Provisionador runs inside our AIO image

Accepted, 2026-11-04. Part of #278; implemented by #282.

## Context

The operator runs the whole install from one page, the Provisionador, which starts at «Centro». The suite is
vanilla AIO plus our layer, and AIO already owns a page with its own certificate: its interface on port 8080, served
by Caddy (`Containers/mastercontainer/internal.Caddyfile`) with certificates its internal issuer makes on demand.
The mastercontainer sits on Docker's bridge network, so it cannot read the address the operator's browser uses
from its own interfaces, and the install has no host service and no timer.

## Decision

**The Provisionador ships in our mastercontainer image and answers on AIO's interface until «Listo».** It is
`aps/provisionador/`, Python's standard library only, with the DEIS register in `aps/deis/`. dinit runs it as
`www-data` on loopback (`aps/provisionador/dinit.d/provisionador`), started with AIO's interface by one line in
`Containers/mastercontainer/dinit.d/caddy-internal`. One import in `internal.Caddyfile` adds
`aps/provisionador/provisionador.Caddyfile` to the 8080 site; it is a glob, so upstream's image, which upstream's
browser tests run with that file, starts without it. Until «Listo», Caddy hands the Provisionador every request but
those for the brand files AIO's page serves under `/aps/` (the token file, the favicon, the fonts and Leaflet),
which the Provisionador's page loads too. The operator's browser sees AIO's own certificate, so the install has one
certificate warning.

**«Listo» hands 8080 to AIO's page.** «Listo» is the file `listo` beside the Provisionador's state in the
mastercontainer's volume (`/mnt/docker-aio-config/provisionador/`), written by the Provisionador once «Instalar» started
the suite and AIO reads every one of its containers running. Caddy's `file`
matcher reads it on every request: from then on 8080 serves AIO's page, and the Provisionador ends the link and
every session. At a later start the Provisionador prints that the install ended and exits; dinit restarts it only
after a failure.

**The link and the session.** Each start mints a link, `https://<address>/#<secret>`, with 256 random bits, and
prints it, its QR code and the certificate's fingerprint to the mastercontainer's log, which the Bootstrap and
Coolify show. The secret rides in the URL fragment, which no request carries. Any browser that opens a link
exchanges the secret for a session of its own (`POST /api/session`), kept in a `__Host-` cookie that is Secure,
HttpOnly and SameSite=Strict. Every link printed stays valid until «Listo»: a restart prints a fresh one, and the
ones before still open a session. The state is one JSON file in the same folder and keeps the links' secrets and
the sessions only as SHA-256 hashes, so a reload, a restart or a reboot resumes it, and a session survives a
restart. qrencode reads the link on stdin, because the host's `ps` shows the arguments of every process in the
container; the request log is off. The API accepts only JSON bodies, so another origin would need a preflight that
is never granted.

**The address is an environment value: `APS_INTERFACE_ADDRESS`.** It is the address the operator's browser opens
AIO's interface at: a host, or `host:port` when the host's port is not 8080, with an IPv6 address in brackets. The
Bootstrap passes the server's own address on the start command, which otherwise keeps vanilla's shape (the fixed
name and volume, the Docker socket and the interface port). The Coolify install passes the address and port the
internet reaches, since Coolify's proxy holds 8080. Without a valid value the log says how to give it and prints no
link.

**The fingerprint is the certificate the browser receives at that address.** Caddy issues one per server name the
browser sends; for an IP address, which browsers never send as a server name, it issues one for the container
address the connection arrives at. So the suite port's `certificate(host)` opens a TLS connection to the
mastercontainer's address on its default route, where the host's published port leads, with the server name a
browser at `host` sends, or none for an IP address, and the Provisionador prints that certificate's SHA-256
fingerprint. The image test compares it with the certificate a TLS client receives at the link's address.

**The Provisionador's routes keep AIO's headers with two allowances for «Centro»'s map.** 8080 sends AIO's
`Containers/mastercontainer/headers.Caddyfile`, with Trusted Types `'none'`, images from itself only and COEP
`require-corp`, and «Centro»'s map breaks under it: Leaflet 1.9.4 probes inline SVG through `innerHTML` when it
loads and writes its zoom buttons' labels the same way, the tiles are OpenStreetMap's, and Leaflet cancels a tile's
download by setting a `data:` blank image. So `provisionador.Caddyfile` edits AIO's policy on the Provisionador's
routes only: `img-src` also allows `data:` and `https://tile.openstreetmap.org`, and `trusted-types 'none'`
becomes `trusted-types default`, which keeps `require-trusted-types-for 'script'`. The page defines that default
policy, and it lets through only Leaflet's probe and the two labels. Leaflet's attribution control would write HTML
too, so the page shows OpenStreetMap's attribution under the map, and the marker is an element. The tiles load in
CORS mode, which OpenStreetMap answers, so COEP stays. AIO's `Referrer-Policy: no-referrer` stays too, though
OpenStreetMap's tile policy requires a Referer: without one, `tile.openstreetmap.org` answers every tile with its
"403 Access blocked" image at HTTP 200, so Leaflet reports no error. So the tile layer sets
`referrerPolicy: "strict-origin"` on its tile images, which overrides the page's policy for them alone: the tile
requests carry the page's origin, never its path. AIO's page and the brand files keep AIO's policy as it is.

**Timezone.** The centre's timezone follows its location: the comuna Isla de Pascua is `Pacific/Easter`, the Región
de Magallanes y de la Antártica Chilena is `America/Punta_Arenas`, and every other place is `America/Santiago`.

## Consequences

- The Seam 2 tests (`aps/provisionador/test_provisionador.py`) drive the HTTP API in-process against the fake suite
  port in the static gate. The image test (`aps/provisionador/image-test.py`, the `Mastercontainer image`
  workflow) builds the image from a pull request's tree, runs it as vanilla's command does and checks the link, the
  fingerprint, a restart and the handoff from outside.
- Caddy's internal issuer, which `internal.Caddyfile` gives no lifetime, issues 12-hour certificates and renews each
  after about 8 hours, while the links stay valid until «Listo». A browser that opens the interface after a renewal
  warns again, so the Provisionador reads the certificate every 5 minutes and, when it changed, prints the new
  fingerprint to the log, without the link; a check that finds AIO's interface down waits for the next one.
- Until #301 removes the old host layer, its own Provisionador and DEIS tool stay in the tree beside this one; the
  new code never imports or runs them, and `scripts/deis.py` reads the register from `aps/deis/`.
- The Bootstrap (#283) and the Coolify install (#293) must pass `APS_INTERFACE_ADDRESS`.
