# Changelog — APS Conecta Gestión

Every version a clinic can install. `main` is the development trunk; a release is a tag, and a clinic
installs a tag ([ADR-0005](docs/adr/0005-gestion-is-the-development-trunk.md)).

Format: [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

Each version links to its GitHub release, which holds the full notes. The pinned app versions and
image digests live there and are deliberately not copied here — one fact, one owner.

## [Unreleased]

### Added

- **The web installer opens with one HTTPS link** (L3 S1).
  - `sudo aps-conecta abrir` prints `https://<LAN-IP>:<port>/login#acceso=<code>` and the
    fingerprint of the installer's own certificate.
  - The installer's CA lives in `/opt/aps-conecta/certificados`: made once and kept; the leaf is
    re-signed for the link's address on every start.
  - The code rides the URL fragment and the session cookie is `Secure`, so nothing crosses the
    LAN in clear.
  - `GET /` opens the sign-in page, and the identity probe is `/api/salud`.
  - A second installer is refused, and the console no longer prints a request log.
  - A green «Revisar y ejecutar» closes the installer (port closed, link dead), and the console
    wires the timers and prints «Listo».
  - The pages follow the approved Instalador UI: the backdrop rail of the nine steps, read from
    the new `aps-conecta pasos` (the one list), the brand fonts served locally, a welcome and a
    «Listo».
  - `aps-conecta provision` is the same step as `abrir`.
- **«Elegir el centro» in the browser** (L3 S2).
  - Región › Comuna › Tipo de centro filters and an accent-blind search over the whole DEIS
    register, every type included. The card shows the type, DEIS code, address, comuna, región,
    Servicio de Salud and dependencia.
  - The installer holds the choice (`/api/centros`, `/api/centro`), so no DEIS code rides a URL.
    The choice can change until the site file is written.
  - One install, one establishment holds at every door: the browser's site step now refuses a
    second centre with 409, as the silent install already did. `/api/deis` is gone.
- **«Cargar equipos y personas» in one screen** (L3 S3).
  - Sectores and programas one per line, with the group code each derives shown underneath.
  - Saving different teams answers with what is new and what goes. «Reemplazar» rewrites the
    teams, folders and grants and keeps the rest of the site file. It is never a silent success.
  - The planilla:
    - a template built for the centre (`/api/plantilla`) that uploads back clean;
    - every error at once, in clinic words;
    - the valid groups listed when one is unknown;
    - `sí` as the admin flag.
  - The old sectores, componentes and planilla screens are gone. `--paso usuarios` prints a
    whole-file error with no line number, and lists the valid groups.
- **«Revisar y ejecutar» in clinic terms, followed live** (L3 S4).
  - The review shows the centre by name, its sectors and programs, every person with their
    groups, the cargo accounts, what the clinic gets (one component catalogue) and the maintenance
    schedule. It shows no paths, files or keys.
  - «Ejecutar» starts the run on the server and answers at once. The page follows it every second
    (`/api/ejecucion`) through the console's own step titles to the verdict, and a reload finds it
    where it is.
  - A red verdict shows its head line and points to `aps-conecta estado`. The divergence screen is
    gone.
- **«Iniciar la suite» from the browser** (L3 S5).
  - Step 7 lists the five APS apps with their versions and says whether Talk and its recording fit
    the server (memory, cores, port 3478), and why.
  - «Preparar el asistente» runs `aps-conecta asistente-aio --preparar`, which starts the
    mastercontainer and fills the wizard: domain, timezone, Euro-Office, Talk as it fits, and the
    daily backup at 04:00 with `/opt/aps-conecta` in scope. It stops before Start.
  - The page shows the wizard's passphrase while it is needed and follows each container by name
    to «Siguiente».
  - The wizard's refusals read in Spanish, in the console and on the page.
  - The domain the wizard took becomes the site file's `SITE_DOMINIO` and «Listo»'s access line.
- **The DEIS register carries each establishment's official point** (L5 S1).
  - `sites/establecimientos-deis-2026-07-23.csv` gains `latitud,longitud` for all 2,655 rows,
    from MINSAL's Geoportal de Chile dataset of June 2026. The provenance, and the dataset's
    unstated licence, are in `docs/LICENSING.md` §3.4.
  - `scripts/deis.py --coordenadas <geojson>` adds them after a `--snapshot`. A source that misses
    an establishment, or carries a value that is not plain degrees, is refused and the register
    stays as it was.
  - New site files carry `SITE_LON` and `SITE_LAT`.
  - The search matches the register's own columns only, so a number in the terms never matches a
    coordinate.
  - `make test` holds every row to a point inside the box the basemap covers.
  - A `--snapshot` whose points never came no longer breaks the installer with a traceback. Reading
    it stops with the way out: add the points, or remove it to fall back to the previous register.
- **The map is the suite's own `/tiles/` route** (L5 S3).
  - The nginx tiles container, `tiles.nginx.conf`, `TILES_PORT` and `TILES_PUBLIC_URL` are gone.
    The suite's apache serves `/srv/aps-conecta/tiles/chile.pmtiles` same-origin at `/tiles/`,
    read-only, with Range, an ETag and no compression.
  - The mastercontainer is created with `APS_TILES_DIR` in both modes, domain and IP. A suite
    already running without it is refused with its own remedy (`docs/INSTALLER.md` §9), and a
    map folder the start would misread is refused before anything runs.
  - Step 4 «Construir el mapa» builds the basemap before the browser opens — no site, no typed
    coordinates; the extract is bounded by three fixed anchors (Santiago, Hanga Roa, Punta
    Arenas), a failure stops the install like any step, and `APS_SKIP_MAP=1` stays for CI.
  - `scripts/refresh-basemap.sh` needs no `.env`, no site and no database.
  - Phase 16 derives `tile_url` from `overwrite.cli.url` (the phase 14 pattern); under dev compose
    it writes blank and territorio falls back to the OpenStreetMap raster.
  - `aps-conecta tiles check` proves the archive, apache's `/aps-tiles` bind and a ranged read
    through the suite's internal network — and no longer moves PMTiles bytes through the shell
    (B-036).
  - Smoke check 16 asserts the derived URL, the bind and a 206 with the `PMTiles` magic; Clean
    boot proves the route on the real apache, by domain and by IP, against a deterministic
    fixture.
  - **Upgrading a clinic installed before this release**: step 7 reds on a mastercontainer
    created without `APS_TILES_DIR` — the guard is new and the remedy is
    `docs/INSTALLER.md` §9 (re-create the mastercontainer **and** `aps-conecta-apache`; a
    changed value never re-creates apache on its own, so the old bind would survive a
    mastercontainer-only re-create). The next `sudo aps-conecta mapa` also removes the old map
    container (`aps-conecta-tiles`, the nginx on loopback 8084): the suite serves `/tiles/`
    itself now.
- **«Elegir el centro» opens on the map** (L5 S4).
  - The screen opens on the establishment's official register point (MINSAL/DEIS, Geoportal de
    Chile): the admin confirms it or moves it — a click or tap on the map, dragging the marker,
    or the arrow keys at 5 m (Shift, 25 m) — with «Punto oficial» to reset and a live readout
    («Oficial: …», «Elegido: … · N m al <rumbo>», a 3 m threshold).
  - The chosen point rides «Confirmar centro» beside the code, held server-side, checked against
    the archive's own bounds when it is readable (a point outside is refused naming the map), and
    written into the site file's `SITE_LON`/`SITE_LAT` at step 8 — where it survives «Reemplazar».
    A fixed site shows its point read-only, and the silent install's optional
    `SITE_LON`/`SITE_LAT` are validated when present. Revisión carries the «Ubicación» row
    (punto oficial, or corregida with the metres from the official).
  - The basemap is the suite's own archive, drawn by vendored Leaflet 1.9.4 and
    protomaps-leaflet 5.1.0 (byte-identical to territorio's, sha256-pinned by `make test`, served
    from `/recursos/` — `docs/LICENSING.md` §3) through the installer's auth-gated
    `/mapa/chile.pmtiles` route: single ranges, a strong ETag, 416 with `Content-Range:
    bytes */N`, bounded reads only. `GET /api/mapa` answers the coverage state.
  - A missing archive or a dead route is a note naming `sudo aps-conecta mapa` and a completable
    screen — the official ring and the pin on the plain background, «Confirmar centro» enabled.
