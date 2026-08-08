# `apps/` — Nextcloud apps (live-mounted, gitignored)

Bind-mounted to **`/var/www/html/custom_apps`** by `compose.yaml`. Two things land here, and only
this README is tracked (`.gitignore` un-ignores it explicitly):

- **Vendored apps** unpacked here by `provisioning/phases/12-apps.sh` — `groupfolders`, `side_menu`,
  `eurooffice`, `calendar`, `contacts`. Their upstream tarballs *are* committed, under
  `provisioning/apps/<id>/`, beside the `*.patch` files that edit them and a `VENDOR` file naming the
  version, URL and sha256. Nothing in a clean install contacts the app store (#98). See
  [ADR-0002](../docs/adr/0002-app-patches.md).
- **Own apps**, one directory per app id with an `appinfo/info.xml`. **A release ships one**,
  `epidemiologia` — [ADR-0003](../docs/adr/0003-this-stack-ships-a-custom-app.md) reverses AD-1.
  It is declared in `OWN_APPS` in `12-apps.sh` and installs from a **tarball** under
  `provisioning/apps/epidemiologia/`, built from a release tag of its own repository: an install
  needs no network and no git. On a development machine, where this directory is a live clone
  instead, `ensure_own_app` sees the `.git` and leaves the working tree alone.
- **Lab apps** — ours, under development, **never in a release**: `territorio`, `analizador_rem`.
  They are clones here and declared in [`dev/lab-apps.sh`](../dev/lab-apps.sh), which is tracked but
  inert — `12-apps.sh` acts on an entry only where `apps/<id>/.git` exists, so a clinic falls
  through. See [ADR-0005](../docs/adr/0005-gestion-is-the-development-trunk.md). To add one: clone it
  here under its **app id** (`analizador-rem` → `apps/analizador_rem`), add a line to
  `dev/lab-apps.sh`, then `make fix-mount-perms && make seed`.

**Boundary (AD-9):** a custom app may depend on Nextcloud only through `OCP\…` public APIs — never
patch core, never rely on private internals, and core never depends on a custom app.

**Linux ownership:** the container runs as `www-data` (uid 33). `make up` handles this via
`fix-mount-perms`; if discovery or enable still fails, `sudo chown -R 33:33 apps`.
