# `apps/` — Nextcloud apps (live-mounted, gitignored)

Bind-mounted to **`/var/www/html/custom_apps`** by `compose.yaml`. Two things land here, and only
this README is tracked (`.gitignore` un-ignores it explicitly):

- **Store apps** installed by `provisioning/phases/12-apps.sh` — `groupfolders`, `side_menu`,
  `eurooffice`. Their code is not committed; edits to them are committed as `*.patch` files under
  `provisioning/apps/`, per [ADR-0002](../docs/adr/0002-app-patches.md).
- **Custom apps**, one directory per app id with an `appinfo/info.xml`. **v1 ships none** (AD-1); the
  first is the REM app, which lives in its own repo and installs onto this platform.

**Boundary (AD-9):** a custom app may depend on Nextcloud only through `OCP\…` public APIs — never
patch core, never rely on private internals, and core never depends on a custom app.

**Linux ownership:** the container runs as `www-data` (uid 33). `make up` handles this via
`fix-mount-perms`; if discovery or enable still fails, `sudo chown -R 33:33 apps`.
