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
| 015 | the Euro-Office container pinned to the certified pairing — DocumentServer 9.3.4 with its connector 11.0.5 |
| 020 | the app store disabled — apps ship baked, never fetched |
| 030 | the suite's apps and theme baked into the Nextcloud image |
| 040 | self-update suppressed — the suite updates as one lockstep set |
| 050 | the Collabora and OnlyOffice cards removed (Euro-Office is the suite's office) |
| 051 | the deSEC DNS flow removed |
| 060 | the operator-visible strings translated to Spanish (es-CL, formal usted) |
| 070 | the wizard re-skinned to the APS Conecta identity |
| 080 | the three php/src registry references re-pointed at this fork |
| 090 | the wizard's Playwright suite translated to assert the es-CL bytes |
| 100 | the first-party `office` overview app disabled while Euro-Office is the suite's office |
| 110 | the wizard's content security policy lets its own brand fonts load |
| 120 | the banner lockup drawn as outlines (`scripts/lockup.py`), so it needs no font |
| 130 | the product named «APS Conecta Gestión AIO» on every wizard surface |
| 140 | the wizard's help links pointed at the suite's own docs (instalador's aps/INSTALLER.md and aps/GUIA-CLINICA.md), the rest removed |
| 150 | the suite's values pre-filled — America/Santiago, `/srv/aps-conecta/respaldos`, a gestion domain pattern |
| 160 | the page offers only what the suite ships — the baked Hub, the suite version, the office card, no ExApp proxies, no «mastercontainer» jargon |
| 170 | the post-start page: the update path, «Suite en marcha», no Docker prune button (the route stays), the suite's names |
| 180 | the wizard laid out for a 360 px phone |
| 190 | no community containers — the channel removed whole: no directory, no image creation, no PHP readers (#48) |
| 200 | the office is Euro-Office only — other choices refused (PHP, declared) |
| 210 | Talk, Whiteboard and Imaginary start off (PHP defaults, declared) |
| 220 | a fresh install calls nothing it does not need — whiteboard's npm update check, the announcements feed |
| 230 | the fresh install skips circles' legacy-table probe (no «oc_circle_circles» error) |
| 233 | an IP accepted as the domain while domain validation is skipped — the install by IP over HTTPS (PHP, declared) |
| 235 | the installer's own certificate served when one is mounted (`APS_TLS_DIR`, an install by IP); otherwise ACME, as upstream (PHP, declared) |
| 237 | the test harness's reset removes the Euro-Office container too |
| 238 | the push server reaches Nextcloud over the internal plain-http listener, not the public URL |
| 239 | dropped by #48: the `/tiles/` basemap route, its `APS_TILES_DIR` setting and read-only bind removed — `/tiles/` answers Nextcloud's own 404 |
| 240 | the suite's containers are named `aps-conecta-*` (generated; the wizard stays `nextcloud-aio-mastercontainer`; fresh installs only) |
| 250 | modern TLS only on every ingress — the ACME and internal listeners pin TLS 1.2/1.3, and apache's runtime ACME stanza carries the same pin on 443; nothing older negotiates |
| 260 | the database image built with pgvector, and Buscador Documental's roles and extensions applied at every start and before a dump restore (`Containers/postgresql/aps-roles.sh`) |

**PHP logic changes only where declared.** Every other modification is a string, an asset, a
template, or Dockerfile plumbing — committed bytes the gates verify. The
declared PHP changes: patch 080's three registry references (strings), patch 200's office guard
(any office other than Euro-Office is refused), patch 210's defaults (Talk, Whiteboard and
Imaginary start off), patch 233's IP guard (an IP is accepted as the domain while domain validation
is skipped), patch 235's certificate directory (a setting and its read-only bind into the web front),
patch 240's container names (strings, and the log route's name guard), and #48's closures — the
community channel's readers (the directory constant, the config property, the listing method, the
form handler, the Caddy trusted-proxy variable) and patch 239's basemap directory (the setting and
its read-only bind, removed with the route).

**What the operator sees.** The wizard presents itself as «APS Conecta Gestión AIO — Instalador»;
an already-installed instance greets with «APS Conecta Gestión AIO ya está instalado»; once the
containers run, the page hands back to the web installer with «Suite en marcha». These are the shipped bytes
— the brand gate proves them equal to this declaration on every run.

**Why some messages remain in English.** The wizard renders 68 operator-visible messages from
PHP code the fork does not translate (its declared PHP changes are behaviour, not strings). They stay English by scope decision, and
this is the complete list, by source:

| Source | Count | Where | Examples |
|---|---|---|---|
| `php/src/Data/ConfigurationManager.php` | 35 | :599–:1148 | "Please enter a domain and not an IP-address!", "The entered timezone does not seem to be a valid timezone!" |
| `php/src/Desec/DesecManager.php` | 17 | — | deSEC registration errors (the flow is removed from the UI; the messages are unreachable) |
| `php/src/Controller/LoginController.php` | 2 | :22, :34 | "The login is blocked since Nextcloud is running.", "The password is incorrect." |
| `php/src/Controller/DockerController.php` | 3 | :81, :308, :353 | "Container not found.", "Stopping container", "Automatically reloading the page after 10s." |
| `php/src/Docker/DockerActionManager.php` | 9 | :198–:1205 | the four "Could not …" errors, the two "You probably did not follow the documentation correctly" messages, the streaming lines ("Starting container", "Docker system prune completed.", "Automatically reloading the page after 10s.") |
| `php/public/index.php` | 2 | :264, :274 | "Not Found", "Method not allowed" |

The translated Playwright suite (`php/tests`, patch 090) keeps English assertions on three of
these as its own canary that the sweep never bled into PHP.

**Nominative use.** The wizard names itself «APS Conecta Gestión AIO»; translated prose calls the
software inside it «la suite» — «Nextcloud» remains only in the Hub-upgrade block the page never
renders, the docker socket proxy and HaRP options (shown only where one is already on) and
the PHP-borne messages listed above — and the
wizard's help links point at the suite's own docs — instalador's `aps/INSTALLER.md` and
`aps/GUIA-CLINICA.md`. The image labels are byte-identical upstream,
deliberately, and both readings are recorded: `org.opencontainers.image.vendor` says
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
[`aps/INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md),
and its Spanish walkthrough for clinic IT in
[`aps/GUIA-CLINICA.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/GUIA-CLINICA.md).

Bugs this fork's own tooling hit are ledgered in [BUGS.md](BUGS.md); upstream's own issues
belong to [nextcloud/all-in-one](https://github.com/nextcloud/all-in-one/issues).

**This file is the fork's declaration only.** The upstream documentation that shared this root —
the install guides, the manual-install and Helm-chart walkthroughs, the migration notes — left
with the unused upstream parts (#48): the suite's documentation is `aps/` above, upstream's own
docs live in [its repository](https://github.com/nextcloud/all-in-one#readme).
<!-- aps-fork-declaration-end -->
