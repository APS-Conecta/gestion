# Changelog — APS Conecta instalador

Every version a clinic can install. `main` is the development trunk; a release is a tag, and a clinic
installs the tag's signed package (the `install.sh` bootstrap; aps/RELEASING.md owns the ritual).

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

Each version links to its GitHub release, which holds the full notes. The pinned app versions and
image digests live there and are deliberately not copied here — one fact, one owner.

## [Unreleased]

### Changed

- **The install one-liner always resolves to the newest Release (#262).** Every Release now
  publishes `apsconecta-install.sh` — the install asset under a stable name, byte-identical
  to its versioned twin — and the runbooks serve it from `releases/latest/download`, so the
  line an operator copies never 404s on a new version. The tag pin travels inside the bytes
  (`BUNDLE_TAG` + `TARBALL_SHA256`, filled at cut time): the sha256+signature verification
  before anything unpacks is unchanged, `fail-on-prerelease` keeps `latest` a full Release,
  and the versioned asset still ships for tag-pinned installs and audits. Clean boot
  rehearses the bootstrap through the mirrored `latest` URL; the alias exists only on
  Releases cut after this change (published assets never move).

- **`aps-conecta actualizar` uninstalls a release app whose row left the manifest (#172).** The plan
  names it, the run removes it last (`occ app:remove`, data included; the backup the run takes first
  is the way back) and the new lock drops its row, so a warm server converges on the suite's apps.

### Fixed

- **Nextcloud's instance time zone follows the zone chosen in AIO (APS-Conecta/totem#7).** Phase 10
  now seeds `default_timezone` from the Nextcloud container's `TZ`, so Totem's Día, opening-hours
  check and ticket times follow the clinic's clock instead of UTC.

## [0.6.0] — 2026-10-27

### Added

- **The #54 acceptance, as one command on a scratch Ubuntu 24.04 VM (`scripts/vm-acceptance.sh`).**
  The real `curl | sudo bash` from a real release URL with no token (`latest` resolves by
  redirect), the silent install with the three optional apps chosen, and the ticket's
  criteria as ✓/✗ lines with evidence: the verified bootstrap, `aps-conecta estado`, the
  suite's answer through the installer's CA (and its refusal without it), a planilla user over
  OCS, every default app installed from its channel (own/fork from their releases at the
  locked tag — tarball, hash, no `signature.json` — store apps enabled) plus the functional
  opens (notify_push's self-test, the office connector), each chosen optional installed and named
  in the wizard's options record, and `actualizar --revisar` printing the plan while writing
  nothing. `--dominio` covers the domain posture (public 443 + DNS, ACME as upstream); by IP any
  VM qualifies. Hermetic self-test (`--self-test`, wired into `scripts/test.sh`) pins the
  classification with PATH shims; the ritual itself is aps/RELEASING.md §7.

### Removed

- **The unused upstream AIO parts, with their hidden readers (#48).** Community containers
  (the directory, the mastercontainer's empty-dir creation, the wizard's PHP readers — the
  directory constant, the config property, the listing method, the community-form handler, the
  Caddy trusted-proxy variable `CADDY_IP_ADDRESS` and its `ADDITIONAL_TRUSTED_PROXY` env, the
  dead jellyfin/caddy/scrutiny/makemkv special cases, the form script's community half), the
  Helm chart, manual install (with the root `compose.yaml`, the compose-start file whose image
  pin pointed at upstream's registry), the upstream QA plans under `tests/QA`, the upstream app
  directory (with its five readers — the nextcloud Dockerfile's COPY into the server's apps, the
  entrypoint's enable-after-upgrade and marked AIO-app block, the major-upgrade codetree copy,
  and upgrade-latest-major's enable leg; no Nextcloud surface redirects into the wizard any
  more), the upstream root docs (`readme.md`'s upstream body, `develop.md`, the `docker-*`
  guides, `local-instance.md`, `manual-upgrade.md`, `migration.md`, `multiple-instances.md`,
  `reverse-proxy.md`, and the Nextcloud policy files `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
  `AI_POLICY.md` — AGENTS.md already carries the fork's own rules), and the inert workflows
  (`community-containers.yml`, `helm-release.yml` — which could never fire on this repository,
  `lint-helm.yml`, `update-copyright.yml`). What stays at the root is the LICENSE and the short
  fork declaration: `readme.md` is the declaration block alone now. The validators lost their
  community-JSON loops (`validate.sh`, `json-validator.yml`), `rename-containers.py` its
  community walk, and the gates' rows were re-cut to pin the removals (row 190 the closed
  channel, row 239 the dropped route) instead of the half-states they pinned before.
- **The migration path, whole (#48).** `scripts/migrate-to-aio.sh`, its choreography
  `aps/MIGRATION.md`, and the migration's mechanized halves (`scripts/db-dump.sh`, the verified
  plain-SQL dump of the old compose stack; `scripts/uninstall.sh`, that stack's teardown) are
  gone, with the acquisition gate's skip.update arm — it existed to protect the migration
  channel — and the dump/uninstall self-test arms. The runbooks' migration sections went with
  them (INSTALLER §13, GUIA §9; the sections renumber) and `retire_tile_remnants`, the v0.4
  basemap-remnant retirement in the host CLI, is removed with its self-tests: v0.5.0 is
  clean-install only and no v0.x install is in production.
- **The `/tiles/` route (#48, the #23 redo).** The read-only-bind mechanism the PMTiles
  retirement left behind — the Caddyfile route, the `APS_TILES_DIR` setting and `%APS_TILES_DIR%`
  bind in `containers.json`, and the mastercontainer's guard — is removed: a request for
  `/tiles/*` falls through to Nextcloud's catch-all and answers its own 404. Brand-gate row 239
  now pins the drop (no route, no token in any surface the route introduced). The TLS floor
  stays as #80 landed it: pinned on 443 only, where the site is https.

### Changed

- **Stray bytecode is untracked.** `.gitignore` now covers `__pycache__/` and `*.py[co]` — the
  bytecode a local gate or resolver run leaves beside the scripts can never land in a commit.

### Added

- **Talk (spreed) from the fork's signed releases (#145, ADR-0020).** The last app-store
  reach at a container boot is gone: `APS-Conecta/spreed` is a zero-code-change fork of
  `nextcloud/spreed` hosting our App releases, refreshed from upstream's newest stable
  release for the suite's Nextcloud major at each suite release — the release chain dispatches
  the fork's refresh (the app key never leaves the fork's release environment, ADR-0001),
  waits bounded, and verifies what it published against the tag tree's own `apps.pub` and
  against upstream's own bytes (the release is upstream's tarball minus exactly
  `appinfo/signature.json`, at upstream's own commit) before the suite Release exists. The
  manifest's spreed row is `source: fork, release: true`; installs resolve it through the
  resolver's usual proof chain and pin it in the lock, gated on the record's Talk switch
  (Talk off resolves nothing — the same gate phase 12 reads through `TALK_ENABLED`; the
  absent-record case never turns Talk off). The nextcloud entrypoint's scoped
  `app:install spreed` is deleted: its Talk block is presence-gated configuration alone, so
  a first boot with Talk on installs nothing of Talk's and the TURN/STUN/HPB wiring converges
  at the first boot after provisioning lands the app. `notify_push` is the scoped store
  open's only first-boot user. The acquisition gate's row 042 is re-cut accordingly and a new
  row 145 pins the tree's half; clean-boot asserts spreed's release install with Talk on and
  its total absence with Talk off, and `aps-conecta actualizar` moves spreed with the other
  release rows through phase 12 (its old store-walk skip line is deleted). The fork's first
  release is upstream's spreed `v24.0.6` (the newest stable for Nextcloud 34), published;
  the release chain's dispatch needs the owner-only `SPREED_REFRESH_TOKEN` secret
  (aps/RELEASING.md), missing which the spreed job reds naming the setup.

- **`aps-conecta actualizar`, the applications update (#46, ADR-0017).** The one path that
  moves the lock deliberately. It refuses to run unless the suite is up, the lock exists and
  the backup is configured; prints the plan — current and candidate per application, `--revisar`
  printing it and writing nothing (asserted in clean-boot on the lock bytes, the stored tarballs
  and the backup archive list); takes a **full backup through the wizard's own API** and stops
  unless it succeeds; restarts the suite with the wizard's own no-pull flag (`bypass_container_update`
  — the update moves apps, never images); fetches and verifies the newest compatible releases into a
  NEW lock beside the old one (the resolver gains `plan` and `actualizar`: the lock as a floor,
  never below it, a pin never moving, an unchosen optional row carried over — never erased);
  applies them through phase 12 itself reading the new lock, with store applications updated by
  one scoped `occ app:update` each and the store asserted closed again after the run; moves the
  lock only when everything succeeded; and revalidates. A failure names the application and the
  restore command (the wizard's «Restaurar la copia de seguridad seleccionada») and changes
  nothing. The major-bump guard rides the resolver's floor rule: when nothing at-or-above the
  installed release is compatible with the running Nextcloud major, the one refusal #46 owes —
  an app already at its newest compatible release resolves to itself («sin cambios», never a
  refusal). Clean-boot proves all three arms against the real hub: a normal update from an older
  lock (a new backup archive, the lock moved, the instance running what it names, revalidate
  green, the store closed), and a bad signature through a local tamper proxy — one tampered
  `SHA256SUMS.minisig`, everything else relayed to the real GitHub — refusing before anything
  moves.

- **Estadística as an optional app (#40, ADR-0017).** The second optional row: its manifest
  entry flips to `optional: "off"` + `release: true` and it arrives from its own signed
  release (APS-Conecta/estadistica `v0.2.0`, the app repo's first: shared workflow, untracked
  bundles, `.nextcloudignore`, the vendored docs checker gone — Docs-SSOT S2a riding its PR).
  Chosen (`--app estadistica`, the wizard's checkbox or the silent flag), it installs at its
  locked tag like farmacia; unchosen it is absent with no lock row and the bake's 0.1.0 never
  imposed. Its DEIS data is the app's own to fetch (ADR-0005 there): nothing moves during
  provisioning, and the figures arrive after install through the app's hourly job — so «no
  choice, no DEIS download» is the app's absence itself, asserted in clean-boot as the empty
  `deis_checked_at`/`deis_register` (the identity keys phase 16 writes are config rows, not
  the app), and «chosen» as the job's first tick: `deis_checked_at` set and the Base de
  Establecimientos imported within minutes of the install, the REM window queued behind it.
  A repeated provisioning keeps the choice beside farmacia's.
- **Tótem installs from its own release, when chosen (#41, ADR-0017).** The suite manifest
  gains its third optional row: `optional: "off"`, `release: true`, Spanish name and summary
  in the wizard's «Aplicaciones opcionales» card, installed only when the operator checks it
  (the same options record farmacia rides, #39), absent otherwise — nothing bakes totem, so
  unchosen means the server never even holds its bytes. Its first signed release is `v0.3.0`,
  whose tarball carries the two committed Piper voices under `js/tts/` (~160 MB, the app's
  ADR-0005): the release builds the app's bundles, but the voices ship as tracked bytes, so the
  waiting-room display speaks offline with no build step. The clean-boot arms assert both
  halves: unchosen → no lock row, no store, no app; chosen → installed at its locked tag, both
  voices served to the display page over https.
- **The release package asks a VENDOR only of default rows (#41).** An optional row never
  bakes — phase 12 skips it before any arrival path — so totem, optional from day one and
  never vendored, needs no `provisioning/apps/totem/VENDOR`; the packager's manifest-vs-bake
  gate now reads that as the expected shape (a default row without its VENDOR still reds).

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
- **Optional apps in the wizard, farmacia as the tracer (#39, ADR-0017).** Step 6 offers an
  «Aplicaciones opcionales» card read from the suite manifest (Spanish name and summary), all
  off by default, and the choice rides the same install options as Talk:
  `aps-conecta asistente-aio --app <id>` (and `install --app <id>`, the silent path) records every
  optional row in the wizard's options record. Without the choice the app installs never: the
  fetch leg resolves nothing, phase 12 skips the row before any of its three paths, and the seed
  never imposes or enables the bake's copy (the image still carries its bytes until #42 — an
  uninstalled directory, not an app). With it, farmacia arrives from its own signed release at
  its locked tag — its manifest row flips to `optional: "off"` + `release: true`, and needs
  APS-Conecta/farmacia's `v0.12.0` published first. A repeated provisioning keeps the choice:
  the record is re-read, the lock does not move, nothing downloads. Un-choosing on a warm server
  keeps what runs (nothing here uninstalls; `occ app:remove`, by hand) — the manifest flip-back's
  doctrine.


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

### Changed

- **No image carries an app — the store opens scoped, nothing else does (#42, ADR-0018).** The
  Nextcloud image now carries the apsconecta theme from the tag tree and nothing else of the
  suite's. Own and fork apps were already on their own signed releases (ADR-0017); the store
  rows (calendar, contacts, groupfolders) now install during provisioning through `occ_store` —
  a scoped command that carries its own `NC_appstoreenabled=1` (the env channel beats both
  `config.php` and the image's own store-off ENV for that one process and dies with it) — and
  the Nextcloud entrypoint installs notify_push and Talk the same way, only when they are
  missing. A bare `occ app:install` fails against the image ENV, the store reads closed in the
  admin UI, every update path keeps the store closed, and AIO's Saturday automatic
  `app:update --all` is deleted outright (the env that armed it is passed no more). Store apps
  install once and never move in place: apps change only when the operator decides
  (`aps-conecta actualizar`, #46). The clean-boot rehearsal asserts all of it: nothing baked at
  first boot, the store apps landed, the bare install refused, no `UPDATE_NEXTCLOUD_APPS` in
  the container; the acquisition gate's 042 rows pin the same in the tree.

### Removed

- **The bake and the last read of the old gestion (#42, ADR-0018).** `scripts/bake.sh`, the
  gestion clone in the Images workflow and its `gestion-ref` input, `provisioning/apps` in the
  composite package, `.paquete.json`'s gestion provenance fields, the vendored fallback of
  phase 12 (a release row without a lock row is now a FATAL naming the repair, never an
  improvised install), the patch machinery (`apply_patch`) that fed on vendored tarballs, and
  the old gestion's release-freeze window in the release ritual — the suite tag is the whole
  source of a release now.
- **The per-repo community files (docs-SSOT S2a, shaped like APS-Conecta/aps-common#10).**
  `.github/ISSUE_TEMPLATE/` (Bug_report.md, Feature_request.md, config.yml — upstream AIO's own,
  still pointing at nextcloud's forums) and `.github/pull_request_template.md` leave the tree:
  the org defaults in `APS-Conecta/.github` serve the community files now (ADR-0008's consequence
  updated to say so). No `guard.yml`: the repo is public after #29, so secret scanning and push
  protection are GitHub's, not a workflow's. `docs/agents/triage-labels.md` carries no «Edit the…»
  line to drop — instalador's copy never had one.
- Upstream's default startup-app set (deck, twofactor_totp, tasks, calendar, contacts, notes — comma-spelled
  here so the gate's literal scan stays honest). The fork's fallback for `NEXTCLOUD_STARTUP_APPS` is now the
  empty string, so the suite manifest (`apps.json`) is the only app list in the suite repo. A clean boot
  installs the same apps as before: the host CLI already passed the empty value regardless (#67).

### Fixed

- **The preflight asks no app bytes of a bundle that carries none (#42, A-026).** Step 3's VENDOR
  walk — every default row demanded `provisioning/apps/<app>` beside a sha256-pinned tarball —
  survived the bake it checked and reddened the no-apps package eleven rows deep into «vuelva a
  descargar la suite completa», killing both clean-boot jobs at Paso 3. The walk is gone with the
  bake: the step verifies the bundle's own shape — a readable manifest, and no `provisioning/apps`
  at all (a bundle that carries one is refused in the operator's words) — with self-test arms on
  both shapes.
- **The nextcloud container is created again (#42, A-027).** `php/containers.json` still passed
  `%UPDATE_NEXTCLOUD_APPS%` after the arm that answered it died with the Saturday update leg, so
  `getPlaceholderValue` fell to its unregistered-secret default and aborted the wizard's
  container start mid-recursion — `aps-conecta-nextcloud` was never created and the nothing-baked
  bring-up timed out at twenty minutes. The env line is gone from containers.json (the container
  never receives the variable, exactly what the entrypoint-side deletion intended), and the
  acquisition gate's 042 row greps containers.json beside the entrypoint so a placeholder without
  its arm reds in the static gate, not in a bring-up.
- **The Playwright suite pulls a chassis the registry has (A-028).** `php/tests/compose.yaml`
  still named upstream's `all-in-one:develop`, a tag the fork never publishes — every run since
  the suite-tag lockstep red at the pull with manifest unknown (main included). The chassis is
  now the suite-tag pin in `scripts/aio-testbed.sh`, resolved by `php/tests/run.sh` into
  `AIO_CHASSIS_IMAGE` (the same single source cleanboot installs, `AIO_TEST_IMAGE` overriding
  exactly as the testbed's own default), the wizard's host publish rides `AIO_TEST_PORT`, and
  the compose interpolation is required so a second literal cannot quietly return.
- **The host bundle's self-test is hermetic again (A-029).** The eight-step silent-install arm
  reddened on the missing `SITE_COMUNA_CUT` whenever a real `aps-conecta-nextcloud` answered on
  the box — green on a clean runner, red beside a live suite. The arm now stubs `cmd_datos` like
  its D9 siblings; the comuna tail keeps its own dedicated arms.
- **Smoke's signature check watches a signal that can exist (#133, A-030).** Check 10 globbed
  `provisioning/apps/<app>/*.patch` — a path #42 deleted with the bake — so it passed vacuously
  on every run since. It now asserts the live edge of the same invariant: no release app (the
  manifest's own and fork rows) carries `appinfo/signature.json`, whose presence means
  upstream's tarball replaced the fork's release — a release never packs one (`releases.py`
  refuses it) and the seed re-imposes its bytes; store apps keep their own true signatures. The
  mirrors still spelling the dead `UPDATE_NEXTCLOUD_APPS` env (manual-install, the helm chart —
  upstream's bytes, whose containers do read it) carry a line saying why it stays: inert here on
  purpose.

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
- `suite_tag()` reads the package's `VERSION` first.

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

- **Talk (`spreed` 24.0.5) is part of the suite**, vendored as pinned tarballs like every other
  app, so a clean install still needs no network and no app store (#98). Two things about Talk are
  recorded in its `VENDOR` file rather than left to be found: it reaches an **external STUN
  server** (`stun.nextcloud.com:443`) by default to discover a caller's own address, and **group
  calls stay small — around four people — without a High Performance Backend**, which this stack
  does not run. Chat and one-to-one calls are unaffected by the second. Talk's tarball is 52 MB,
  more than every other vendored app put together, and git keeps a full copy per bump: it is now
  the first place to look if this repo has to go on a diet.

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
