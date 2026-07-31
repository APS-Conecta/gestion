# `themes/` — custom Nextcloud themes (live-mounted)

Bind-mounted to **`/var/www/html/themes`** by `compose.yaml`, so theme code is edited live — no image
rebuild, no fork. The mount masks the `example/` scaffold the official image ships there; that is
safe, it was never an active theme.

White-labeling ships as the `apsconecta/` server theme here, superseding AD-6 —
[ADR-0001](../docs/adr/0001-server-theme-for-branding.md) has the decision and what it rests on.

**Before editing `server.css`, read [`docs/THEMING-MODEL.md`](../docs/THEMING-MODEL.md).** It is the
one place the theming mechanism is written down, and the first rule — variables declared in `:root`
are inert — is the one that costs an afternoon if you meet it by surprise. The brand palette and
type decisions are in [`apsconecta/MAPEO.md`](apsconecta/MAPEO.md).

**Linux ownership:** the container runs as `www-data` (uid 33). `make up` fixes this for you via
`fix-mount-perms`; if a theme placed here still isn't picked up, `sudo chown -R 33:33 themes`.
