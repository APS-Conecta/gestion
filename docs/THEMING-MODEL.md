# Theming model — how APS Conecta Gestión is branded

How Nextcloud theming actually works on this instance, the rules that hold, and where every knob
lives. Written from measurements taken on the live NC 34.0.1 instance on 2026-07-27, because the
official manual documents none of it.

Companion documents: [`docs/BRANDING.md`](BRANDING.md) is the step-by-step deploy guide;
[`themes/apsconecta/MAPEO.md`](../themes/apsconecta/MAPEO.md) records what `server.css` owns and
why; [`docs/adr/0001-server-theme-for-branding.md`](adr/0001-server-theme-for-branding.md) is the
decision record.

> **Golden rule, unchanged since the original plan:** never edit Nextcloud core or a third-party
> app. Everything is applied on top — the Theming app, `occ`, `themes/apsconecta/` and our own
> assets. A change inside `core/` or someone else's app would trigger AGPL §13 and would be lost
> at the next upgrade.

---

## 1. The four layers

| Layer | What it owns | Where it lives | Who writes it |
|---|---|---|---|
| **A — Identity** | Name, slogan, URLs, colours, `productName`, brand images | Theming app config | `provisioning/phases/15-branding.sh` |
| **B — CSS & fonts** | `@font-face`, display typography, header, focus, high contrast | `themes/apsconecta/core/css/server.css` | the file itself |
| **C — Per-app icons** | Overrides for icons that clash | `themes/apsconecta/apps/<appid>/img/` | *currently empty — see §4* |
| **D — Brand source** | Tokens, logo artwork, the living brandbook | `../APS Conecta Nextcloud/` (MIT, separate) | designers |

**Layer B is the only reason the theme directory exists.** Images are registered with
`occ theming:config` from absolute paths and would work from anywhere on disk; identity and colour
are pure config. Only `@font-face` needs a path Nextcloud serves.

**Split rule for any new asset:** *runs on the server → `gestion/`; feeds a designer or the website
→ the brand kit.*

## 2. Settings structure — every knob

`15-branding.sh` is the **only** writer. Nothing is set by hand in the admin panel (AD-2).

| Knob | Command | Value here | What it actually controls |
|---|---|---|---|
| `name`, `slogan`, `url`, `imprintUrl`, `privacyUrl` | `occ theming:config` | APS Conecta Gestión … | Header title, login, emails, footer |
| `productName` | `occ config:app:set theming` | APS Conecta Gestión | `/status.php`, `OC.theme`, OCS capabilities, public-share button. **Unset = "Nextcloud" leaks** |
| `primary_color` | `occ theming:config` | `#7f21fe` | Buttons, checkboxes, folder icons, and the whole `--color-primary-*` family |
| `background_color` | `occ theming:config` | `#5315a8` | **Not decorative.** Text colour over the background and the header icon inversion — see §3 rule 5 |
| `logo` | `occ theming:config` | `core/img/logo/logo.svg` | Login card. Full lockup |
| `logoheader` | `occ theming:config` | `core/img/logo/logo-header.svg` | Header, 62×44 px slot. Mark only |
| `favicon` | `occ theming:config` | `core/img/favicon.svg` | Favicon, touch icons, webmanifest |
| `background` | `occ theming:config` | `core/img/background.svg` | The **whole-UI** backdrop, not just login |
| `disable-user-theming` | `occ theming:config` | `yes` (stored `1`) | Stops per-user background/colour overrides |
| `enforce_theme` | `occ config:system:set` | `light` | Locks appearance. **Also removes high-contrast and dyslexia themes — see §3 rule 4** |
| `customclient_ios_appid` | `occ config:system:set` | `""` | Kills the iOS "Nextcloud — Abrir" smart-app banner |
| `theme` | `occ config:system:set` | `apsconecta` | Activates the server theme |

## 3. The rules

Each one cost something to learn. None of them appears in the Nextcloud manual.

### Rule 1 — `:root` is inert. Scope to `body`.

Nextcloud declares its theme variables on **`body[data-theme-light]`**, and a server theme's
`server.css` loads *before* the theming app's stylesheet. So any variable you declare in `:root`
loses for everything inside `<body>`.

Measured 2026-07-27: of 30 variables the theme declared, **7 landed** — and those only because they
already equalled Nextcloud's own value. `--color-main-text` stayed `#222222`, `--border-radius`
`4px`, `--color-border` `#ededed`.

To win, you need `!important` on the custom property — it beats `body[data-theme-light]` regardless
of specificity or load order. Use it sparingly; today only `--font-face` and the high-contrast
block do.

*Note the asymmetry:* our **element selectors** (`h1`, `#header`, `:focus-visible`) do win, because
they beat core's rules. Variables lose; selectors win.

### Rule 2 — Measure on `document.body`, never `document.documentElement`.

