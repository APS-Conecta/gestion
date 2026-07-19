# `themes/` — custom Nextcloud themes (live-mounted)

This directory is bind-mounted to **`/var/www/html/themes`** in the running Nextcloud (`compose.yaml`), so
custom server-side theme code can be edited live — no image rebuild, no fork.

- This mount **masks** the example theme template the official image ships at `/var/www/html/themes/example`
  (a reference scaffold, not an active theme — safe to mask). See the Nextcloud theming docs (via Context7)
  or copy that `example/` out of the image if you want it as a starting point.
- **v1 white-labeling is done as config, not theme files** (AD-6): APS Conecta branding/locale is applied by
  the `10-branding` provisioning phase (`occ theming:config` + es-CL), Epic 1 — **not** by dropping files
  here. This dir stays empty but mounted, available for a custom theme if one is ever needed.

**Linux ownership:** the container runs as `www-data` (uid 33). If a theme placed here isn't picked up, run
`sudo chown -R 33:33 themes`.