- **`aps-conecta estado`** — the last execution's verdict, each item with its fix, in Spanish, with
  no sudo (`/opt/aps-conecta/estado.txt`, 0644, written by every execution — the installer's, the
  silent install's and the weekly one). When the weekly re-provision finds drift or does not finish,
  every member of the `admin` group gets one notification at their next login, replaced each week.
  The divergence gate's notes and verdict are now Spanish, in the console and in
  `aps-conecta estado`.
- **`sudo aps-conecta temporizadores`** — installs the weekly re-provision and the monthly basemap
  units from the bundle, reloads systemd and enables the weekly timer (and the monthly one once the
  map exists); a re-run finds them in place. It refuses when `/usr/local/bin/aps-conecta` is not
  this bundle's — the units would be skipped without a word. The silent install runs it itself.
  Both timers now fire on Santiago time (`OnCalendar=… America/Santiago`): the re-provision on
  Sundays at 03:00, the basemap on the 4th at 05:00. INSTALLER §6 no longer copies unit files.
- **Silent install: `sudo aps-conecta install --sitio site.sh --planilla usuarios.csv`** — the same
  nine steps with no prompt and no browser. The centre comes from the operator's `site.sh` (it
  must declare `SITE_DEIS` and `SITE_DOMINIO`; it is placed at `sites/<DEIS>/`, never over a
  different one), the suite is started and its wizard driven (`asistente-aio`), the planilla
  loaded, and the seed run with one Spanish line per phase — the whole log in `.install.log`.
  It ends with what to do next: hand out `credentials.txt` row by row, run `aps-conecta
  revalidate`. Clean boot now installs through it. New Provisionador steps: `--paso sitio
  --archivo`, `--paso generar --resumen`.
