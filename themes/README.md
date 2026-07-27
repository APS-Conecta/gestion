# `themes/` — custom Nextcloud themes (live-mounted)

This directory is bind-mounted to **`/var/www/html/themes`** in the running Nextcloud (`compose.yaml`), so
custom server-side theme code can be edited live — no image rebuild, no fork.

- This mount **masks** the example theme template the official image ships at `/var/www/html/themes/example`
  (a reference scaffold, not an active theme — safe to mask). See the Nextcloud theming docs (via Context7)
  or copy that `example/` out of the image if you want it as a starting point.
- **White-labeling ships as a server theme** — `apsconecta/`, here. AD-6 said config-only, no theme files;
  it is **superseded by [ADR-0001](../docs/adr/0001-server-theme-for-branding.md)**, which explains why
  (NC34's `occ` can't set images, and brand fonts need `@font-face` paths a theme serves). Identity keys
  still come from `occ`; this directory carries `server.css`, the fonts, the brand images and `defaults.php`.
- **`defaults.php` is opcached** — a container restart is required after changing it, or it silently won't load.

**Linux ownership:** the container runs as `www-data` (uid 33). If a theme placed here isn't picked up, run
`sudo chown -R 33:33 themes`.
