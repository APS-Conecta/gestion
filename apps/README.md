# `apps/` — Nextcloud apps (live-mounted, gitignored)

Bind-mounted to **`/var/www/html/custom_apps`** by `compose.yaml`. Two things land here, and only
this README is tracked (`.gitignore` un-ignores it explicitly):

- **Vendored apps** unpacked here by `provisioning/phases/12-apps.sh` — `groupfolders`, `side_menu`,
  `eurooffice`. Their upstream tarballs *are* committed, under `provisioning/apps/<id>/`, beside the
  `*.patch` files that edit them and a `VENDOR` file naming the version, URL and sha256. Nothing in a
  clean install contacts the app store (#98). See [ADR-0002](../docs/adr/0002-app-patches.md).
- **Custom apps**, one directory per app id with an `appinfo/info.xml`. **v1 ships none** (AD-1); the
  first is the REM app, which lives in its own repo and installs onto this platform.

**Boundary (AD-9):** a custom app may depend on Nextcloud only through `OCP\…` public APIs — never
patch core, never rely on private internals, and core never depends on a custom app.

**Linux ownership:** the container runs as `www-data` (uid 33). `make up` handles this via
`fix-mount-perms`; if discovery or enable still fails, `sudo chown -R 33:33 apps`.
