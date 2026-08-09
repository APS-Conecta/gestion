# BRANDING.md — installing the brand on Nextcloud

Step-by-step guide to dressing the instance in the **APS Conecta Gestión** identity
(**light theme only**) on **Nextcloud 34**.

> How Nextcloud theming behaves internally, and the rules that cannot be broken, are in
> [`THEMING-MODEL.md`](THEMING-MODEL.md). This guide is the *what to do*; that one is the *why*.
> This file was called `INSTALACION-NEXTCLOUD.md` and lived in the brand kit; it moved into the repo
> on 2026-07-27 because it describes what runs on the server, and was translated to English on
> 2026-08-09 for the same reason — its reader deploys the brand, they do not design it.

---

## 0. What this folder holds

What **runs** is in this repo:

```
gestion/
├── docs/BRANDING.md              ← this guide
├── docs/THEMING-MODEL.md         ← rules, settings structure, verification
├── provisioning/phases/15-branding.sh   ← the ONLY place that writes the brand
└── themes/apsconecta/            ← a single copy; compose.yaml mounts it
    ├── MAPEO.md
    ├── defaults.php               ← identity on the legacy render path (ADR-0004)
    ├── tools/                     ← art generator, single-use; not a package
    └── core/{css,fonts,img}/      ← the img/ listing is in §3
```

What **feeds design** is in the sibling kit `../APS Conecta Nextcloud/` (outside git; its MIT licence
was withdrawn on 2026-08-08 — see [`LICENSING.md`](LICENSING.md), which owns this):
`tokens/`, `logo/`, `css/apsconecta.css`, `sistema-diseno.html` (living brandbook),
`brandbook-agnostico.html`, `README-MARCA.md`.

> **Rule:** *runs on the server → `gestion/`; feeds a designer or the website → the kit.*

## 1. Requirements

- Nextcloud **34** with the **Theming** app enabled (on by default).
- Access to **`occ`** as the web user:
  - Normal install: `sudo -u www-data php occ …`
  - Docker: `docker exec -u www-data <container> php occ …`
- For Nextcloud to **generate favicons and home-screen icons** from the logo you need **PHP imagick with SVG support** (e.g. `libmagickcore-*-extra`). Without it, upload the favicon yourself in Theming's advanced options.

> **Golden rule:** never edit Nextcloud core. Prefer soft layers: the Theming panel, `occ` commands,
> our own server theme (`themes/apsconecta/`) and our own CSS/l10n.
>
> *Qualified by [ADR-0002](adr/0002-app-patches.md) on 2026-07-29:* third-party apps **are** patched,
> at runtime and from versioned `.patch` files, when there is no other way. What that means for
> AGPL §13 is settled by [`LICENSING.md`](LICENSING.md) §4, which owns it.

---

## 2. The reproducible path — `make seed` (the only one)

There is no loose script to run. The identity layer is a **provisioning phase**,
`gestion/provisioning/phases/15-branding.sh`, applied with the rest:

```bash
cd gestion
make up      # brings up the stack (bind-mounts ./themes)
make seed    # applies locale, brand, groups, folders, ACL…
```

It is idempotent: every key is read before it is written, so re-running does nothing.
The phase does, in order:
1. **Identity:** `name`, `slogan`, `url`, `imprintUrl`, `privacyUrl`.
2. **`productName`** (a separate key — **essential**): without it, "Nextcloud" leaks through `status.php`, `OC.theme`, the OCS capabilities and the public-share button.
3. **Colours:** `primary_color #7f21fe`, `background_color #5315a8`.
   `background_color` is **not decorative**: Nextcloud derives the text colour over the backdrop and
   the header icon inversion from it. It has to match the dominant tone of `background.svg`. Setting
   it to white painted black text and inverted icons over violet (fixed 2026-07-27). See rule 5 of
   `THEMING-MODEL.md`.
4. **Forced light theme:** `enforce_theme = light` + `disable-user-theming = yes`. The keys are **complementary**: the first removes the theme/appearance choice, the second stops each user changing background and colour on their own.
5. **iOS banner:** `config:system:set customclient_ios_appid ""` — kills the `apple-itunes-app`
   meta tag. It replaces `defaults.php` **for this task**, which is why that file was deleted on
   2026-07-27. The file came back on 2026-08-04 for a different reason — identity on the legacy
   render path ([ADR-0004](adr/0004-branding-the-legacy-render-path.md)).
