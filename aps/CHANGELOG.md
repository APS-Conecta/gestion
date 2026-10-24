# Changelog — APS Conecta instalador

Every version a clinic can install. `main` is the development trunk; a release is a tag, and a clinic
installs the tag's signed package (the `install.sh` bootstrap; aps/RELEASING.md owns the ritual).

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

Each version links to its GitHub release, which holds the full notes. The pinned app versions and
image digests live there and are deliberately not copied here — one fact, one owner.

## [Unreleased]

### Added

- **Euro-Office installs from its own release (#36, ADR-0017).** The connector is no longer
  the store's `eurooffice` plus two bake-time white-label patches: it is the fork
  `APS-Conecta/eurooffice` (upstream main plus our two renames — the admin section and the app
  name — as two commits), it publishes signed releases through the org's shared workflow (first
  release `v11.0.7`, monotonic: one patch above upstream's newest tag, so no app-store version is
  ever "newer"), and its manifest row is `source: fork` with `release: true`. At install time the
  resolver downloads the fork's newest compatible release, verifies it against `apps.pub`, and
  the lock records it; the office smoke's round-trip re-certifies the DS 9.3.x pairing per
  install. With the store closed, no update path replaces the fork with the store's namesake:
  clean-boot runs `occ app:update eurooffice` directly and asserts the version, the enabled state
  and the names unchanged (by domain and by IP), and the office smoke after the store-off reboot
  answers the connector still enabled and wired — the entrypoint's own update leg included. The bake
  keeps shipping the vendored 11.0.5 as the interim fallback until #42 removes it.