- **`provisionador.py --paso usuarios|generar`** — the installer's planilla and generate steps from a
  terminal, with no server: Spanish ✓/✗ lines and an exit code (0 done · 1 refused · 2 usage). The
  weekly `aps-conecta provision --reponer` now runs `--paso generar` in its own process — no second
  server, no token — and the journal shows the step's own ✓/✗ lines.
- **`aps-conecta asistente-aio --dominio D`** — configures and starts the suite through the AIO
  wizard's own API, with no browser: the one-time passphrase captured into a 0600 file (reused on a
  re-run), login, domain (`--sin-validar-dominio` for a disposable instance), America/Santiago,
  the options (office on; Talk, whiteboard and imaginary off), an optional `--respaldo` location,
  the start with a running count of containers (it pulls ~6 GB inside one request), the bounded
  waits, and the Nextcloud admin password into a 0600 file. A re-run on a running suite posts
  nothing. The CI testbed (`scripts/aio-testbed.sh up`) now calls it — one copy of the drive.
- **Two-line install on a fresh server** — `curl -fsSL …/<tag>/host/aps-conecta -o aps-conecta` and
  `sudo bash aps-conecta install` on Ubuntu or Debian: «preparar» installs git/python3, Docker Engine
  + Compose from Docker's own apt repository, adds the operator to the docker group and sets
  `vm.overcommit_memory = 1` (its own `/etc/sysctl.d` file); «descargar» clones the suite at the
  file's own release (`BUNDLE_TAG`) into `/opt/aps-conecta/gestion`, verifies every app's sha256 and
  links `/usr/local/bin/aps-conecta` (`ln -sf`). A re-run finds each step done; another installed
  version is refused, untouched. `preflight --dominio D` probes DNS before the wizard, and preflight
  tells a stopped docker service from a missing docker group.
- **`aps-conecta install`** — the install opens on a welcome screen and walks numbered steps,
  each with its purpose, command, result, next step and where it runs, in Spanish. One list of
  nine steps (five on the server, four in the browser) is also the CLI's subcommands
  (`revisar`, `preparar`, `descargar`, `mapa`, `abrir`, …), and `aps-conecta` with no argument
  prints a Spanish usage generated from it. Preflight and every operator error are Spanish too.
- **The welcome screen (IntraVox)** — the intranet surface as seeded content, not a fork:
  `provisioning/phases/41-intravox.sh` (engine setup, registry→engine group map, templated `es`
  import, page ACL) + the clinic-agnostic Spanish payload under `provisioning/intravox/es/`
  (homepage per Variante A, navigation, footer, news/avisos seeds, Vida CESFAM, Documentos, ten
  role/category pages, the Guía de equipos hub, one generated page per `SITE_TEAMS` entry).
  Zero upstream divergences, zero new `SITE_*` variables, `defaultapp` untouched until the
  promotion commit. Telemetry pinned free-tier (`intravox:telemetry_enabled=false`);
  divergence tolerances for the three engine groups + the `IntraVox` folder. ADRs
  [0014](docs/adr/0014-intravox-is-the-default-landing-app.md),
  [0015](docs/adr/0015-welcome-content-seeds-through-an-ungated-own-app-phase.md),
  [0016](docs/adr/0016-personal-layer-stays-page-level.md),
  [0017](docs/adr/0017-metavox-deferred-alert-expiry-is-editorial.md); operator/editor guide in
  [docs/WELCOME-SCREEN.md](docs/WELCOME-SCREEN.md). Design:
  `2026-09-24_aps-conecta-welcome-screen` (gestion workspace `.rpiv/artifacts/designs/`).