6. **Navigation:** the `side_menu` colour (`background-color` / `background-color-to`). The app
   itself is installed by phase `12-apps` from its vendored tarball (#98), not by this one.
7. **Theme activation:** `config:system:set theme --value apsconecta`.

**It does upload images**, with `occ theming:config <key> <absolute-path>` (§3) — an absolute path is
the only requirement. Uploading them through the panel is still forbidden: that would be the
"hand-click" AD-2 vetoes.

> **Reverting any key:** `occ theming:config <key> --reset`.

---

## 3. The brand images (nothing is uploaded)

The files live in the theme and the phase **registers** them with `occ theming:config <key>
<absolute-path>` pointing at the bind-mount. Nothing goes through the panel, no API and no admin
credentials are needed, and it is that registration which makes favicon rasterisation, the
webmanifest and branded email work:

```
gestion/themes/apsconecta/core/img/
├── logo/logo.svg          ← key `logo`: login card (full lockup)
├── logo/logo-header.svg   ← key `logoheader`: the full lockup. Since #84 it shows in the
│                            side_menu panel (`.cm-logo`), not in the header — measurements
│                            in MAPEO.md §3
│                            BOTH lockups carry their own embedded subset of Fraunces/Nunito
│                            Sans: an SVG served as an image cannot see server.css's
│                            @font-face (B-011). Regenerate with tools/embed-fonts.py
├── logo/logo-mark.svg     ← the figure alone: the header, at any width
├── home.svg               ← the header's home icon (#84). server.css uses it; it is not a
│                            theming key, so the phase does not register it
├── favicon.svg            ← key `favicon`
├── manifest.json          ← the webmanifest `smoke.sh` verifies (check 7)
└── background.svg         ← key `background`: backdrop for the WHOLE UI, not just login
```

> **Do not paint over the backdrop.** `server.css` had a light gradient on `body`/`#content` that
> hid `background.svg` completely: it was registered, served, and never once seen. Removed
> 2026-07-27.
>
> **Resolved 2026-07-27** ([ADR-0001](adr/0001-server-theme-for-branding.md) § *Pending*): we
> register all four keys ourselves, so theme-vs-DB precedence became moot.

---

## 4. The server theme

Already installed: it lives in **`gestion/themes/apsconecta/`**, which `compose.yaml` mounts at `/var/www/html/themes`. What is in git *is* what runs — there is no copy step. The tree is in §0; what `server.css` actually delivers is in [`MAPEO.md`](../themes/apsconecta/MAPEO.md).

`defaults.php` **does exist**: it came back on 2026-08-04 ([ADR-0004](adr/0004-branding-the-legacy-render-path.md)).
It no longer kills the iOS banner — `customclient_ios_appid` does that — but delivers the identity on
the legacy-render-path screens, where no config key answers. What does not exist is
`apps/<appid>/img/` (§5: zero clashing icons).

> **A theme stylesheet can change very little**, and why — `:root` inert, element selectors not —
> is rule 1 of [`THEMING-MODEL.md`](THEMING-MODEL.md). Read it before touching `server.css`.

1. **Activate the theme:** phase `15-branding` does it (`config:system:set theme --value apsconecta`).
2. **Restart:** none for the `occ` keys in this document. One is needed if you touch
   `defaults.php`, which is back and still goes through opcache.
3. **Fonts:** Fraunces and Nunito Sans as **variable woff2** (one file per family covers weights 400–800, plus the italics), in `core/fonts/`, declared by `@font-face` with absolute paths `/themes/apsconecta/core/fonts/` — **zero-egress, no Google Fonts**. **woff2 only, no TTF fallback**: no browser Nextcloud 34 supports lacks woff2, and the fallback hid errors (a missing woff2 fell back to the TTF silently). `make test` verifies every `url()` in `server.css` exists on disk. Regenerate after updating a font:
   ```bash
   python3 -c "from fontTools.ttLib.woff2 import compress; compress('X.ttf','X.woff2')"
   ```

   Converting format is neither subsetting nor renaming, so the SIL OFL is satisfied.

*(The **Custom CSS** app is ruled out as an alternative: it cannot self-host fonts, so the brand typography would be lost.)*

---

## 5. Per-app icons — there are none

`themes/apsconecta/apps/` does not exist and there is nothing to deploy here. The replacement
criterion, the measurement that left it empty, and why the stock Material icons are kept are in
[`THEMING-MODEL.md`](THEMING-MODEL.md) §4 and
[`ADR-0001`](adr/0001-server-theme-for-branding.md) § *Per-app icons*.

---

## 6. Known traps

The traps of the theming **mechanism** (`:root` inert, `background_color` deciding the text colour,
`enforce_theme` removing high contrast, an SVG that does not parse) are in
[`THEMING-MODEL.md`](THEMING-MODEL.md) §3, once. What stays here is brand-specific:

- **Product name:** `productName` is a separate key (`config:app:set theming productName`).
  Without it "Nextcloud" leaks through `status.php`, `OC.theme` and the share button.
- **The iOS "Nextcloud — Abrir" banner:** the leak is a **number**, so `grep Nextcloud` does not see
  it. Neutralised with `customclient_ios_appid ""`. Check:
  `curl -s localhost:8180/login | grep -c apple-itunes-app` → `0`.
- **Nextcloud's blue background is a *wallpaper*, not a colour:** `background_color` does not remove
  it. Here it is replaced by `background.svg`; if the image is ever withdrawn, the flat background is
  set with `theming:config background backgroundColor` — and `background_color` must be readjusted
  with it.
- **Language:** there is no `es_CL` translation. We use `default_language=es` + `force_language=es`,
  with `default_locale=es_CL` for Chilean formatting. **Do not use `es_419`** (B-009).
- **Clientless access:** if the instance blocks `status.php` from the external network, the official
  desktop and mobile apps deliberately cannot connect — the mobile route is the **PWA**.

---

## 7. PWA and mobile apps

- Nextcloud **generates the webmanifest** from theming. Verify it: `curl https://YOUR-HOST/apps/theming/manifest`.
  Mapping: `name ← productName` · `short_name ← name` · `theme_color ← primary_color` · `background_color` · icons ← `favicon`/per-app `img/app.svg` · `display ← theming.standalone_window.enabled`.
- The **official Android and iOS apps sync the server theme** automatically (colour, logo, background): theming the server keeps web, PWA, Android and iOS coherent.
- **"The PWA" and "360 px" are two different checks**, and only the first belongs to this document;
  how the second is measured is in [`THEMING-MODEL.md`](THEMING-MODEL.md) §*"PWA at 360 px" was two
  different checks*, and what the header does at that width is fixed by
  [`MAPEO.md`](../themes/apsconecta/MAPEO.md) §3, which owns the numbers.

---

## 8. Final verification

1. **Hard refresh:** Ctrl/Cmd + Shift + R.
2. Check: login (gradient + logo), header (mark + home icon + clinic name above 601 px; mark alone
   below), favicon, PWA (`/apps/theming/manifest`), and that neither "Nextcloud" nor the number
   `1125420102` appears.
   **Email cannot be checked yet:** no SMTP is configured anywhere in the repo, so the instance
   cannot send anything. This step is blocked by the deferred mail decision (see the *Future*
   section of `ROADMAP.md`); the theme does reach the mail templates, but that has not been seen in
   a real message.
3. Confirm the theme selector **does not exist** and dark mode is unreachable (`enforce_theme=light`).
4. **Check the theme that actually loaded.** Paste the console snippet from
   [`THEMING-MODEL.md` §5](THEMING-MODEL.md) into devtools **on a Nextcloud page**, reading
   `document.body`. (The brandbook's "Deriva" panel did this between files and was removed on
   2026-07-27: it could not see a running instance, which is exactly why it never noticed the whole
   map was inert.)
5. **Automatic gates:** `make test` (SVGs parse, every `url()` in `server.css` exists) and
   `make smoke` (`/status.php` returns 200 and does **not** contain "Nextcloud").

## 9. Viewing the brandbook

From the kit folder (`../APS Conecta Nextcloud/`, sibling of this repo):

```bash
cd "../APS Conecta Nextcloud" && python3 -m http.server 8080
# open http://localhost:8080/sistema-diseno.html
```

(Under `file://` the fonts and some assets do not load; use the local server.)

## 10. Licensing

[`LICENSING.md`](LICENSING.md) owns this, and [ADR-0010](adr/0010-agpl-across-the-org.md) is the
decision. What matters when deploying the brand: our own code — this theme included — is
**AGPL-3.0-or-later** (§1), the logo artwork is reserved by **trademark** under AGPL **§7(e)** while
the colour tokens ship AGPL with the code, and the brand fonts are **SIL OFL 1.1** (§3.2 — the SVG
lockups do embed a subset, which the licence permits; what is not done is renaming them).
