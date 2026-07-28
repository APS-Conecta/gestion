# ADR-0001 — A server theme is the branding path (supersedes AD-6)

- **Status:** accepted, 2026-07-26
- **Supersedes:** AD-6 (as stated in `docs/ARCHITECTURE.md` § Branding & localization)
- **Affects:** `themes/apsconecta/`, `provisioning/`, `docs/ARCHITECTURE.md`, `themes/README.md`, `README.md`

## Context

AD-6 said white-labeling would be `occ theming:config` plus `disable-user-theming`,
config-as-code, with **no `themes/` file and no `defaults.php`** — the latter rejected as
"fork-adjacent" and because it needs an opcache reset. It also deferred everything until
"a brand guide lands".

The brand guide has now landed: a complete kit (tokens in 6 formats, logo set, a mapped
`server.css`, self-hosted variable fonts, a living brandbook). Applying it surfaced three
facts AD-6 did not have:

1. ~~**`occ` on NC34 cannot set images.**~~ **This was wrong — see Corrections below.** `occ`
   sets all four image keys; it simply requires an absolute path. The claim was inherited from
   `docs/ARCHITECTURE.md`. The decision below survives without it, on fact 2 alone.
2. **Brand typography is unreachable from config.** Fraunces and Nunito Sans need
   `@font-face` with paths a theme serves. The Custom CSS app cannot self-host fonts, so
   the config-only path silently drops half the visual identity.
3. ~~**A server theme is not a fork.** `themes/` is Nextcloud's documented extension point,~~
   **The "documented" half was wrong — see Corrections (2026-07-27).** `themes/` is an
   *undocumented legacy* mechanism; it is not a fork, and it works, but no manual describes it.
   `compose.yaml:56` already bind-mounts `./themes` for exactly this. `themes/README.md`
   itself said the directory was "ready for a custom theme" while citing AD-6, which forbade
   putting one there — the repo contradicted itself.

## Decision

**`themes/apsconecta/` is the branding path.** Concretely:

- `core/css/server.css` — brand tokens mapped onto Nextcloud's CSS variables.
- `core/fonts/*.ttf` — Fraunces + Nunito Sans, self-hosted, zero egress.
- `core/img/` — logo, favicon and login background live here as files, and `15-branding.sh`
  **registers them with the Theming app** via `theming:config <key> <absolute-path>`, pointing at
  the bind-mounted theme directory (`/var/www/html/themes/apsconecta/core/img/…`). Still
  config-as-code, still no upload, no API call and no admin credentials in the seed runner, so
  AD-2 is intact. Registration (rather than relying on theme-first lookup) is what makes favicon
  rasterisation, the webmanifest and branded emails work — and it is the *only* way to set
  `background`, since core ships no background image for a theme to override.
  Note `background` is the **whole-UI** background, not only the login screen
  (`CommonThemeTrait` feeds it into `--image-background`); its 8-hour legibility is under review.
- ~~`defaults.php` — accepted despite AD-6's objection. Its one irreplaceable job is
  `getiTunesAppId()` returning `''`, which kills the iOS "Nextcloud — Abrir" banner. No
  config key can do this.~~ **Withdrawn 2026-07-27 — the claim was false and the file is
  deleted.** `occ config:system:set customclient_ios_appid ""` does exactly the same thing;
  see Corrections. **AD-6 was right about this one.** Identity stays with `occ`.
- Activation is `occ config:system:set theme --value apsconecta` — still config-as-code, applied by
  `provisioning/phases/15-branding.sh` so `make seed` remains the only thing that mutates instance
  state (AD-2). The standalone `occ-theming.sh` from the brand kit is deleted; it was a second
  state-changing entry point.
- **Fonts ship as woff2 only, with no TTF fallback.** Every browser Nextcloud 34 supports has had
  woff2 since ~2016, so the fallback protected nobody — and it actively hid a bug: `server.css`
  declared four `.woff2` files that were never generated, and the TTF fallback swallowed the 404s.
  One format has no hiding place. Payload dropped 1.85 MB → 856 KB. `make test` now asserts every
  `url()` in `server.css` resolves to a file on disk, which is what replaces the fallback.

