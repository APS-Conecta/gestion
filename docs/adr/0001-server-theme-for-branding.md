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
3. **A server theme is not a fork.** `themes/` is Nextcloud's documented extension point,
   and `compose.yaml:56` already bind-mounts `./themes` for exactly this. `themes/README.md`
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
- `defaults.php` — accepted despite AD-6's objection. Its one irreplaceable job is
  `getiTunesAppId()` returning `''`, which kills the iOS "Nextcloud — Abrir" banner. No
  config key can do this. Everything else in it is fallback; `occ` remains the source of
  truth for identity.
- Activation is `occ config:system:set theme --value apsconecta` — still config-as-code, applied by
  `provisioning/phases/15-branding.sh` so `make seed` remains the only thing that mutates instance
  state (AD-2). The standalone `occ-theming.sh` from the brand kit is deleted; it was a second
  state-changing entry point.
- **Fonts ship as woff2 only, with no TTF fallback.** Every browser Nextcloud 34 supports has had
  woff2 since ~2016, so the fallback protected nobody — and it actively hid a bug: `server.css`
  declared four `.woff2` files that were never generated, and the TTF fallback swallowed the 404s.
  One format has no hiding place. Payload dropped 1.85 MB → 856 KB. `make test` now asserts every
  `url()` in `server.css` resolves to a file on disk, which is what replaces the fallback.

**Per-app icons (`apps/<appid>/img/`) are permitted but deliberately near-empty.** An app's
icon is overridden **only if it clashes**, defined objectively as: *its shipped SVG lacks
`currentColor` or uses more than one tint*. Stock Material icons are kept — per ADR-iconos
our icons use Material language precisely so they disappear into the host, which makes
overriding a stock Material glyph with our own a per-upgrade maintenance cost for an
imperceptible delta. Expected steady state: 0–3 files.

## Consequences

**Accepted costs**

- A container restart is required after **editing** `defaults.php` (opcache). This is narrower than
  it first appears: `defaults.php` is bind-mounted and present before PHP boots, so a fresh
  `make up` compiles it on first use with no restart. The restart is a dev-loop concern —
  `docker compose restart nextcloud`. (Note `provisioning/lib.sh:8` runs `occ` via
  `docker compose exec` from the *host*, so a phase could restart the container if that ever
  becomes necessary; it isn't today.)
- The theme must be re-verified on every Nextcloud major upgrade. The kit's variable map was
  authored against NC33; the stack runs 34.0.1.
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
  defaults.php
  core/css/server.css
  core/fonts/*.ttf
  core/img/{favicon,background}.svg  core/img/logo/{logo,logo-mono}.svg
  apps/<appid>/img/*.svg         ← only for clashing icons

APS Conecta Nextcloud/           ← brand source, MIT, ships to nobody
  tokens/  logo/  sistema-diseno.html  *.md  PLAN-IMPLEMENTACION.html
```

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

## Pending — must be closed before this ADR is proven

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
