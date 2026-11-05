<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0029 — The Coolify install

Accepted, 2026-11-05. Part of #278; implemented by #293.

## Context

A Coolify admin runs the suite beside other apps, as a resource of an internet-reachable Coolify 4 server, with the
same suite release and the same Nightly updates as the Bootstrap. Coolify's proxy, a Traefik in the container
`coolify-proxy`, holds the host's ports 80, 443 and 8080, reads routes from Coolify's dynamic folder
`/data/coolify/proxy/dynamic` and gets certificates by Let's Encrypt's HTTP challenge. Coolify names the containers and
volumes of a compose resource itself, except in Raw mode, and AIO requires its own names. A cloud server's public
address may be none of its interfaces' own. GitHub's runners take no inbound connections.

## Decision

**The resource is a Git-based Docker Compose resource of this repository, in Raw mode, with `aps/coolify.yaml` as its
compose file.** Raw mode deploys the file as written, with only Coolify's labels added, so the container stays
`nextcloud-aio-mastercontainer` and its volume `nextcloud_aio_mastercontainer`. The file has AIO's own shape
(`compose.yaml`), plus:

- our mastercontainer on the channel tag, `ghcr.io/aps-conecta/all-in-one:latest`;
- reverse-proxy mode: Apache on 11000 (`APACHE_PORT`), bound to the host's loopback (`APACHE_IP_BINDING=127.0.0.1`)
  and joined to Coolify's network (`APACHE_ADDITIONAL_NETWORK=coolify`), where Coolify's proxy reaches it as
  `http://nextcloud-aio-apache:11000`, as it reaches AIO's domaincheck container, which AIO gives Apache's name there;
- AIO's interface on the host's port 8443, since Coolify's proxy holds 8080, with `APS_INTERFACE_ADDRESS` made of the
  resource's one variable, `APS_PUBLIC_ADDRESS`, the server's public IPv4 address, and that port (ADR 0027); a deploy
  without the variable stops with the reason;
- Coolify's dynamic proxy folder, mounted at its own path, which also tells the Provisionador that it runs as a
  Coolify resource;
- vanilla's `NEXTCLOUD_TRUSTED_CACERTS_DIR`, empty unless the resource gives it a folder.

The Provisionador's link, QR code and fingerprint go to the mastercontainer's log, which Coolify shows as the
resource's logs. Its live logs show them whole; its API and its copied or downloaded logs hide the value of every
variable of the resource, the public address in the link among them, unless the resource's «Environment values in
logs» is «Hide locked values only». The resource holds no secret, so the Coolify test sets it so.

**«Dirección» goes on once Coolify's proxy runs with AIO's Traefik settings.** The Provisionador reads the arguments
`coolify-proxy` runs with and answers 409 with those of AIO's Traefik settings (upstream's `reverse-proxy.md`,
«Traefik 3») it lacks: the https entry point's read timeout, 3610 s, ten seconds above Nextcloud's own, and its
allowances for encoded slashes, question marks and percent signs, which Traefik refuses by default. The page shows
them as lines for the `command` list of Coolify's proxy configuration. They hold for the whole proxy, so the admin
pastes them once, saves, restarts the proxy and presses «Reintentar»; Traefik reads its flags whatever their case, and
so does the check. A proxy that cannot be read, stopped or not Traefik, answers 503 with «Reintentar». Then:

- the APS name is claimed as elsewhere (ADR 0028) and points at the server's public address, the host of
  `APS_INTERFACE_ADDRESS`, which the address updater keeps publishing;
- AIO gets the vanilla settings of an own domain, with the name as its domain and vanilla's domain check skipped, as
  for the APS name: no community container, since Coolify's proxy stands where our Caddy stands; Talk on 3478 at the
  domain; none of the name's acme-dns secrets. The mastercontainer's environment keeps Apache behind the proxy;
- once every nameserver of the name's zone publishes that address, which «Dirección» waits for (two minutes, then
  503 with «Reintentar»), the Provisionador writes the route from the name to AIO's Apache into Coolify's dynamic
  folder, `nextcloud-aio.yaml`: Traefik's HTTP challenge and the suite's own calls ask resolvers for the name, and a
  resolver asked before then keeps finding nothing for the zone's SOA minimum, 30 minutes (ADR 0028). The route is
  AIO's «Traefik 3» sample: on the https entry point, with Coolify's `letsencrypt` resolver and AIO's headers, and on
  the http entry point, a redirect to https. Traefik reads YAML, and the file is JSON, which is YAML.
  Coolify keeps the folder to its own account, so the route goes in as root through the Docker socket AIO already
  holds, by `docker exec` into the mastercontainer, with a rename. Traefik then gets the name's certificate by its
  usual HTTP challenge;