**Per-app icons (`apps/<appid>/img/`) are permitted but, as measured, empty.** An app's icon is
overridden **only if it clashes**. Stock Material icons are kept: our own icons deliberately speak
Material language so they disappear into the host, which makes overriding a stock Material glyph
with our own a per-upgrade maintenance cost for an imperceptible delta. *(That rule was previously
cited as a separate "ADR-iconos", which never existed as a document. It lives here now; the
dangling reference is retired.)*

**Clash criterion, corrected 2026-07-27.** It was defined as *"lacks `currentColor` **or** uses more
than one tint"*. The first half is wrong: 30+ stock apps ship `img/app.svg` without `currentColor`,
because the Theming app recolours them server-side from that very file — absence of `currentColor`
means nothing. **Multi-tint is the whole criterion.** Scanning every enabled app on the live
instance found **zero** multi-tint icons, so the expected steady state of "0–3 files" is, measured,
**0**. `themes/apsconecta/apps/` does not exist and does not need to.

## Consequences

**Accepted costs**

- ~~A container restart is required after **editing** `defaults.php` (opcache).~~ **Gone as of
  2026-07-27** — `defaults.php` was deleted, so the whole opcache concern with it. This was the
  headline cost of the decision and it no longer exists.
- The theme must be re-verified on every Nextcloud major upgrade — and **more carefully than first
  written**, because `themes/` is undocumented legacy (Corrections, 2026-07-27) and so carries no
  deprecation notice or migration guide. The kit's variable map was authored against NC33; the
  stack runs 34.0.1, and that map did not survive the jump.
- **`enforce_theme=light` disables Nextcloud's accessibility themes.** `ThemesService::getThemes()`
  returns only `default`, `dark` and the enforced theme, so `HighContrastTheme`,
  `DarkHighContrastTheme` and `DyslexiaFont` are unreachable for every user. Mitigated by the
  `@media (prefers-contrast: more)` block in `server.css`, which is therefore load-bearing
  accessibility rather than a nicety. Discovered 2026-07-27; the light-only decision itself
  (2026-07-12) is unchanged.
- `themes/` is proprietary under `docs/LICENSING.md` §1. The kit's AGPL-3.0 claim for the
  theme is retracted; it was a free choice, not an obligation (soft layers never trigger
  AGPL §13). Tokens and logos stay MIT in the brand kit, where the public apsconecta.cl site
  consumes them.

**Gained**

- Brand typography, radii, focus states and the header gradient — none reachable by config.
- The iOS banner leak fixed.
- Images arrive with the theme, so a fresh bring-up is branded with no manual step.

**Layout** — one copy, in the location the bind mount already serves:

```
gestion/themes/apsconecta/       ← the only copy; what runs
  MAPEO.md                       ← what server.css owns, beside the file it describes
  core/css/server.css
  core/fonts/*.woff2             ← the ONLY reason this directory exists
  core/img/{favicon,background}.svg
  core/img/logo/{logo,logo-header,logo-mono}.svg
                                 ← logo = login card (full lockup)
                                   logo-header = header, 62x44 slot (mark only)
  (no defaults.php — deleted 2026-07-27)
  (no apps/<appid>/img/ — measured zero clashing icons)

APS Conecta Nextcloud/           ← brand source, MIT, ships to nobody
  tokens/  logo/  css/  sistema-diseno.html  brandbook-agnostico.html
  README.md  README-MARCA.md
```

Deploy guide and theming rules now live in the repo, not the kit:
[`docs/BRANDING.md`](../BRANDING.md) and [`docs/THEMING-MODEL.md`](../THEMING-MODEL.md).

Rule for any future asset: **runs on the server → `gestion/`; feeds a designer or the
website → the kit.**

## Verifying the map against the live instance

The brandbook's "Deriva" panel compares `server.css` against the declared map — it links
both files locally and reads its own document, so it is a **file-level** check and cannot
see a running Nextcloud. To check the theme that actually loaded, paste this into devtools
**on a real Nextcloud page**:

