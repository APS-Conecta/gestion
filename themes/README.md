# `themes/` — custom Nextcloud themes (live-mounted)

This directory is bind-mounted to **`/var/www/html/themes`** in the running Nextcloud (`compose.yaml`), so
custom server-side theme code can be edited live — no image rebuild, no fork.

- This mount **masks** the example theme template the official image ships at `/var/www/html/themes/example`
  (a reference scaffold, not an active theme — safe to mask). See the Nextcloud theming docs (via Context7)
  or copy that `example/` out of the image if you want it as a starting point.
- **White-labeling ships as a server theme** — `apsconecta/`, here. AD-6 said config-only, no theme files;
  it is **superseded by [ADR-0001](../docs/adr/0001-server-theme-for-branding.md)**. The reason is narrower
  than that ADR first claimed: brand fonts need `@font-face` paths a theme serves. (`occ` *can* set all four
  images — it just needs an absolute path — and it registers them from here.) Identity keys come from `occ`;
  this directory carries `server.css`, the fonts, the brand images and `MAPEO.md`.
- **There is no `defaults.php`** — deleted 2026-07-27. Its one job (killing the iOS banner) is
  `occ config:system:set customclient_ios_appid ""`, so the opcache restart it used to require is gone too.
- **`themes/` is undocumented legacy in Nextcloud** — it appears in no manual and its loader lives in
  `lib/private/legacy/`. It works, but re-verify after every major upgrade. Before editing `server.css`,
  read [`docs/THEMING-MODEL.md`](../docs/THEMING-MODEL.md): variables declared in `:root` here are **inert**,
  because Nextcloud scopes its own to `body[data-theme-light]` and loads them after this file.

**Linux ownership:** the container runs as `www-data` (uid 33). If a theme placed here isn't picked up, run
`sudo chown -R 33:33 themes`.
