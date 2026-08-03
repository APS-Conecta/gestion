# `apps/` — Nextcloud apps (live-mounted, gitignored)

Bind-mounted to **`/var/www/html/custom_apps`** by `compose.yaml`. Two things land here, and only
this README is tracked (`.gitignore` un-ignores it explicitly):

- **Vendored apps** unpacked here by `provisioning/phases/12-apps.sh` — `groupfolders`, `side_menu`,
  `eurooffice`. Their upstream tarballs *are* committed, under `provisioning/apps/<id>/`, beside the
  `*.patch` files that edit them and a `VENDOR` file naming the version, URL and sha256. Nothing in a
  clean install contacts the app store (#98). See [ADR-0002](../docs/adr/0002-app-patches.md).
- **Custom apps**, one directory per app id with an `appinfo/info.xml`. **v1 ships one**,
  `epidemiologia` — [ADR-0003](../docs/adr/0003-this-stack-ships-a-custom-app.md) reverses AD-1.
  It lives in its own git repository and is declared in `OWN_APPS` in `12-apps.sh`, which **checks
  and reports** rather than re-imposing: `apps/` may hold a working tree someone is editing. A clean
  machine needs the clone first, and the phase prints the exact command if it is missing. The REM
  analyzer is the next one, on the same terms.

**Boundary (AD-9):** a custom app may depend on Nextcloud only through `OCP\…` public APIs — never
patch core, never rely on private internals, and core never depends on a custom app.

**Linux ownership:** the container runs as `www-data` (uid 33). `make up` handles this via
`fix-mount-perms`; if discovery or enable still fails, `sudo chown -R 33:33 apps`.
