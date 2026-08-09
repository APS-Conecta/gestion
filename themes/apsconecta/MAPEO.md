# MAPEO.md — the theme's brand sheet

What you need in order to work on `core/css/server.css`: the palette with its contrast ratios, the
typographic decisions, and the header geometry.

**The mechanism is not here.** Why `:root` is inert, why `background_color` decides the text colour,
what a theme stylesheet can and cannot reach — all of that lives once, in
[`docs/THEMING-MODEL.md`](../../docs/THEMING-MODEL.md). The decision to have a theme at all is in
[`ADR-0001`](../../docs/adr/0001-server-theme-for-branding.md). This file links; it does not repeat.

## 1. Contrast ledger

The brand gold `#e06f00` measures **3.07:1** on white → **fails AA for small text**. Permitted use:
fills, icons, badges and large text (≥24 px, or ≥19 px bold). For small text on white use the dark
gold **`#9a4c00`** (≥4.5:1).

| Colour | Hex | Ratio | Use |
|---|---|---|---|
| Primary violet | `#7f21fe` | 5.57:1 | AA text/UI ✓ (`primary_color`) |
| Dark violet | `#5315a8` | ~8:1 | Headings, backdrop ✓ (`background_color`) |
| Error pink | `#ea003e` | 4.33:1 | UI/border/large text — **not** body text |
| Gold | `#e06f00` | 3.07:1 | Fills/icons/large text |
| Dark gold | `#9a4c00` | ≥4.5:1 | Small text |
| Ink | `#101828` | ~16:1 | Main text |
| Muted | `#485363` | ~7:1 | Secondary text |

The two violets are **not interchangeable**: `background_color` must stay the dark one (`#5315a8`),
because Nextcloud derives the text colour over the backdrop and the header icon inversion from it
(THEMING-MODEL rule 5).

## 2. Typography

- **Families:** Fraunces (display: `h1`–`h3`, header) · Nunito Sans (everything else).
- **Nunito Sans is delivered through `--font-face`**, the only documented typographic variable, with
  `!important`. **Fraunces goes through element selectors**, because no documented variable exists
  for a display font.
- `@font-face` with **absolute paths** `/themes/apsconecta/core/fonts/`. Outside Nextcloud they 404;
  `sistema-diseno.html` redeclares them with relative paths.
- **`.woff2` only**, no `.ttf` fallback (ADR-0001).
- The served `.woff2` files are **not subset**; the SVG lockups **do** embed a subset. Both are
  compatible with SIL OFL-1.1 — the detail is in
  [`docs/LICENSING.md`](../../docs/LICENSING.md) §3.2, the single source on licensing.
- Nextcloud's `--default-font-size` (15 px) and `--default-line-height` (1.5) are kept, so as not to
  throw off `@nextcloud/vue`'s density.

## 3. Header geometry

The `#nextcloud` slot reserves **68 px of padding** for the mark, which core positions absolutely
(`inset-inline-start:12px`, with its own width of 62); `server.css` narrows it to 46, so it ends at
58. 68 and not 52 (#102): at 52 the flex row started 6 px inside the mark. `logo-mark.svg` is served
at 34×30 within those 46. The three slots — mark, home (19 px within 36) and clinic name (12 px of
padding) — are 36 px tall with radius 8, so the hover highlight falls the same way on each. Only
above **601 px**; below it the two generated slots are withdrawn (`content: none`) and core's 62×44
slot returns, with the same mark.

The rules are scoped to `a#nextcloud`, not `#nextcloud`: the **public link** header uses that same id
on a `<div>` with its own content, and unscoped it was getting the header's padding.
`scripts/test.sh` verifies this against both templates.

## 4. What the theme does NOT touch

No dark mode (`enforce_theme=light`), no per-app icons (measured: zero multi-tint icons), and no
canvas rule — painting `body`/`#content` hid the brand background image completely.

**It does touch, since 2026-08-04, the screens Nextcloud draws the legacy way** — maintenance, both
upgrade screens, 429, the exception screen, untrusted domain, the server-config error and the three
setup screens. Those screens do not emit the event `server.css` hangs off, so they arrived in
Nextcloud's blue and with its logo. `core/css/guest.css` covers them (with `defaults.php` for the
identity strings, because on an untrusted domain Nextcloud does not even consult the brand config).
It is the only part of the theme that declares variables in `:root` without `!important`, and that is
deliberate: it wins on those screens and stays inert everywhere else. The full detail is in
`docs/adr/0004-branding-the-legacy-render-path.md`.
