<!-- aps-fork-declaration-start -->
> [!IMPORTANT]
> **This is APS Conecta Gestión AIO — Instalador, a fork of
> [Nextcloud All-in-One](https://github.com/nextcloud/all-in-one)** maintained by
> [APS Conecta](https://github.com/APS-Conecta) for Chilean primary-healthcare clinics
> (CESFAM and the APS network). It is **not** produced by, affiliated with, sponsored, or
> endorsed by Nextcloud GmbH. "Nextcloud" and the Nextcloud logo are trademarks of
> Nextcloud GmbH.

**What this fork changes.** The fork's changes are committed bytes on `main` — one tree,
first-class files, what the images are built from. They were born as numbered patches the CI
replayed over upstream's tree; the hard fork (Stage 3) merged the replayed tree into `main`
and retired the queue. The IDs are attribution — which change owes which guarantee, the same
ID the gates' rows name:

| Patch | What it does |
|---|---|
| 010 | the container images re-pointed at this fork's registry (`ghcr.io/aps-conecta/*`) |
| 015 | the Euro-Office container built from the pinned DocumentServer 9.3.7-1 |
| 020 | the app store disabled — apps ship baked, never fetched |
| 030 | the suite theme and official Office, Talk and Custom Menu packages |
| 040 | updates follow the suite's deliberate versioned path; scheduled backups restart the current images |
| 050 | Euro-Office is the suite's only office backend, from the wizard through runtime and release images |
| 051 | the establishment supplies its own domain or IP address |
| 060 | the operator-visible strings translated to Spanish (es-CL, formal usted) |
| 070 | the wizard re-skinned to the APS Conecta identity |
| 080 | the three php/src registry references re-pointed at this fork |
| 090 | the wizard's Playwright suite translated to assert the es-CL bytes |
| 100 | the native `office` hub enabled for staff navigation; its document links use Euro-Office (#271) |
| 110 | the wizard's content security policy lets its own brand fonts load |
| 120 | the banner lockup drawn as outlines (`scripts/lockup.py`), so it needs no font |
| 130 | the product named «APS Conecta Gestión AIO» on every wizard surface |
| 140 | the wizard's help links pointed at the suite's own docs (instalador's aps/INSTALLER.md and aps/GUIA-CLINICA.md), the rest removed |
| 150 | the suite's values pre-filled — America/Santiago, `/srv/aps-conecta/respaldos`, a gestion domain pattern |
| 160 | the page offers only what the suite ships — the baked Hub, the suite version, the office card, no ExApp proxies, no «mastercontainer» jargon |
| 170 | the post-start page: the update path, «Suite en marcha», no host-wide Docker cleanup, the suite's names |
| 180 | the wizard laid out for a 360 px phone |
| 190 | no community containers — the channel removed whole: no directory, no image creation, no PHP readers (#48) |
| 200 | the office is Euro-Office only — other choices refused (PHP, declared) |
| 210 | the included service set is fixed; recording stays off (#183) |
| 220 | a fresh install calls nothing it does not need — the announcements feed |
| 230 | the fresh install skips circles' legacy-table probe (no «oc_circle_circles» error) |
| 233 | an IP accepted as the domain while domain validation is skipped — the install by IP over HTTPS, reused by testbed and lifecycle acceptance (PHP, declared) |
| 235 | the installer's own certificate served when one is mounted (`APS_TLS_DIR`, an install by IP); otherwise ACME, as upstream (PHP, declared) |
| 237 | the test harness's reset removes the Euro-Office container too |
| 238 | the push server reaches Nextcloud over the internal plain-http listener, not the public URL |
| 239 | dropped by #48: the `/tiles/` basemap route, its `APS_TILES_DIR` setting and read-only bind removed — `/tiles/` answers Nextcloud's own 404 |
| 240 | the suite's containers are named `aps-conecta-*` (generated; the wizard stays `nextcloud-aio-mastercontainer`; fresh installs only) |
| 250 | modern TLS only on every ingress — the ACME and internal listeners pin TLS 1.2/1.3, and apache's runtime ACME stanza carries the same pin on 443; nothing older negotiates |
| 260 | the database image built from this tree, never retagged — its image test runs before the push, and the pushed layers are the tested ones |
| 270 | one brand token file — `themes/apsconecta/core/css/tokens.css` — the palette and fonts read by the server theme, the wizard, the Provisionador and the brand gate; the wizard's font subsets re-cut to cover every string, and every job that runs the gate installs its font dependencies; Releases titled «APS Conecta Gestión»; no logo master in git |
| 280 | the entrypoint enables none of the apps `provisioning/app-policy.sh` restricts or disables — phase 16 alone sets their state |

**PHP logic changes only where declared.** Every other modification is a string, an asset, a
template, or Dockerfile plumbing — committed bytes the gates verify. The
declared PHP changes: patch 080's three registry references (strings), patch 200's office guard
(any office other than Euro-Office is refused), patch 210's fixed service policy (ADR-0021), patch 233's IP guard (an IP is accepted as the domain while domain validation
is skipped), patch 235's certificate directory (a setting and its read-only bind into the web front),
patch 240's container names (strings, the log route's name guard, and #186's creation-time
HaRP compatibility alias), and #48's closures — the
community channel's readers (the directory constant, the config property, the listing method, the
form handler, the Caddy trusted-proxy variable) and patch 239's basemap directory (the setting and
its read-only bind, removed with the route). The office configuration and container lifecycle carry
only the suite's Euro-Office backend (#177). Runtime control is limited to the suite's own
versioned images, backup lifecycle and domain/IP setup (#179); maintenance never prunes the
whole Docker host.

Institutional proxy configuration persists in a private host profile. Docker reads its
environment file; the wizard forwards the normalized proxy to Nextcloud, whose existing
proxy configuration masks credentials in ordinary configuration listings. Docker-socket
requests stay direct; bypasses include the inspected suite network and service inventory (#192).
The native AppAPI daemon hostname also bypasses the proxy. HaRP trusts the public suite CA
alongside system roots before its upstream agent starts; revalidation checks both directions (#186).
Image discovery accepts Docker and OCI image manifests and their indexes from the suite registry (#243).
Talk wiring has one boot/provisioning owner: phase 12 calls it after the official store app installs,
and native imports carry changed settings through stdin. Revalidation checks the configured
endpoints, verified public HTTPS welcome and native signaling diagnostics (#187).

The wizard's complete start path catches failures and finishes its existing HTML stream
with an explicit result. The host requires that result before reporting success. Image pulls
report new layer states and byte maxima separately from heartbeats; the host bounds waits
by monotonic inactivity and finite container-state transitions. A rejected request can renew
its session once; an ambiguous start is never replayed automatically (#193).

**What the operator sees.** The wizard presents itself as «APS Conecta Gestión AIO — Instalador»;
an already-installed instance greets with «APS Conecta Gestión AIO ya está instalado»; once the
containers run, the page hands back to the web installer with «Suite en marcha». These are the shipped bytes
— the brand gate proves them equal to this declaration on every run.

Operator file errors name the absolute lookup path. Roster collisions include the complete
establishment-specific list under «usuarios reservados:». The testbed summary names password
files only when they exist; signature verification prefers `signify-openbsd`, and its missing-tool
instruction includes both the package and the compatibility link (#141).

`APS_HOME` selects the host, Provisionador and app-resolver state directory. Explicit
app paths and `AIO_STATE` retain precedence. Developer certificate renewal retains file
ownership and grants Apache access through a named ACL; the no-root workflow lives in
`aps/INSTALLER.md` §14 (#142).

Silent installation forwards `--sin-validar-dominio` through the existing wizard parser.
The first completed wizard drive supplies the initial configuration. While Apache runs, later
drives retain it and the seed converges the establishment. Preparatory and stopped-suite drives
can apply configuration before startup. INSTALLER §4 documents the testbed and backup consequences (#158).

**Why some messages remain in English.** Upstream PHP messages remain for configuration
validation, authentication and ordinary container operations. Their sources are:

| Source | Examples |
|---|---|
| `php/src/Data/ConfigurationManager.php` | "Please enter a domain and not an IP-address!", "The entered timezone does not seem to be a valid timezone!" |
| `php/src/Controller/LoginController.php` | "The login is blocked since Nextcloud is running.", "The password is incorrect." |
| `php/src/Controller/DockerController.php` | "Container not found.", "Stopping container" |
| `php/src/Docker/DockerActionManager.php` | Docker request failures and container-start progress |
| `php/public/index.php` | "Not Found", "Method not allowed" |

The translated Playwright suite (`php/tests`, patch 090) keeps English assertions on
selected messages as its canary that the translation sweep never bled into PHP.

**Nominative use.** The wizard names itself «APS Conecta Gestión AIO»; translated prose calls the
software inside it «la suite» — «Nextcloud» remains in
the PHP-borne messages listed above — and the
wizard's help links point at the suite's own docs — instalador's `aps/INSTALLER.md` and
`aps/GUIA-CLINICA.md`. The source and revision image labels identify APS-Conecta/gestion and the built commit.
Upstream attribution stays in the vendor and documentation labels: `org.opencontainers.image.vendor` says
"Nextcloud" — true and honest nominative use, the software inside the image IS Nextcloud,
with this declaration carrying the fork's attribution — and `org.opencontainers.image.url`
points at Nextcloud's own documentation, which is correct for the software but not for this
suite's install story: the suite's documentation is this repository plus instalador's
`aps/INSTALLER.md`, never the label's target. This repository is the source of the
modifications.

**Schedules.** This fork runs none: upstream changes arrive by a deliberate merge into
`main`, and the discipline is proven by every release's own gates run, before anything builds
or signs.

**License.** The upstream [LICENSE](LICENSE) (AGPL-3.0) is carried unchanged. The complete
corresponding source of every suite image is this repository at the matching suite tag: the
tag's tree — upstream's history and the fork's changes as committed bytes — is the whole of
it.

**Installing.** A clinic installs from the published suite tag, never from this branch — the
runbook (preflight, the provisionador, backups, the map, updates) lives in
[`aps/INSTALLER.md`](https://github.com/APS-Conecta/gestion/blob/main/aps/INSTALLER.md),
and its Spanish walkthrough for clinic IT in
[`aps/GUIA-CLINICA.md`](https://github.com/APS-Conecta/gestion/blob/main/aps/GUIA-CLINICA.md).

Bugs this fork's own tooling hit are ledgered in [BUGS.md](BUGS.md); upstream's own issues
belong to [nextcloud/all-in-one](https://github.com/nextcloud/all-in-one/issues).

**This file is the fork's declaration only.** The upstream documentation that shared this root —
the install guides, the manual-install and Helm-chart walkthroughs, the migration notes — left
with the unused upstream parts (#48): the suite's documentation is `aps/` above, upstream's own
docs live in [its repository](https://github.com/nextcloud/all-in-one#readme).
Host preflight rejects unsupported architectures, missing FUSE, orphaned suite state and Snap Docker before preparation. Disk checks use Docker's active data root; firewall guidance and DNS rules use the suite network's actual subnets (#188).

Host preparation installs required tools independently of the optional signature verifier.
Split DNS binds dynamically, and Docker retains usable existing and host resolvers behind
the LAN address. An unavailable verifier leaves signature verification explicitly pending (#194).

<!-- aps-fork-declaration-end -->