- **The storage folder is named for staff** ([ADR-0020](docs/adr/0020-the-storage-root-is-named-for-staff.md)):
  the seed tells the engine the mount name (`IV_MOUNT`, «Intranet») before creating it and
  refuses to seed an install whose folder still carries another name (the engine's default, or
  a previous `IV_MOUNT`) — that rename is a documented one-time runbook
  ([docs/WELCOME-SCREEN.md](docs/WELCOME-SCREEN.md)), and `make divergence` points at it instead
  of offering to delete the folder. Bienvenida and Cómo publicar say where pages live, naming
  `IV_MOUNT`. Needs an IntraVox engine with `MountName` (welcome-folders p5).

- **Estadística's establishment** ([ADR-0013](docs/adr/0013-the-establishment-is-instance-configuration.md),
  amended): phase 16 writes `deis_code`, `establishment_type` and `comuna_cut` from the site file,
  and stops the install on a `SITE_DEIS` that is not six digits, which the app would read as no
  establishment. `make divergence` reads the three back. The roadmap names Estadística where the
  REM app and Analytics stood, and `docs/CONTRACTS.md` lists its OCS surface.
- **Estadística ships** — promoted from lab to own at v0.1.0: `provisioning/apps/estadistica/`
  holds the tarball built from the tag and its `VENDOR`, `OWN_APPS` carries it and
  `dev/lab-apps.sh` is empty again. After install the app's RemJob downloads the DEIS window
  itself, ≈ 4.9 GB of database for the default 2023–2026. `scripts/check-org-drift.sh` compares it
  with territorio and CI clones it; `docs/LICENSING.md` has its row (twelve apps).
- **The organisation map registers the org's newest repositories** — an `IntraVox` row (the
  default landing app; fork truth and the upstream deltas cited from that repository's ADR-0001)
  and an `aps-common` row (the committed-subtree distribution, cited from its ADR-0001); the
  map's verified date moves to 2026-10-04.
