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

1. **`occ` on NC34 cannot set images.** It sets text and colour keys only; logo, favicon
   and login background are admin-UI uploads. That collides with **AD-2** ("the only thing
   that changes instance state is `make seed` — never hand-click"). Layer A alone therefore
   *cannot* deliver a branded instance reproducibly.
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
- `core/img/` — logo, favicon and login background ship **as theme files**, relying on
  Nextcloud's theme-first image lookup. No upload, no API call, no admin credentials in the
  seed runner. This is what keeps AD-2 intact.
- `defaults.php` — accepted despite AD-6's objection. Its one irreplaceable job is
  `getiTunesAppId()` returning `''`, which kills the iOS "Nextcloud — Abrir" banner. No
  config key can do this. Everything else in it is fallback; `occ` remains the source of
  truth for identity.
- Activation is `occ config:system:set theme --value apsconecta` — still config-as-code.

**Per-app icons (`apps/<appid>/img/`) are permitted but deliberately near-empty.** An app's
icon is overridden **only if it clashes**, defined objectively as: *its shipped SVG lacks
`currentColor` or uses more than one tint*. Stock Material icons are kept — per ADR-iconos
our icons use Material language precisely so they disappear into the host, which makes
overriding a stock Material glyph with our own a per-upgrade maintenance cost for an
imperceptible delta. Expected steady state: 0–3 files.

## Consequences

**Accepted costs**

- A container restart is required after any `defaults.php` change (opcache). `make seed`
  cannot restart its own container, so the restart's home in the provisioning flow is
  **still open** — see Pending below.
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
const cs = getComputedStyle(document.documentElement);
const drift = Object.entries(expected).filter(([k, v]) => {
  const real = cs.getPropertyValue(k).trim();
  if (real.toLowerCase() !== v.toLowerCase()) { console.warn(k, 'esperado', v, '→ real', real || 'AUSENTE'); return true; }
  return false;
});
console.log(drift.length ? `✗ deriva en ${drift.length}/${Object.keys(expected).length}` : '✓ sin deriva');
```

## Pending — must be closed before this ADR is proven

1. **Do theme images actually win?** `core/img/` must beat the Theming app's DB values, and
   the login background and favicon-generation pipelines must honour them. If they lose, the
   fallback is the OCS API (`/apps/theming/ajax/uploadImage`, documented in the kit) driven
   from a provisioning phase — which reintroduces admin credentials in the seed runner.
2. **Where the container restart lives** — a `make` target, a documented post-seed step, or
   a provisioning phase that shells out.
3. **Which icons clash** — needs `occ app:list`, then grep each app's `img/` for
   `currentColor`.
