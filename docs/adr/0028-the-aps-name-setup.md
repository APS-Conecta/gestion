<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0028 — The APS name setup

Accepted, 2026-11-05. Part of #278; implemented by #285.

## Context

An establishment with no domain of its own opens the suite at its APS name, `<slug>.gestion.apsconecta.cl`, one per
DEIS code, given by APS's name service (`aps/name-service/` in APS-Conecta/gestion-aio, which owns its API; this repo
is a client). Staff open it inside the clinic, so the name must point to the server's address there and carry a real
certificate, with no port open on the clinic's router. The mastercontainer sits on Docker's bridge network, the
Provisionador runs as `www-data` and exits for good after «Listo» (ADR 0027), and the install has no host service and
no timer.

## Decision

**«Dirección» claims the name once, by DEIS code.** `POST /api/address` claims the confirmed centre's name from the
name service, `https://gestion-nombres.apsconecta.workers.dev`. The answer is the name and its credential: a username
and a password, the name's acme-dns subdomain and the service's address. The credential changes only that name's
address records and, through acme-dns's update, its certificate's challenge record, and it frees the name. The
Provisionador keeps it in `aps-name.json`, beside its state in the mastercontainer's volume, where AIO keeps its own
`configuration.json`: mode 0600, readable only by `www-data`, the account the Provisionador runs as. The
mastercontainer's start opens the whole volume to the group again (upstream's `start.sh`), so each process that keeps
the file sets it back to 0600. Every later call reuses the credential, so a name is claimed once, and
from the claim on «Centro» keeps its centre. A name another installation holds answers 409 and says that APS Conecta
can release it, with «Reintentar»; an unreachable name service or internet answers 503 with «Reintentar».

**AIO serves the name through its settings file, as upstream's Caddy DNS-challenge recipe does.** The suite port runs
AIO's own configuration code (`USE_NAME` in `aps/provisionador/suite.py`):

- AIO's first-run setup, so its passphrase exists as the first visit to its page would make it;
- the name as AIO's domain, with vanilla's domain check skipped, as upstream documents for that recipe and as its own
  deSEC registration does;
- our Caddy (`aps/images/caddy`) as the one community container, upstream's `community-containers/caddy`;
- the settings that container's definition gives AIO: reverse-proxy mode, Apache on port 11000 with the binding
  `@INTERNAL`, so Apache's port is published nowhere, not even on the host's loopback, and Caddy reaches it on the
  suite's network; and Talk on 443;
- the name's acme-dns credential among AIO's secrets, which `caddy.json` passes to Caddy as `ACMEDNS_*`.

Caddy gets the certificate by the DNS challenge through the name service, so no inbound port is needed, and staff
reach the suite on 443 only. The mastercontainer's environment does not change.

**The name follows the server's address, from inside the suite.** The name points to the server's address on the
network its default route leaves by, the clinic's. Docker's bridge network hides that address from the
mastercontainer, and `APS_INTERFACE_ADDRESS` is fixed at its start, so the suite port reads it from a short-lived
container of the mastercontainer's own image on the host's network, through the Docker socket. «Dirección» publishes
it with the claim. Then `aps-address-updater` (`aps/provisionador/dinit.d/`), a dinit service in the mastercontainer
shaped like upstream's `desec-ip-updater`, publishes it every 10 minutes and keeps running after «Listo», so a DHCP
change is followed. It starts with AIO's interface, by one more line in
`Containers/mastercontainer/dinit.d/caddy-internal`. An unchanged address changes nothing at the name service, and an
outage waits for the next round.

**Blocked private answers are detected from the operator's browser.** Some resolvers drop the answers that point to
private addresses, as a protection against DNS rebinding. After the claim, the page asks for AIO's interface at the
name. When the browser's resolver answers the server's address, the request reaches AIO's interface, and its Caddy
issues a certificate for the name on demand, before the browser refuses it (ADR 0027): the request fails in the
browser, and the certificate stays in Caddy's storage. The suite port looks for it there, and `GET /api/state` says
whether a browser opened the interface at the name. When none did, the page shows the router change: a DNS-rebinding
exception for the name's domain. It then asks again every 15 seconds. For that request, `provisionador.Caddyfile`
makes a third allowance on the Provisionador's routes: `connect-src` also allows `https://*.gestion.apsconecta.cl:*`.

**The suite's calls to its own address stay on its network.** Nextcloud calls Talk's signaling at the name and
signaling calls Nextcloud back; Office calls back and push is checked there too (#267 and #272 chased this failure).
On AIO's network, `nextcloud-aio`, the name is a network alias of our Caddy, which `DockerActionManager.php` adds when
it creates that container. That is the Docker mechanism AIO already uses on that network, which gives its domain check
Apache's name. Docker's resolver answers an alias before any outside resolver, so these calls never meet the host's
firewall, a router's hairpin NAT or the clinic's resolver. #286's Seam 1 run proves it.

**CI names.** gestion claims names only on the name service's CI deployment,
`https://gestion-nombres-ci.apsconecta.workers.dev`, whose names live under `ci.gestion.apsconecta.cl`, with the DEIS
codes reserved for gestion's CI in `aps/provisionador/ci-codes.txt`. gestion-aio's CI may claim any code, so a run that
finds a code held takes the next one. A run frees every name it claims with the name's own credential, even when an
earlier step failed. gestion never deploys the name service and holds no Cloudflare token; a name a lost run left held
is freed by APS Conecta with gestion-aio's «APS name release» workflow.

## Consequences

- The Seam 2 tests drive «Dirección» against the fake suite port: the claim and the credential's reuse, a name already
  held, an outage and «Reintentar», blocked private answers, and the name following the server's new address.
- The CI proof, `.github/workflows/aps-name.yml` (`aps/provisionador/name-test.py`), runs on pull requests that touch
  the Provisionador's name setup or our Caddy image, and on dispatch. On a GitHub runner, which takes no inbound
  connections, our Caddy image built from the tree gets a Let's Encrypt staging certificate for a CI name, with the
  environment `caddy.json` gives it, and the run then frees the name.
- The Provisionador claims from the name service's production deployment, and Caddy uses Let's Encrypt's production
  directory unless `ACME_CA` names another. The release gate's test builds (#286, #303) need the CI deployment and the
  staging directory.
- The detection reads where Caddy keeps the interface's certificates, `/mnt/docker-aio-config/caddy-internal/`, as the
  image test reads AIO's authority there.
- The Bootstrap's reset frees the name with the stored credential (#286).