```js
const expected = {
  '--color-primary-element':'#7f21fe',
  '--color-primary-element-hover':'#6c1bd9',
  '--color-primary-element-light-text':'#5315a8',
  '--color-main-text':'#101828',
  '--color-main-background':'#ffffff',
  '--color-error':'#ea003e',
  '--color-success':'#009764',
  '--color-border':'#e2e5e9',
  '--border-radius':'6px',
  '--border-radius-large':'8px',
};
// NOTE: read document.body, NOT documentElement. Nextcloud scopes its themes to
// body[data-theme-light] / [data-theme-dark]; <html> only ever sees the :root layer, which
// under a dark OS resolves to dark values and produces a false alarm. Verified 2026-07-27.
const cs = getComputedStyle(document.body);
const drift = Object.entries(expected).filter(([k, v]) => {
  const real = cs.getPropertyValue(k).trim();
  if (real.toLowerCase() !== v.toLowerCase()) { console.warn(k, 'esperado', v, '→ real', real || 'AUSENTE'); return true; }
  return false;
});
console.log(drift.length ? `✗ deriva en ${drift.length}/${Object.keys(expected).length}` : '✓ sin deriva');
```

## Corrections (2026-07-26)

Recorded rather than quietly edited, because the original reasoning was published with a false
premise and the audit trail matters more than looking right.

**Believed:** NC34's `occ` sets text and colour only; brand images must be uploaded through the
admin UI, which AD-2 forbids. This drove the plan to ship images as theme files and rely on
theme-first lookup.

**Found:** `apps/theming/lib/Command/UpdateConfig.php:103-113` handles every key in
`ImageManager::SUPPORTED_IMAGE_KEYS` = `['background','logo','logoheader','favicon']`. The only
constraints are `str_starts_with($value, '/')` and `file_exists($value)`. The brand kit's original
`occ-theming.sh` failed because it passed `./logo-header-oficial.svg` — a *relative* path. A
path-format bug, not a missing capability. Two further findings fell out:

- **`core/img/background.svg` resolved to nothing.** Core ships no background image; backgrounds
  live in `apps/theming/img/background/`. Theme-first lookup could never have served the login
  background. Registration is the only route.
- **SVG is accepted for all four keys.** `getSupportedUploadImageFormats()` restricts SVG only for
  `favicon`, and only when imagick lacks the SVG delegate — which `nextcloud:34-apache` has
  (`queryFormats('SVG')` → `['SVG']`).

**Verified by** reading the shipped source in the pinned image, not by running the stack:
`docker run --rm nextcloud:34-apache`.

**Effect on the decision:** none. Fact 2 (brand typography needs `@font-face` paths only a theme
serves) is sufficient on its own to require `themes/`, and fact 3 stands. What changed is *how*
images arrive: `15-branding.sh` now registers them through the Theming app instead of leaning on
theme-first lookup. `docs/ARCHITECTURE.md` carried the same false sentence and is corrected.

## Corrections (2026-07-27)

A second round, recorded the same way as the first: the original reasoning carried two more false
premises, and the audit trail matters more than looking right. Both were settled by reading the
pinned image and the Nextcloud 34 manuals.

**Believed:** `defaults.php`'s `getiTunesAppId()` returning `''` was irreplaceable, because "no
config key can do this". It was the sole justification for shipping an `OC_Theme` class and for
accepting an opcache container restart.

**Found:** `lib/private/legacy/OC_Defaults.php:44` reads
`$config->getSystemValue('customclient_ios_appid', '1125420102')`, and
`core/templates/layout.{user,public,guest}.php` emit the `apple-itunes-app` meta tag only when the
id is not `''`. So `occ config:system:set customclient_ios_appid ""` produces exactly the same
result with no file. The admin manual additionally documents
`occ config:app:set theming iTunesAppId`. `OC_Defaults.php:54` also guards the theme file with
`if (file_exists($themePath))`, so the theme works fine without it. **`defaults.php` is deleted.**
Verified end to end: `curl -s localhost:8180/login | grep -c apple-itunes-app` → `0`.

