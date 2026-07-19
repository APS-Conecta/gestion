# `apps/` — custom Nextcloud apps (live-mounted)

This directory is bind-mounted to **`/var/www/html/custom_apps`** in the running Nextcloud
(`compose.yaml`), so you can add and **edit custom app code and see it live** — no image rebuild, no fork.

- **One directory per app**, named by the app id, each with an `appinfo/info.xml`. Nextcloud discovers it on
  the next request / `occ` scan; enable with `docker compose exec --user www-data nextcloud php occ app:enable <id>`.
- **Boundary (AD-9):** custom apps may depend on Nextcloud **only through OCP public APIs**
  (`OCP\…`) — never patch core, never rely on private internals; core never depends on a custom app.
- **v1 ships no custom app** (config-as-code only, AD-1) — this dir stays empty but mounted, ready for
  Layer-2 apps (e.g. the REM app on the roadmap).

Minimal app skeleton:

```
apps/my_app/
  appinfo/info.xml     # <id>my_app</id>, <version>, <dependencies><nextcloud min-version="34"/></dependencies>
  lib/                 # PHP (OCP APIs only)
```

**Linux ownership:** the container runs as `www-data` (uid 33). App *code* only needs to be readable, so a
normally-owned checkout works as-is. If discovery/enable fails on your host, run `sudo chown -R 33:33 apps`.
