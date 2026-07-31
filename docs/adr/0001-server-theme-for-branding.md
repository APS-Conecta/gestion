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

1. **Brand typography is unreachable from config.** Fraunces and Nunito Sans need `@font-face`
   with paths a theme serves. The Custom CSS app cannot self-host fonts, so the config-only path
   silently drops half the visual identity. **This is the one load-bearing fact** — see Corrections.
2. **A server theme is not a fork.** `themes/` is bind-mounted by `compose.yaml` for exactly this,
   and using it modifies nothing. It is *undocumented legacy* rather than a documented extension
   point (Correction 3), so it carries no deprecation guarantee — but it is not a fork.
3. Two further facts were claimed here and are now withdrawn: that `occ` cannot set brand images,
   and that `themes/` is documented. Both were wrong; see **Corrections**. The decision stands on
   fact 1 alone.

## Decision

**`themes/apsconecta/` is the branding path.** Concretely:

- `core/css/server.css` — brand tokens mapped onto Nextcloud's CSS variables.
- `core/fonts/*.woff2` — Fraunces + Nunito Sans, self-hosted, zero egress.
- `core/img/` — logo, favicon and login background live here as files, and `15-branding.sh`
  **registers them with the Theming app** via `theming:config <key> <absolute-path>`, pointing at
  the bind-mounted theme directory (`/var/www/html/themes/apsconecta/core/img/…`). Still
  config-as-code, still no upload, no API call and no admin credentials in the seed runner, so
  AD-2 is intact. Registration (rather than relying on theme-first lookup) is what makes favicon
  rasterisation, the webmanifest and branded emails work — and it is the *only* way to set
  `background`, since core ships no background image for a theme to override.
  Note `background` is the **whole-UI** background, not only the login screen
  (`CommonThemeTrait` feeds it into `--image-background`); its 8-hour legibility is under review.
- **No `defaults.php`.** An earlier draft accepted one, over AD-6's objection, to kill the iOS
  "Nextcloud — Abrir" banner. That claim was false: `customclient_ios_appid ""` does the same job,
  so the file was deleted 2026-07-27 and **AD-6 was right about this one**. Identity stays with
  `occ`.
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

- **No container restart.** This was the headline cost of the decision, required only by
  `defaults.php`'s opcache; deleting that file removed it entirely.
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
  core/img/manifest.json         ← the webmanifest smoke check 7 asserts
  core/img/logo/{logo,logo-header,logo-mark}.svg
                                 ← logo = login card, logo-header = header (both full lockups),
                                   logo-mark = the narrow header below the breakpoint.
                                   Header geometry: MAPEO.md §3 owns the numbers.
  tools/embed-fonts.py           ← subsets the brand fonts INTO the two lockups (B-011)
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

## Verifying

The token→variable map this section used to check **was withdrawn** (Correction 3), so the snippet
that compared against it went with it. How to verify the theme that actually loaded is
[`../THEMING-MODEL.md`](../THEMING-MODEL.md) §5 — one owner per fact.

## Corrections

Recorded rather than quietly edited: the original reasoning was published with false premises, and
the audit trail matters more than looking right. Three rounds, consolidated here 2026-07-30.

**1 — `occ` does set brand images (2026-07-26).** Believed: NC34's `occ` sets text and colour only,
so images must go through the admin UI, which AD-2 forbids. Found: `UpdateConfig.php:103-113` handles
every key in `ImageManager::SUPPORTED_IMAGE_KEYS` (`background`, `logo`, `logoheader`, `favicon`);
the only constraints are an absolute path that exists. `15-branding.sh` registers all four that way,
so no admin credentials enter the seed runner.

**2 — `defaults.php` was replaceable (2026-07-27).** Believed: its `getiTunesAppId()` returning `''`
was the only way to kill the iOS smart-app banner. Found: `customclient_ios_appid ""` is a system key
that does the same job, so the file — and the opcache container restart it required — was deleted.
AD-6 was right about `defaults.php` after all.

**3 — our own token map never reached the page (2026-07-27).** Nextcloud scopes theme variables to
`body[data-theme-light]` while a server theme's `server.css` loads first, so every `:root`
declaration was inert: 7 of 30 matched, and only because they already equalled Nextcloud's own value.
`server.css` was cut to what element selectors and `--font-face` actually deliver.

**What this leaves.** `themes/` is undocumented legacy — it appears in no manual and its loader lives
in `lib/private/legacy/` — so re-verify after every major upgrade. **Fact 2, that brand typography
needs `@font-face` with paths a theme serves, is now the only load-bearing justification for this
decision**, since images register from any absolute path and identity is pure config. If `themes/`
is ever withdrawn, the fallback is a small branding **app** shipping the CSS and fonts, which is the
documented path: `apps/text` and `apps/viewer` both self-host `.woff2` under `apps/<id>/css/fonts/`.

## Pending — all closed 2026-07-27

1. **Do theme images win?** Moot — we do not rely on theme-first lookup; the Theming app's own
   values *are* ours.
2. **Which icons clash?** None. Zero multi-tint `img/app.svg` across every enabled app.
3. **A branding gate?** Shipped — `scripts/smoke.sh` greps `/status.php` for `Nextcloud`, and
   `scripts/test.sh` parses every theme SVG. Both verified in each direction.