**Believed:** `themes/` is "Nextcloud's documented extension point" (fact 3 above).

**Found:** it appears in **neither** manual — not the admin *Theming* chapter (which covers only the
Theming app and `occ theming:config`), nor the developer *Theming support* page (CSS variables,
`OCA.Theming`, icons). Checked against the online stable NC34 docs and the local clone. Its loader
lives in `lib/private/legacy/`. It is undocumented legacy: functional, bind-mounted, and carrying no
deprecation guarantee.

**Effect on the decision: none, but the ground under it is narrower.** Fact 2 — brand typography
needs `@font-face` with paths a theme serves — is now the **only** load-bearing justification, since
`occ` registers images from any absolute path and identity is pure config. If `themes/` is ever
withdrawn, the fallback is a small branding **app** shipping the CSS and fonts, which is the
documented path: `apps/text` and `apps/viewer` both self-host `.woff2` under `apps/<id>/css/fonts/`.

**A third correction, on our own work rather than on Nextcloud:** the token→variable map this ADR
was built to deliver **never reached the page**. Nextcloud scopes theme variables to
`body[data-theme-light]` while a server theme's `server.css` loads first, so every `:root`
declaration was inert — 7 of 30 variables matched, and only because they already equalled
Nextcloud's own value. `server.css` was cut down to what element selectors and `--font-face`
actually deliver. Details in [`../../themes/apsconecta/MAPEO.md`](../../themes/apsconecta/MAPEO.md)
and [`../THEMING-MODEL.md`](../THEMING-MODEL.md).

## Pending — closed 2026-07-27

All three are resolved. Kept here rather than deleted, because how they resolved is the record.

1. **Do theme images actually win?** — **Moot.** The question assumed theme-first lookup. We do not
   rely on it: `15-branding.sh` registers all four images through the Theming app with
   `occ theming:config <key> <absolute-path>`, so the Theming app's own values *are* ours. Verified
   live: all four registered, favicon rasterised, webmanifest themed. No OCS fallback needed, so no
   admin credentials entered the seed runner and AD-2 stands.
2. **Which icons clash?** — **None.** Scanned every enabled app on the live instance: zero
   multi-tint `img/app.svg`. The `currentColor` half of the criterion was itself wrong; see the
   corrected criterion above.
3. **A branding gate.** — **Shipped.** `scripts/smoke.sh` check 5 now greps the `/status.php` body
   it already fetched for `Nextcloud` and fails on a hit. Verified in both directions: passes as
   configured, fails when `theming productName` is deleted. A second gate joined it in
   `scripts/test.sh`: every SVG in the theme must *parse*, after a malformed one (a double hyphen
   inside an XML comment) was served with a 200 and rendered nothing while every existing check
   stayed green.

## Superseded pending (historical)

*The original wording, kept verbatim so the closures above can be read against what was actually
asked. One path has since moved: `INSTALACION-NEXTCLOUD.md` is now [`../BRANDING.md`](../BRANDING.md).*

1. **Do theme images actually win?** `core/img/` must beat the Theming app's DB values, and
   the login background and favicon-generation pipelines must honour them. If they lose, the
   fallback is the OCS API (`/apps/theming/ajax/uploadImage`, documented in the kit) driven
   from a provisioning phase — which reintroduces admin credentials in the seed runner.
   Related: `INSTALACION-NEXTCLOUD.md` §7 notes Nextcloud's default background is a *wallpaper*,
   not a colour, and `background_color` does not remove it. We rely on our own background image
   winning; if it doesn't, set `config:app:set theming backgroundMime backgroundColor`.
2. **Which icons clash** — needs `occ app:list`, then grep each app's `img/` for `currentColor`.
3. **A branding gate.** `scripts/smoke.sh` check 5 already curls `/status.php`, which is exactly
   where "Nextcloud" leaks when `productName` is unset — the most-cited trap in the plan. It
   throws the body away. Grepping it is ~2 lines and would catch the highest-value branding
   regression, but it needs a running stack to write honestly.