- **ROADMAP §Next item 2 is now the L6 freeze contract** — what is frozen whole
  (`docs/INSTALLER.md`, `docs/GUIA-CLINICA.md`, the AIO fork declaration, `AIO/BUGS.md`,
  `AIO/patches/*`), what is frozen in place (the paused L5 S3 blueprint's touch sections, the
  INSTALLER/GUIA H2 anchors the AIO patches deep-link), the unfreeze gate (a23, gestion#205) and
  every open item the freeze holds — the deferral vehicle for the **suite-docs** rewrite and the
  instalador laps behind it.
- **Index rows for `docs/CONTRACTS.md`, `docs/MIGRATION.md` and `docs/WELCOME-SCREEN.md`** — the
  cross-module surfaces and the two operating runbooks were governed documents without a row.
- **The compliance horizon is on the roadmap** — four one-liners in [`ROADMAP.md`](ROADMAP.md)
  § *Next*: **Ley 21.719** (binding 2026-12-01) — staff-data access, rectification and erasure
  workflows plus the *encargado de tratamiento* template; **ficha clínica retention**
  (Ley 20.584 / DTO 41/2012) — 15 years with authorized destruction, a legal-hold posture the
  defaults do not provide; **MINSAL EIS FHIR drafts** — planned until the guides are normative;
  **AGPL §13 + trademark** — in-app access to the running Corresponding Source and the trademark
  attribution on the login and dashboard views. They arrive from the dissolved audit register
  (see *Removed*), where dated obligations did not belong.

### Changed

- **Groups by role** — the 22 shared roles name their category (the Ley 19.378 families: 4
  jefaturas, 10 clínicos, 3 técnicos, 5 administrativos), and every planilla user joins `all-staff`
  and the category of each of their roles. A site's own roles already named theirs.
- **Each cargo account has its own first password** — sealed into `credentials.txt` with the
  planilla's, one row per position (`Cargo director`, …). `FIXTURE_USER_PASSWORD` is now only for
  `make install` without the Provisionador (the compose lab, CI). The GUIA no longer claims the
  system forces a password change at first login: it tells each person where to change it.
  A cargo account created before this release keeps its password: before handing over its row,
  set it with `occ user:resetpassword <uid>`.
- **Planilla users reach the intranet on the first run** — the roster driver maps them into the
  IntraVox groups the seed already mapped (until now, only at the next weekly re-provision).
- **`credentials.txt` is kept after handover** (B-034) — the weekly re-provision reads it.

- **Language reality is the IntraVox engine's** — phase 41 no longer converges
  `intravox enabled_languages`; the engine's own defaults are the es-only deployment: `es`+`en`
  enabled and `es` as the primary language when unset. gestion writes no language config.
  [ADR-0018](docs/adr/0018-language-reality-is-the-engines-es-only-default.md).

- **The welcome tree is declared per site and converged per section** — `SITE_WELCOME` in
  `sites/<slug>/site.sh` (written by `scripts/deis.py`; the default has no `equipos`) names the
  sections, and phase 41 converges them on every seed: added when declared and missing, never
  touched when present (a later seed imports only what is new, so a page staff deleted stays
  deleted), reported by `make divergence` when live but undeclared; the engine is told
  `--skip-existing` and never overwrites. `provisioning/intravox/render.py` renders the tree —
  home tiles, menu, footer and the Documentos links come from the declaration; the ten
  hand-written team pages are gone, a team page is a declared `SITE_TEAMS` entry under a declared
  `equipos`. [ADR-0019](docs/adr/0019-the-welcome-tree-is-declared-and-converged-per-section.md)
  supersedes ADR-0015's import-once. Existing site files need the `SITE_WELCOME` block by hand
  ([docs/WELCOME-SCREEN.md](docs/WELCOME-SCREEN.md) § Declaring the tree). Needs an IntraVox
  engine with `occ intravox:import --skip-existing`.
- **Talk follows the suite's option** — under AIO, phase 12 installs spreed only when the suite
  runs Talk (`TALK_ENABLED`, the switch the AIO entrypoint reads), and «Revisar y ejecutar» lists
  Talk only when step 7 gave it to the suite. The fork starts Talk off; with Talk off the entrypoint
  removes spreed on every boot, which the seed used to re-install. Compose keeps Talk.
- **The password breach check is off** — phase 16 sets `password_policy` `enforceHaveIBeenPwned`
  to `0`: Nextcloud no longer sends each new password's SHA-1 prefix to api.pwnedpasswords.com.
  Smoke asserts it with the other policy switches.
- **The install docs describe the suite the wizard now is** — «APS Conecta Gestión AIO»; Euro-Office
  the only office; no community containers; Talk, Whiteboard and Imaginary off until step 7; no
  territorio card. `docs/INSTALLER.md` §12 has the reinstall-from-scratch recipe the wizard's reset
  links open, and §13 says a stock Nextcloud AIO backup is not restored into the suite.
  `aps-conecta datos` says territorio is not installed yet, not «pendiente de empaquetado».
  `make test` checks that the six doc anchors the wizard links still resolve.
- **The suite's containers are `aps-conecta-*`** (the AIO fork's patch 240). Every caller, the
  testbed, Clean boot and the docs follow; the wizard stays `nextcloud-aio-mastercontainer`, the
  network `nextcloud-aio` and the volumes `nextcloud_aio_*`. Clean boot runs the fork's suite
  (the CI suite tag `scripts/aio-testbed.sh` pins), not upstream's. Fresh installs only: an instance from
  v0.3.0 or earlier keeps its `nextcloud-aio-*` containers and is reinstalled (`docs/INSTALLER.md`
  §12). `make test` refuses a sibling spelled the old way.