`<html>` only ever sees the `:root` layer, which under a dark-mode OS resolves to dark values and
produces a **false alarm** that dark mode is not disabled. The UI is fine; the measurement is wrong.

```js
getComputedStyle(document.body).getPropertyValue('--color-main-text')
```

### Rule 3 — `--color-error` / `--color-success` are backgrounds, not text.

The official CSS-variables reference: *"Color to show error state, this should not be used for text
but for element backgrounds."* NC34 changed these from foreground colours to light background
tints (`--color-error` is `#FFE7E7` here).

Putting a brand foreground colour in them is **wrong, not merely overridden**. For foreground use
`--color-text-error` / `--color-text-success`; for elements `--color-element-error` and friends.

### Rule 4 — `enforce_theme=light` costs more than dark mode.

`ThemesService::getThemes()` returns **exactly three** providers when `enforce_theme` is set:
`default`, `dark`, and the enforced one. Everything else in `apps/theming/lib/Themes/` disappears —
including **`HighContrastTheme`, `DarkHighContrastTheme` and `DyslexiaFont`**.

So Nextcloud's built-in high-contrast mode and the OpenDyslexic option are unreachable for every
user here. `server.css`'s `@media (prefers-contrast: more)` block is the instance's **only**
high-contrast affordance. Treat it as load-bearing accessibility, not decoration.

### Rule 5 — `background_color` must match the background image.

`CommonThemeTrait.php:82` derives the text colour over the backdrop from `background_color`, **not**
from the background image:

```php
'--color-background-plain-text' => $this->util->invertTextColor($backgroundColor) ? '#000000' : '#ffffff',
// invertTextColor() → colorContrast($color, '#ffffff') < 4.5
```

Line 83 derives `--background-image-invert-if-bright` from it too, which flips header icons. The
admin manual adds that it also drives the header bar icon colour.

Setting it to white while shipping a violet background image produced **black text and inverted
(black) icons over violet** — the visible bug fixed on 2026-07-27.

Corollary: **do not paint over the backdrop.** `server.css` used to set a light gradient on
`body, #content, #content-vue`, which hid `background.svg` completely — it was registered, served,
and never once seen.

### Rule 6 — `themes/` is undocumented legacy. Re-verify every major upgrade.

The `themes/` mechanism appears in **neither** the admin manual nor the developer manual, online or
in the local clone. Its loader lives in `lib/private/legacy/OC_Defaults.php`. It works, and
`compose.yaml:56` bind-mounts it — but being undocumented, it carries no deprecation notice.

If it ever breaks, the fallback is a small branding **app** shipping the CSS and fonts, which is the
documented path — `apps/text` and `apps/viewer` both self-host `.woff2` under `apps/<id>/css/fonts/`.

### Rule 7 — an SVG that does not parse is served with a 200 and renders nothing.

Brand SVGs are parsed as XML when loaded as images. A double hyphen inside an XML comment is a
parse error, so the file silently renders as nothing while every existence check stays green.
`make test` now parses every SVG in the theme.

## 4. What this theme does *not* do

- **No per-app icon overrides.** ADR-0001 allowed them for icons that "clash". Scanned every enabled
  app on 2026-07-27: **zero** multi-tint icons, so nothing qualifies. Note the other half of that
  criterion — *lacks `currentColor`* — is wrong: 30+ stock icons lack it and Nextcloud recolours them
  itself from `img/app.svg`. Multi-tint is the criterion that means anything.
- **No dark mode.** Owner decision, 2026-07-12. Dark tokens exist only in the brand kit, for the
  website.
- **No component restyling, no SCSS, no core edits, no `@nextcloud/vue` fork.**
- **The `eurooffice` app still shows "Nextcloud Office"** in the admin sidebar. That is the vendored
  app's own display name; fixing it means custom l10n inside a vendored app, which is
  upgrade-fragile. Admin-only, accepted.

## 5. How to verify

After any theming change, on a real Nextcloud page:

```js
const cs = getComputedStyle(document.body);          // body, NOT documentElement
const check = {
  fontFace:  cs.getPropertyValue('--font-face').trim(),        // expect "Nunito Sans", …
  bodyFont:  cs.fontFamily,                                    // expect "Nunito Sans", …
  plainText: cs.getPropertyValue('--color-background-plain-text').trim(), // #ffffff on violet
  invert:    cs.getPropertyValue('--background-image-invert-if-bright').trim(), // expect "no"
  primary:   cs.getPropertyValue('--color-primary-element').trim(),      // #7f21fe
};
console.table(check);
```

And from the shell:

```sh
make test                              # SVGs parse, every url() in server.css resolves
make smoke                             # /status.php 200 and free of "Nextcloud"
curl -s localhost:8180/login | grep -c apple-itunes-app   # expect 0
```

`make seed` twice in a row must change nothing except the four image registrations, which rewrite
by design (there is no stored path to compare against, so skipping would mean edits never reach the
instance).