- an own domain (ADR 0028) gets its route first, since vanilla's domain check reaches the domain through Coolify's
  proxy: until the proxy holds the domain's certificate, the check refuses, and «Reintentar» checks again. A switch
  either way replaces the route.

**Talk publishes 3478 itself**, TCP and UDP, on the host, as for an own domain; «Dirección» and «Revisar» say to open
it.

**The suite's calls to its own address go to the server's public address**, through Coolify's proxy, as vanilla's do
behind a reverse proxy: the server is internet-reachable, so they need no alias on AIO's network.

**AIO owns the version.** The compose file names no version, only the channel tag, which only a release moves, and
forward (`aps/RELEASING.md`). Coolify pulls every image-only service at each deploy, so a redeploy runs the channel's
newest final release, the one AIO's own update follows; and it recreates the mastercontainer alone, so the suite's
containers keep the images AIO started them on until AIO's update moves them. A redeploy never runs a candidate or an
older version, and never pins one.

**Stopping, removing and cleaning up safely**, which the manual's Coolify section (#302) gives the admin:

- to stop the suite, stop its containers in AIO's page first, then stop the resource in Coolify, which removes only
  the mastercontainer; to start it again, deploy the resource, then start the containers in AIO's page;
- to remove the suite, run the Bootstrap's reset on the server first (`… | sudo bash -s restablecer`): it frees the APS
  name with its credential and removes the suite's containers, the images they ran, its volumes, its network, its
  backups and its route from Coolify's dynamic folder, and leaves Docker and Coolify; then delete the resource in
  Coolify. In the other order, deleting the resource may delete its volumes, the mastercontainer's among them, and the
  name's credential with it, so that the name stays held;
- keep «Delete Unused Volumes» and «Delete Unused Networks» off in the server's Docker cleanup in Coolify: a stopped
  suite's volumes and network are unused, and so is the mastercontainer's volume once Coolify stops the resource; and
  keep the cleanup's schedule, midnight by default, away from AIO's nightly backup at 06:00 UTC, during which, and
  during the Nightly update after it, AIO pulls images it has not started yet, which the cleanup would remove.

**The Coolify test (Seam 1)** is the acceptance harness's second way in (`aps/acceptance/run.sh <tag> coolify`, a job
of `acceptance.yml` beside the Bootstrap's). On its own fresh Debian 12 VM, `aps/acceptance/coolify.sh` installs Coolify
4.6.0 with Coolify's install script, pastes the Provisionador's settings into the proxy configuration as an admin
does, adds the candidate's commit as the resource through Coolify's API, deploys it and reads the link from the
resource's logs through the API. Every check module then runs as on the Bootstrap's way: the way's rerun is a
redeploy, `80-again` proves after «Listo» that a redeploy keeps the running version, and the removal is the one above.
Two things differ from an admin's server, each for CI's sake:

- the HTTP challenge cannot reach the test's proxy. On a test build, the test's proxy configuration gives Coolify's
  `letsencrypt` resolver Let's Encrypt's staging directory and the DNS challenge through acme-dns, whose account lego
  reads, when it solves the challenge, from a storage on the machine that answers with the credential «Dirección» keeps
  (`aps/acceptance/acme-dns-storage.py`): the name service updates the challenge record, as it does for our Caddy. The
  route the Provisionador writes stays the same, and the suite trusts the staging roots through
  `NEXTCLOUD_TRUSTED_CACERTS_DIR`, as a test build's Bootstrap gives them;
- a candidate is never on the channel tag, so the test loads it there on the machine, by digest, as the Bootstrap
  does, and sets the resource's custom build command, which makes Coolify skip its pull of the channel tag. On an
  admin's server, that pull fetches the release.

## Consequences

- The Seam 2 tests (`aps/provisionador/test_coolify.py`) drive «Dirección» against a fake Coolify folder and proxy:
  the settings asked for first, whatever their case, an unreadable proxy, the route file once the nameservers publish
  the name, AIO's settings with Talk's notice, the public address the name and the address updater publish, and an own
  domain with the switch.
- Traefik's HTTP challenge, the own domain's check through Coolify's proxy and a redeploy's pull of a released channel
  tag are not observable in CI; they are Traefik's, vanilla's and Coolify's own.
- The host's port 8443 must be free on the server; an app that holds it stops the deploy, which says so.
- Coolify 5 is announced. The install and its test target Coolify 4, the test 4.6.0, and may need work then.