- **Install by IP over HTTPS** (L4 S6b, R22) — a clinic without a domain writes one of the server's
  IPv4 addresses where the domain goes (step 7 or `SITE_DOMINIO`); another server's address is
  refused and the wizard's domain check is skipped.
  - `provisionador.py --paso certificado-suite --ip A` signs the suite's leaf from the installer's CA
    into `/opt/aps-conecta/certificados/suite` (apache's, 0400) and copies the CA's certificate alone
    to `…/ca/aps-conecta-ca.crt`. The weekly run signs it again 30 days before it expires and
    restarts apache whenever it started before the leaf on disk. The CA is never made again under an
    install by IP: a missing one stops the run (restore from the backup).
  - The run command gains `APS_TLS_DIR` and `NEXTCLOUD_TRUSTED_CACERTS_DIR` by IP only; a suite
    started for a domain is refused for an address (reinstall, `docs/INSTALLER.md` §12).
  - Phase 07 imports the CA into Nextcloud's own bundle; phase 14 points Euro-Office's
    server-to-server URLs inside the suite's network.
  - Step 7 offers the CA («Descargar el certificado», `/api/ca`) with its fingerprint, and the
    install's last lines print both. `docs/INSTALLER.md` §14 and `docs/GUIA-CLINICA.md` §11: the CA
    on Windows, macOS, Ubuntu and Android.
  - Clean boot gains a job that installs by the runner's own IP with the silent command alone and
    checks the CA end to end: trusted with it, refused without it, imported by Nextcloud; a planilla
    user logs in; push and office pass their own checks; the weekly run keeps the leaf and apache.
- **The manuals' one-owner dedup sweep** (docs). Sections that restated another file's content now
  point at its owner instead.
  - `docs/manuals/ADMIN_MANUAL.md` §3 collapses to a pointer stub — the clinic install is
    [`docs/INSTALLER.md`](docs/INSTALLER.md) and [`docs/GUIA-CLINICA.md`](docs/GUIA-CLINICA.md)'s,
    the dev path the [README quickstart](README.md#quickstart)'s, the container lifecycle `make help`'s.
  - `docs/manuals/USER_MANUAL.md` §9.2 keeps the platform story and defers the farmacia walkthrough
    to farmacia's own manual; §2.6 names all five own apps; §6.1 and §7.1 point at the AIO readme's
    patch table for the wizard's office/Talk pins.
  - `docs/manuals/DEVELOPER_MANUAL.md` §1.3, §2.1, §5, §5.4 and §7.1 collapse to pointers at
    [`CONTEXT.md`](CONTEXT.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) § *Runtime topology*,
    [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md) + [`docs/BRANDING.md`](docs/BRANDING.md),
    ADR-0004, and ADR-0010 + [`docs/LICENSING.md`](docs/LICENSING.md).
  - `docs/CONTRACTS.md` drops the OCS table's route column — the per-app `openapi.json` is the
    published surface.
  - The brand kit is named outside-git at its three pointer sites (`docs/BRANDING.md` §9,
    `docs/THEMING-MODEL.md` layer D, `themes/apsconecta/MAPEO.md` §2); licence facts stay
    [`docs/LICENSING.md`](docs/LICENSING.md)'s.
- **The README `scripts/` row now lists every script** — the ten it missed each get their one phrase.
- **The registers are current.** The organisation map no longer names the two out-of-project
  repositories (their facts stay with their owners), the territorio reversal paragraph records
  ADRs 0015/0016/0017 as implemented with their five code anchors, and the AIO row records the L4
  wizard fork. The manuals tree reads **14-Phase** throughout and §4 names `41-intravox.sh`
  (a pointer to `docs/WELCOME-SCREEN.md`); AD-6 carries the ADR-0004 forward note
  ([ADR-0004](docs/adr/0004-branding-the-legacy-render-path.md)); the compose comments cite D7
  and ADR-0003 where they cited the reversed AD-1; every documentation index table is the
  four-column Document × Mode × Reader × Authority standard.
- **`docs/ORG-MAP.md` retires the four deleted forks** (docs) — *Retired* records `server`, `formvox`,
  `Welcome` and `Gestion-Mobile` (deleted 2026-10-03) and `server` leaves the ownership table; the `Databases`
  paragraph now says what that repository ships since its 2026-10-04 re-creation (docs CI; a
  freshness gate red by design, per its ADR-0002) instead of "no CI" and "no REM README".

### Removed

- **`scripts/final-validation.sh`** — the whole-installer harness kept a second copy of the wizard
  drive; the release rehearsal installs a fresh box the way a clinic does (`docs/INSTALLER.md` §10).
- **Two repository rows and one correction bullet from the organisation map** — the map names
  only what this project's documentation governs.
- **The Epic-5 row's "both turned out unnecessary" clause** — `defaults.php` is tracked,
  load-bearing and smoke-gated; the row's date and shipped facts stay.
- **The manuals' inline boilerplate** — the four `<style>` blocks (USER, ADMIN, DEVELOPER, the
  manuals README), the three Master Tables of Contents and the DEVELOPER manual's `Target File`
  scaffold line are gone; `docs/manuals/style.css` owns the hero card verbatim (`.aps-hero`,
  `.aps-hero h1`, `.aps-tag`, `.aps-meta` replace the dead `.aps-header-*` rules) and the USER
  manual's `## 1.` heading no longer claims an index. ≈ −400 lines.
- **Obsolete instalador patch — do not re-apply at resume**: L5 S3's P6 durable hunk
  (`@@ -116,7 @@`, `docs/manuals/ADMIN_MANUAL.md` Master TOC rows) lost its target when the
  Master TOC was deleted (previous entry) — drop that hunk when resuming S3.
- **The audit register** — the fourth manual under `docs/manuals/`, an inventory of
  inconsistencies, architectural debt and stubs across the suite, is gone. Each item moved to
  its owner: the four hardening findings (Redis authentication, 2FA enrollment, audit logging,
  `trusted_proxies`) to the org's private tracker — no hardening detail stays in a public repo;
  seven app-debt findings to public issues in the owning repos (territorio, farmacia,
  epidemiologia, gestion); the regulatory cliffs to `ROADMAP.md` § *Next* (the compliance
  horizon, above); the bug ledger already lives in [`BUGS.md`](BUGS.md) and the findings ledger
  in the org's tracker. The manual set is three again; [`docs/index.md`](docs/index.md) and the
  manuals cover page say so.

### Fixed

- **The daily backup runs at 04:00 Santiago time** (B-035) — the AIO mastercontainer runs in UTC,
  so the «04:00» step 7 posted ran at 00:00 or 01:00. Step 7 now posts the UTC hour that is 04:00
  in Santiago; on a host without tzdata it stops before any post and the installer's page names the
  cause. `docs/INSTALLER.md` §11 states the hour drift across a DST change.

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
  inventory move. ADR-0003's two own apps.
- **The comuna data packages** — the national masters pinned in `provisioning/data/packages.json`,
  the DEIS comuna reference derived beside them, and `scripts/comuna-package.sh`: one fetch, one
  seconds-long cut, the exact import commands printed.
- **The release manifest** — `scripts/release-manifest.sh` + the tag-triggered workflow: every
  release gets a machine-readable union of what it pins, as a GitHub Release asset.
- **notify_push, vendored for the AIO bake** — this stack installs it from no inventory; the bake
  needs the bytes with provenance.
- **The establishment-agnostic gates** — the shape-based ADR-0013 check, the sites/ register-only
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
  instance configuration (ADR-0013), and no app consumes it.
- **The repo stops naming its pilot** — living docs AND dated history (ADR-0013 carries a dated
  correction; the register CSV, the public MINSAL catalogue, is untouched).
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
  dropped in ADR-0005/#142. It is the largest thing in the repo now — 18.9 MB against the next at
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
  cloned things ([ADR-0011](docs/adr/0011-org-wide-facts-live-in-gestion.md)); the organisation
  publishes only the generic half of its shared documents
  ([ADR-0012](docs/adr/0012-only-the-generic-half-is-published-as-an-org-default.md)); and the
  consequences ADR-0010 recorded when it moved the organisation to AGPL-3.0-or-later are now carried
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
  §1 that ADR-0010 had already reversed. The aggregation analysis survived the relicence; its
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
  ([ADR-0005](docs/adr/0005-gestion-is-the-development-trunk.md)).
- Pins six apps — five vendored upstream, plus `epidemiologia` built from a tag of its own
  repository. Nothing contacts the Nextcloud app store at any point: every app ships as a committed
  tarball verified by sha256 ([#98](https://github.com/APS-Conecta/gestion/issues/98)). Images are
  pinned by digest rather than tag.

[Unreleased]: https://github.com/APS-Conecta/gestion/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/APS-Conecta/gestion/releases/tag/v0.2.0
[0.3.0]: https://github.com/APS-Conecta/gestion/releases/tag/v0.3.0
[0.1.1]: https://github.com/APS-Conecta/gestion/releases/tag/v0.1.1
[0.1.0]: https://github.com/APS-Conecta/gestion/releases/tag/v0.1.0