- **Territorio installs from its own release (#33, ADR-0017).** At install time the Provisionador
  resolves the app's newest GitHub Release compatible with the running Nextcloud (the latest-release
  redirect — no API call, no token), downloads it, verifies it against `apps.pub` (signify: the
  SHA256SUMS signature, the tarball and `info.xml` hashes, the top directory, no
  `appinfo/signature.json`), installs it, and records its tag in the per-server lock file
  (`/opt/aps-conecta/apps.lock.json`, inside the backup scope). A repeated provisioning installs
  from the lock and downloads nothing; a failed download or verification stops the install naming
  the app and the retry command; review mode downloads nothing. The other apps still come from the
  bake until their own releases land (#36–#37) and the bake is removed (#42).
- **Epidemiología installs from its own release too (#34, ADR-0017).** Its manifest row flips to
  `release: true`, so the resolver fetches, verifies and locks it exactly as it does territorio.
  The clean-boot seam (by domain and by IP) asserts its lock row names a release newer than the
  bake's 0.9.0, that the instance runs the locked version, and that no `signature.json` rides it.
  Needs epidemiologia's `v0.12.0` release (APS-Conecta/epidemiologia#169) published first.
- **side_menu is a fork app of our own, installed from its release (#38, ADR-0017).** Upstream
  (gitnet.fr, the app's only source) has been unreachable since 2026-08-13 (#169), so the
  decision there — "mirror the tarball somewhere we control" — became APS-Conecta/side_menu:
  a repo seeded from our AGPL 6.0.1 tarball, byte for byte, with no build manifest and its
  bundle shipping as committed bytes (the shared release workflow's one `shipped-bundle`
  caller). Its manifest row turns `fork` with `release: true`, so the resolver fetches,
  verifies and locks it exactly as it does territorio — same 6.0.1 the bake pinned, so the
  clean-boot seam proves the release path by what only the fetch leg writes (the lock row, the
  stored tarball, no `signature.json`) and that the suite's violet still paints the menu
  (`background-color` / `background-color-to`, and the stylesheet the app derives from them).

### Removed

- Upstream's default startup-app set (deck, twofactor_totp, tasks, calendar, contacts, notes — comma-spelled
  here so the gate's literal scan stays honest). The fork's fallback for `NEXTCLOUD_STARTUP_APPS` is now the
  empty string, so the suite manifest (`apps.json`) is the only app list in the suite repo. A clean boot
  installs the same apps as before: the host CLI already passed the empty value regardless (#67).

## [0.5.0] — 2026-10-23

### Fixed

- Ported gestion `3b62c24` to the package, which had landed only in gestion's frozen copy of the
  executor: phase 05 now sets `session_lifetime` to 900 (a 15-minute inactivity logoff) and
  `session_keepalive` to false (so an idle workstation is not kept alive), and enables the
  `admin_audit` app via the new idempotent `app_enable` helper. Encryption at rest
  (`encryption.enabled`) was deliberately not ported: it needs `occ encryption:enable` and a
  key-management decision, with backup, group-folder and Office consequences.
- Apache starts again behind a reverse proxy (`APACHE_PORT` other than 443). v0.4.0 pinned TLS 1.2/1.3 on
  every listener, and Caddy refuses a TLS policy on a plain-http one («server listening on [:11000] is
  HTTP»); the pin now applies on 443 only.

### Added

- `role-emergencia-breakglass` in the group registry (phase 20, `cat-clinicos`): a role/group only,
  with no permissions of its own and no override mechanism. The shared registry is now 28 groups and
  23 roles, so the roster planilla accepts it as a cargo.

### Removed
- **The PMTiles basemap machinery.** The install's step 4 «Construir el mapa» (`aps-conecta mapa`),
  `host/tiles.sh`, `scripts/refresh-basemap.sh`, the monthly `aps-conecta-tiles` timer and service,
  the `tiles` subcommand, `APS_SKIP_MAP`, the `TILES_HOME` knob, the `APS_TILES_DIR` environment line of
  the mastercontainer's run string (and the guard that refused a running suite without it), the map-folder
  literal gate, the tiles self-tests and Clean boot's `/tiles/` steps. Territorio and the installer's
  Centro pane draw OpenStreetMap's own tile service instead (ADR-0021 in territorio). The install is
  **eight** steps now (Centro is step 5); every «Paso N de 9» is «Paso N de 8».

### Added
- **`retire_tile_remnants`**, run by `aps-conecta temporizadores` (and so by a finished install) and by the
  weekly re-provision: on a host that ran an earlier bundle it disables the old map timer, stops a refresh
  that is already running, removes its two unit files (reloading systemd only then), removes the old `aps-conecta-tiles` container if present, and says once that the archive can
  be freed with `sudo rm -rf /srv/aps-conecta/tiles`. Idempotent, silent the second time, and it never
  deletes the archive. Upgrade notes: `aps/MIGRATION.md` §12.

### Changed
- **The installer's Centro map pane draws OpenStreetMap's tile service** (one raster layer, under its
  Tile Usage Policy: the bare tile URL, the wizard's origin as `Referer`, a linked «© OpenStreetMap
  contributors», zoom 4 to 18) instead of the local PMTiles archive. On the first tile failure the pane
  says so and the step stays completable. The wizard no longer serves `/mapa/chile.pmtiles` or
  `/api/mapa`, no longer vendors `protomaps-leaflet.js`, and no longer refuses a point outside the
  archive's coverage. The self-test's browser arms mock every tile request and abort any other
  `openstreetmap.org` request; a skipped browser arm is now a failure of the self-test
  (`APS_SELFTEST_SIN_NAVEGADOR=1` waives it, visibly).
- **Provisioning phase 16 no longer writes Territorio's `tile_url`.** Territorio's basemap is
  OpenStreetMap's own tile service, loaded by each browser (ADR-0021 in territorio), so nothing is
  provisioned for it; the comuna keys (`comuna_cut`, `comuna_name`), from which the app derives
  where the map opens, are written as before. `scripts/smoke.sh` check 16 and Clean boot assert
  the comuna instead of a URL.

## [0.4.0] — 2026-10-12
### Added
- The signed package release channel: the `install.sh` bootstrap, the `VERSION` discipline, `installer.pub`.
- `suite_tag()` reads the package's `VERSION` first; the git channel is rehearsal-only (`APS_REPO_URL`).

## [0.3.0] — 2026-09-22

### Added

- **The Provisionador** (`scripts/provisionador.py`) — the host-side wizard that walks an operator
  from a fresh AIO install to a provisioned clinic: the DEIS cascade, sectors/programs, the users
  CSV with sealed credentials, the executor (`.env` convergence → seed → roster → divergence gate),
  and the eight es-CL screens over the same JSON APIs. 100-check hermetic self-test.
- **The host bundle** (`host/aps-conecta`) — `preflight`, `run-command` (the one `docker run`
  string), `provision [--reponer]` (the weekly headless re-provision), `revalidate`, `respaldo`,
  `tiles`, `datos`; the weekly re-provision and monthly tiles-refresh systemd units.
- **The tiles stack** (`host/tiles.sh`) — the digest-pinned nginx + the sha256-gated pmtiles CLI
  + the `TILES_PUBLIC_URL` convergence + the 18-check self-test; the archive at
  `/srv/aps-conecta` (outside borg's scope by design).
- **The migration tool** (`scripts/migrate-to-aio.sh`) — dump + datadir + config.php +
  version.php into AIO's own volumes before first start, and the post-restore verify hook;
  20-check self-test. `docs/MIGRATION.md` gains the codetree-half amendment, §2½, the B-019
  remote-user leg, and §9's permanent-traps index.
- **The operator docs** — `docs/INSTALLER.md` (the English clinic runbook) and
  `docs/GUIA-CLINICA.md` (the es-CL walkthrough: the eight screens, the planilla, the
  credentials ritual, «tras actualizar», «¿y el mapa?»).
- **The final-validation harness** (`scripts/final-validation.sh`) — the whole-installer
  acceptance ritual, 17 numbered steps, 5-check self-test.
- **Four hermetic self-tests in `make test`** — provisionador (100), host bundle (39), tiles (18),
  migrate (20): no docker, no stack, every PR.

### Changed

- **`cleanboot.yml` is the S8 acceptance** — the first-boot notify-push sibling assert, the
  divergence-gate handoff on the clean install, the store-off reboot (settle-wait +
  converge-then-prove), the office AIO legs, and the deterministic register pick.
- **`office-smoke.sh` answers the AIO stack** — the public-path healthcheck through apache, the
  DS 9.3.x pin read from `--check`'s own line, the image namespaces; the white-label pair
  retired to build time. `test.sh`'s office gate flips to the AIO sibling (the visible skip
  under compose).
- **`14-office.sh` carries the AIO arm** — the entrypoint owns the office wire under AIO; the
  compose writes live inside their branch.
- **README/docs index/ARCHITECTURE** — the two-worlds posture: the dev stack stays this README,
  the clinic is APS Conecta AIO (`INSTALLER.md`).
## [0.2.0] — 2026-09-21

### Added

- **Territorio's comuna door is armed per install** — the register's `comuna_codigo` lands in
  territorio's app config (`comuna_cut`/`comuna_name`, written by phase 16 and watched by
  divergence), so `refuseAnotherComuna` compares against THIS install's comuna, and the import
  door opens for exactly one comuna and no other.
- **The uninstall** — `make uninstall`: preservation copy, a verified-restorable dump, typed
  confirmation, `down -v`, generated artifacts, the basemap timer, and a clean-slate report. The
  one command that finally deletes, on purpose.
- **The migration runbook** — `docs/MIGRATION.md`: the rehearsal-first choreography for moving
  the pilot (or any install) to the AIO stack, the data-dir markers, the autoupdate trap, the
  preservation-doc template.
- **Territorio ships** — v0.74.0, from lab app to own app: the tarball, the LICENSING row, the
  inventory move.
- **The comuna data packages** — the national masters pinned in `provisioning/data/packages.json`,
  the DEIS comuna reference derived beside them, and `scripts/comuna-package.sh`: one fetch, one
  seconds-long cut, the exact import commands printed.
- **The release manifest** — `scripts/release-manifest.sh` + the tag-triggered workflow: every
  release gets a machine-readable union of what it pins, as a GitHub Release asset.
- **notify_push, vendored for the AIO bake** — this stack installs it from no inventory; the bake
  needs the bytes with provenance.
- **The establishment-agnostic gates** — the shape-based ADR-0009 check, the sites/ register-only
  check, and the neutral cleanboot fixture (a deterministic register pick, not a fixed clinic).
- **The suite serves its own basemap** — a new `tiles` service (`nginx:alpine`, digest-pinned)
  publishing one Protomaps PMTiles archive on loopback, reached from outside over `tailscale serve`.

  **Because OpenStreetMap's public tile service answered `403`.** That is a *block*, not an outage:
  their wiki files `tile.openstreetmap.org` as a P2 best-effort service under a Tile Usage Policy,
  and their own answer to a blocked application is to run your own tile server or use a third
  party. Territorio's ADR-0019 has the full reasoning and the app-side half of the fix.

  **Not a tile server.** PMTiles is a single file the *browser* reads with HTTP **Range** requests,
  so this is a static file server that honours ranges and sets CORS — nothing more. The arrow in
  `docs/ARCHITECTURE.md` goes browser → tiles, not Nextcloud → tiles, which is why the address is
  `TILES_PUBLIC_URL` and not a compose service name: the browser is not in this network.

  **~1 GB in `./tiles/`, gitignored.** All of Chile at zoom 0–15, including Isla de Pascua and Juan
  Fernández — a bbox stopping at the mainland silently drops two comunas with health facilities,
  and including them costs 4.7 MB. It is generated data with a refresh schedule, not source. A
  client pulls about 0.5–1 MB per screenful, not the file.

  The mount is `./tiles`, relative like `./apps` and `./themes`. An early draft of this service
  mounted `/srv/tiles` and would have broken "the core compose carries nothing VPS-specific and no
  absolute host paths" without anything failing.

- **`scripts/refresh-basemap.sh` rebuilds the archive**, and verifies the artefact rather than an
  exit code.

  Two things make it a script rather than a cron one-liner. **The source URL cannot be pinned** —
  Protomaps publishes dated planet builds and removes old ones, and one nine days old already
  answered `404`, so the date is discovered newest-first. And **a zero exit proves nothing**: a
  truncated download, an error page saved under the right name, or an archive of the wrong region
  all leave something returning success. The new file has to carry the PMTiles magic, declare
  zoom 0–15, declare bounds that *contain* the comuna, answer for a real tile **in bytes**, and be
  over 500 MB, before it is allowed to replace a working archive — which it does by `mv` on the
  same filesystem, so a reader sees the whole old file or the whole new one.

  Each of those was tested by seeding the violation it exists for. One failed: the obvious
  `pmtiles tile … >/dev/null || fail` form **can never fail**, because that command exits 0 and
  prints nothing for a tile it does not hold — an archive of Amsterdam passed it for a tile over
  Santiago. Hence the byte count, and hence the bounds check beside it.

  **Its healthcheck is liveness and nothing more**, after the first version of it failed CI's clean
  boot two ways at once. It HEADed `/chile.pmtiles`, on the reasoning that nginx being up says
  nothing about whether the mount carried the file — true, and still the wrong check, because the
  archive is gitignored generated data: a fresh clone has none, so the container never went healthy
  and `make install` died for the **whole suite** over an optional asset. And it used `http://localhost`,
  which **could never pass at all**: nginx listens on `0.0.0.0:80`, the image maps `localhost` to
  both `127.0.0.1` and `::1`, and busybox wget tries `::1` first and is refused. That second fault
  was the one CI actually reported, and it had been failing here too — invisibly, because an
  unhealthy container still serves. Now `wget --spider http://127.0.0.1/healthz`, measured healthy
  both with the archive present and with `tiles/` empty.

  Scheduled by **`territorio-basemap.timer`** on the host (monthly, the 4th at 04:30,
  `Persistent=true`, `Nice=15`, `IOSchedulingClass=idle`) — units live outside this repo because
  they are host configuration, and are recorded in `/root/SERVICES.md`. Monthly rather than nightly
  because this is OpenStreetMap cartography, which does not move fast enough to be worth a gigabyte
  a night; the 4th to land clear of the 02:30 site backup and the 03:32 offsite run. Measured on
  2026-09-18: 21 s of CPU, 1.2 GB transferred, exit 0, and the running `tiles` service picked up the
  new archive without a restart because the replacement is an `mv` on the same filesystem.

- **Every custom app's mount shows a branded loading state instead of a blank frame.** One
  app-agnostic component (territorio arch-review L0-04, generalized on the developer's directive):
  a spinner + `<noscript>` fragment pasted inside each bare mount — `#territorio`,
  `#territorio-admin`, `#farmacia`, `#epidemiologia` — and the CSS served once to every page by
  the theme (`server.css`; canonical fragment in `MAPEO.md` §5).

  **Because the frame was blank until the webpack bundle mounted** — nothing for a slow load or a
  JS-disabled browser, on every custom app. A spinner, not a skeleton: a skeleton must imitate each
  app's layout and cannot be agnostic. Vue's container mount replaces the mount's children on
  boot, so the stub removes itself — no cleanup code anywhere.

### Changed

- **The basemap anchor is the establishment's own DEIS point** — read from territorio's import at
  refresh time, not hand-picked constants; the tile checks derive from the point they must agree with.
- **Connector 11.0.5 + documentserver 9.3.4, bumped together** — both white-label patches
  regenerated, the DS digest re-pinned, and office-smoke now ASSERTS the running documentserver's
  version: the pairing is a gate, not a coincidence.
- **07-certs serves national hosts only** — the regional statistics host is per-establishment
  instance configuration (ADR-0009), and no app consumes it.
- **The repo stops naming its pilot** — living docs AND dated history (the register CSV, the public
  MINSAL catalogue, is untouched).
- **Provisioning phase 16 writes Territorio's `tile_url`** from `TILES_PUBLIC_URL`, the same shape
  and for the same reason as phase 14's `DocumentServerUrl`: which address staff browsers use is a
  per-install answer, never a repository fact. The default is the loopback one, which works for a
  developer on the box and for nobody else — an honest failure, since Territorio then says
  «No se pudo cargar el fondo de mapa» instead of showing a map that is quietly wrong.

  It is a line of its own rather than an entry in `POLICY_CONFIG`, for a mechanical reason: that
  list is space-separated `app:key:value` triples and cannot carry a value with a variable expanded
  into it.

- **Talk (`spreed` 24.0.5) and Desktop Workspace (`desktop_workspace` 0.18.2) are part of the
  suite**, vendored as pinned tarballs like every other app, so a clean install still needs no
  network and no app store (#98). Two things about Talk are recorded in its `VENDOR` file rather
  than left to be found: it reaches an **external STUN server** (`stun.nextcloud.com:443`) by
  default to discover a caller's own address, and **group calls stay small — around four people —
  without a High Performance Backend**, which this stack does not run. Chat and one-to-one calls are
  unaffected by the second. Talk's tarball is 52 MB, more than every other vendored app put
  together, and git keeps a full copy per bump: it is now the first place to look if this repo has
  to go on a diet. `desktop_workspace` is third-party (`canisdata`), the same posture as
  `side_menu`.

- **The licence table is now gated against the apps themselves.** `scripts/test.sh` reads
  `appinfo/info.xml` out of each vendored tarball — tracked, so it needs no network and no running
  stack — and fails if `docs/LICENSING.md` disagrees or has no row for a vendored app. Nextcloud's
  legacy bare `agpl` normalises to `AGPL-3.0-or-later` rather than failing, since `calendar`,
  `side_menu` and `epidemiologia` still declare it that way. The SPDX column is located by reading
  the header, not by a fixed index: the Source column also contains backticks, and an inserted
  column would otherwise shift the check onto its neighbour. Validated by seeding four cases —
  the original defect, a deleted row, an inserted column, and a table with no SPDX column at all.

### Fixed

- **`docs/LICENSING.md` stated the wrong grant for the Euro-Office connector** (#171). The table
  said `AGPL-3.0-or-later`; `eurooffice`'s own `info.xml` declares **`AGPL-3.0-only`** — materially
  different grants. It survived two documentation audits (#87, #88) and a version bump (#167) that
  edited that exact row without looking one cell to the left. Five rows also still said
  *(occ-installed)*, false since #98 vendored them as tarballs; they now name the pinned version and
  the tarball.

- **`provisioning/apps/calendar/VENDOR` described its own size against an app that was deleted**
  (#172): *"the second largest thing in this repo after maps"*, pointing at maps' file. `maps` was
  dropped in #142. It is the largest thing in the repo now — 18.9 MB against the next at
  4.7 MB — and the comment says so without naming a sibling that can be dropped again.
  `CONTRIBUTING.md` gains **"What the docs gate does not govern"**, recording that `VENDOR` files,
  `Makefile` comments and code comments are outside `repo-docs`' corpus deliberately, so the
  retirement rule applies to them by review rather than by gate.

- **`provisioning/apps/side_menu/VENDOR` pointed at a source nobody can reach** (#169).
  `gitnet.fr` — deblan's self-hosted forge and the app's only source, with no mirror anywhere —
  resolves and then blackholes the SYN on both 80 and 443 (`http=000`, `time_connect=0.000000`).
  Measured 2026-08-13 and again 2026-09-14, unchanged. Nothing is broken: the 6.0.1 tarball is
  committed, sha-pinned and installs. The file records the outage, that 6.0.1 is pinned
  deliberately, and the three ways out — and a `frozen=` line beside the pin now tells
  `make apps-check` to **report this app without failing on it**, because a red line nobody can act
  on is one everyone learns to ignore, which is what the weekly workflow's own header warns against.
  The app is still listed on every run with the version it cannot take, so the freeze stays
  reviewable; a stale pin on any other app still fails the gate.


### Security

- **Provisioning refuses to run with the secrets this repository publishes.** `make setup` generates
  all four from `/dev/urandom`, so a placeholder only survives a hand-copy of `.env.example` — which
  is what README step 2 used to ask for, and what somebody does when `make setup` refuses because
  `.env` already exists. The result is a clinic whose admin password is readable by anyone who can
  read this repo. `install.sh` and `seed.sh` now stop, naming the keys. What counts as a placeholder
  is read out of `.env.example`, so rewording one does not quietly stop it being one, and a secret
  added there is covered on the day it is added.

### Security

- **The cert phase ran a string an attacker on the network chose.**
  `ensure_aia_intermediate` read a certificate's authorityInfoAccess pointer from a **remote** host
  over an `openssl s_client` handshake that verifies nothing, then interpolated it into a
  `docker compose exec … sh -c "…"`. A single quote closed the literal and the rest was a command —
  demonstrated in a container with `x'; touch /tmp/PWNED; echo '`.

  Neither apparent mitigation held. The `tr -d '[:space:]'` strip does not stop a payload that needs
  no whitespace, and "it is only root inside the container" names the wrong party: the operator
  running `make seed` already holds the docker socket, while **the network** — which otherwise has
  none — was being handed execution in the container that holds the database credentials.

  The pointer and the host now go through the environment, the pattern `ensure_sample_file` already
  used; anything that is not a plain `http(s)` URL of safe characters is refused rather than escaped;
  and the fetched certificate must now chain to a root the container **already trusts**, for a leaf
  that is **for this host** (`openssl verify -untrusted … -verify_hostname`), before it joins
  Nextcloud's trust bundle.

  That last check was got wrong once on the way. `-partial_chain -trusted` proves only that the
  fetched certificate signed the certificate the handshake presented — and an on-path attacker
  chooses both, so it accepted a forged pair in testing. A parse is not a verification, and neither
  is verifying against something the attacker supplied. The pointer and the leaf are also now read
  from a **single** handshake, so the certificate being verified is the one whose pointer was
  followed.

### Changed

- Documentation consistency pass across the organisation. Org-wide decisions now live in this
  repository and are referenced by absolute URL rather than by a path that depended on where someone
  cloned things (ADR-0007); the organisation
  publishes only the generic half of its shared documents
  (ADR-0008); and the
  consequences ADR-0006 recorded when it moved the organisation to AGPL-3.0-or-later are now carried
  through every document that had gone on describing the code as proprietary.

### Removed

- **No establishment ships with the product any more.** The pilot's `sites/<slug>/site.sh` and the
  generated `themes/apsconecta/core/css/site.css` are no longer tracked: both are per-install
  artifacts, and the repository promised in `README.md` and `AGENTS.md` to name no establishment
  while shipping a real one as the suggested default. A fresh clone now stops at "choose your
  establishment" and you pick one from the DEIS register with `scripts/deis.py`.

  **Before updating an existing working copy, copy your `sites/<slug>/` somewhere outside the
  repository.** Taking this change deletes the previously-tracked site file from your working tree.
  Restore it afterwards — it is ignored from now on, and `make install` converges exactly as before.

### Fixed

- `docs/LICENSING.md` §4.3 concluded that our own code "may therefore remain proprietary", citing a
  §1 that ADR-0006 had already reversed. The aggregation analysis survived the relicence; its
  conclusion did not.
- `CONTRIBUTORS.md` listed two developers who had never committed and held no access, and
  `CONTRIBUTING.md` and `SECURITY.md` both built on that roster — including a promise to answer
  security reports "as fast as a 3-person team can".

## [0.1.1] — 2026-08-08

### Fixed

- `07-certs` re-imported a certificate the bundle already held ([#143](https://github.com/APS-Conecta/gestion/issues/143),
  fixed in [#144](https://github.com/APS-Conecta/gestion/pull/144)). A container briefly too busy to
  answer looked exactly like a bundle holding nothing, so provisioning performed a *write* on an
  already-provisioned instance and failed the idempotency check in CI. Two defects shared the one
  line: "could not ask" was indistinguishable from "not imported", and the match read a rendered
  table whose column padding meant it was effectively asking which *other* certificates were
  installed. `scripts/test.sh` now carries a behavioural regression check covering both.

Same pinned apps and image digests as 0.1.0 — no functional change for a clinic.

## [0.1.0] — 2026-08-08

### Added

- The first installable release. Before it `git tag` returned nothing: every app was pinned by
  version and sha256 while gestion itself carried no version at all, so a clinic installed whatever
  `main` happened to be that day and a bug report could not name the bytes that produced it
  (ADR-0005).
- Pins six apps — five vendored upstream, plus `epidemiologia` built from a tag of its own
  repository. Nothing contacts the Nextcloud app store at any point: every app ships as a committed
  tarball verified by sha256 ([#98](https://github.com/APS-Conecta/gestion/issues/98)). Images are
  pinned by digest rather than tag.

[Unreleased]: https://github.com/APS-Conecta/gestion/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/APS-Conecta/gestion/releases/tag/v0.2.0
[0.3.0]: https://github.com/APS-Conecta/gestion/releases/tag/v0.3.0
[0.1.1]: https://github.com/APS-Conecta/gestion/releases/tag/v0.1.1
[0.1.0]: https://github.com/APS-Conecta/gestion/releases/tag/v0.1.0
