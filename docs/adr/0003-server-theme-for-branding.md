<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0003 — A server theme is the branding path

Accepted, 2026-07-26.

## Context

`occ theming:config` sets the product's name, colours and brand images as config-as-code. The brand kit
(tokens, logo set, a mapped `server.css`, self-hosted variable fonts) needs more than that:

1. **Brand typography is unreachable from config.** Fraunces and Nunito Sans need `@font-face` with
   paths a theme serves. The Custom CSS app cannot self-host fonts, so the config-only path silently
   drops half the visual identity.
2. **Some screens never consult the Theming app.** On the legacy render path, identity and CSS can come
   only from the theme ([ADR-0004](0004-branding-the-legacy-render-path.md)).
3. **A server theme is not a fork.** Using `themes/` modifies nothing. It is undocumented legacy rather
   than a documented extension point (it appears in no manual and its loader lives in
   `lib/private/legacy/`), so it carries no deprecation guarantee.

## Decision

**`themes/apsconecta/` is the branding path.**

- `core/css/server.css`: brand tokens mapped onto Nextcloud's CSS variables.
- `core/fonts/*.woff2`: Fraunces and Nunito Sans, self-hosted, zero egress.
- `core/img/`: logo, favicon and login background live here as files, and `15-branding.sh` registers
  them with the Theming app via `theming:config <key> <absolute-path>`, pointing at the theme directory
  (`/var/www/html/themes/apsconecta/core/img/…`). Still config-as-code, with no upload, no API call and
  no admin credentials in the seed runner, so AD-2 is intact ([ADR-0002](0002-inherited-decisions.md)).
  Registration, rather than relying on theme-first lookup, is what makes favicon rasterisation, the
  webmanifest and branded emails work, and it is the only way to set `background`, since core ships no
  background image for a theme to override. `background` is the whole-UI background, not only the login
  screen (`CommonThemeTrait` feeds it into `--image-background`); its 8-hour legibility is under review.
- **No `defaults.php` for the iOS banner.** `customclient_ios_appid ""` kills the "Nextcloud — Abrir"
  banner. Identity stays with `occ`, except on the screens where Nextcloud never consults the Theming
  app ([ADR-0004](0004-branding-the-legacy-render-path.md)).
- Activation is `occ config:system:set theme --value apsconecta`, still config-as-code, applied by
  `provisioning/phases/15-branding.sh` so the seed remains the only thing that mutates instance state
  (AD-2). No standalone theming script: it would be a second state-changing entry point.
- **Fonts ship as woff2 only, with no TTF fallback.** Every browser Nextcloud 34 supports has had woff2
  since ~2016, so the fallback protected nobody, and it actively hid a bug: `server.css` declared four
  `.woff2` files that were never generated, and the TTF fallback swallowed the 404s. One format has no
  hiding place. Payload dropped from 1.85 MB to 856 KB. `scripts/test.sh` asserts every `url()` in
  `server.css` resolves to a file on disk, which is what replaces the fallback.

**Per-app icons (`apps/<appid>/img/`) are permitted but, as measured, empty.** An app's icon is
overridden only if it clashes. Stock Material icons are kept: our own icons deliberately speak Material
language so they disappear into the host, which makes overriding a stock Material glyph with our own a
per-upgrade maintenance cost for an imperceptible delta.

**Multi-tint is the whole clash criterion.** Absence of `currentColor` means nothing: 30+ stock apps ship
`img/app.svg` without it, because the Theming app recolours them server-side from that very file.
Scanning every enabled app found zero multi-tint icons, so `themes/apsconecta/apps/` does not exist and
does not need to.

## Consequences

- The theme must be re-verified on every Nextcloud major upgrade, carefully: `themes/` is undocumented
  legacy and carries no deprecation notice or migration guide. How to verify the theme that actually
  loaded: [tema.html](https://aps-conecta.github.io/documentation/desarrollo/tema.html).
- If `themes/` is ever withdrawn, the fallback is a small branding app shipping the CSS and fonts
  (`apps/text` and `apps/viewer` both self-host `.woff2` under `apps/<id>/css/fonts/`). That fallback does
  not reach the legacy-rendered screens: in maintenance mode `lib/base.php` dies before `loadApps()` and
  no app is loaded at all. For that class there is no second mechanism.
- `enforce_theme=light` disables Nextcloud's accessibility themes. `ThemesService::getThemes()` returns
  only `default`, `dark` and the enforced theme, so `HighContrastTheme`, `DarkHighContrastTheme` and
  `DyslexiaFont` are unreachable for every user. The `@media (prefers-contrast: more)` block in
  `server.css` mitigates it, and is therefore load-bearing accessibility rather than a nicety.
- The theme is AGPL-3.0-or-later like every repository. The logo, mono logo, lockup and favicon are
  protected by trademark; colour tokens ship under the AGPL ([ADR-0006](0006-agpl-across-the-org.md)).
- Gained: brand typography, radii, focus states and the header gradient, none reachable by config; the
  iOS banner leak fixed; images arrive with the theme, so a fresh bring-up is branded with no manual step.
- Branding is gated: `scripts/smoke.sh` fails when `/status.php` says `Nextcloud`, and `scripts/test.sh`
  parses every theme SVG.
- Rule for any future asset: runs on the server → this repository; feeds a designer or the website → the
  brand kit. Theming rules live in
  [tema.html](https://aps-conecta.github.io/documentation/desarrollo/tema.html).
