# ADR-0004 — Branding the legacy render path

**Status:** accepted, 2026-08-04. Amends ADR-0001, which said "No `defaults.php`".

## Context

Nextcloud draws two classes of screen, and only one of them announces itself.

A **framework-rendered** screen dispatches `BeforeTemplateRenderedEvent` as it renders.
`core/Listener/BeforeTemplateRenderedListener.php` reacts by adding `core/css/server.css`, and the
CSS resource locator appends the theme's copy beside it — which is the *only* reason our
`server.css` is ever requested; nothing links it by name. The Theming app hangs its generated
variable sheets off the same event.

A **legacy-rendered** screen goes through `Template::printPage()` and dispatches nothing. There are
**seven such call sites in two files** on NC 34.0.1:

| Site | Screens |
|---|---|
| `lib/base.php:253` | maintenance mode |
| `lib/base.php:322` | upgrade required (CLI-only updater) |
| `lib/base.php:384` | update in progress |
| `lib/base.php:909` | untrusted domain |
| `TemplateManager.php:52` (`printGuestPage`) | HTTP 429 · installation · installation incomplete · installation forbidden · the server-config error at `lib/base.php:785` |
| `TemplateManager.php:134` | fatal exception page |
| `TemplateManager.php:96` | `printErrorPage`'s **catch-block fallback only** |

The last row is the one worth reading twice: `printErrorPage`'s normal path *does* dispatch the
event (`:82`) and renders through the framework, so it is branded. Line 96 runs only when that
themed render has already thrown.

Those screens therefore loaded exactly two stylesheets — `apps/theming/css/default.css`, whose
`:root` carries stock `#00679e` and Nextcloud's own photographic backdrop, and `core/css/guest.css`,
whose `var(--image-logo, url("../../core/img/logo/logo.svg"))` falls back to the vendor's logo.
Measured on the untrusted-domain screen: **zero themed CSS and 14 occurrences of "Nextcloud"**.

Two facts constrain any fix:

1. **No app can reach this class.** In maintenance mode `lib/base.php` dies before `loadApps()`.
   ADR-0001 named "a small branding app" as the fallback if `themes/` were ever removed; for these
   screens that fallback does not exist. `themes/` is the only mechanism.
2. **`ThemingDefaults` is not always what answers.** `lib/private/Server.php:1052-1056` hands it out
   only when the class autoloads *and* `installed` is true *and* theming is enabled *and*
   **the request host is trusted**. Otherwise the container returns a raw `\OC_Defaults`, whose
   identity strings are hardcoded literals with no system key behind them. Two screens in the class
   fail that test *by definition* — the untrusted-domain warning, whose whole purpose is an
   untrusted host, and the three setup screens, which run with `installed` false. Separately,
   `lib/base.php:387-395` builds `new \OC_Defaults()` **directly** for the two upgrade screens'
   product name, bypassing the container even on a healthy trusted host.

## Decision

Three artifacts, each the smallest thing that closes one of those routes.

**1. `themes/apsconecta/core/css/guest.css`** — an `@import` of `server.css` (fonts and typography,
which otherwise reach none of these screens) plus a `:root` block declaring the five variables
`core/css/guest.css` reads and gets wrong: `--image-logo`, `--image-background`,
`--color-background-plain`, `--color-primary-element`, `--color-primary-element-hover`.

Both resource strings that reach core's file — `addStyle('core','guest')` from `lib/base.php:252`
and `addStyle('guest')` from `TemplateLayout.php:280` — resolve through `doFindTheme()` onto this one
path, so it is linked twice on some screens. Identical bytes, idempotent, accepted.

**2. `themes/apsconecta/defaults.php`** — `class OC_Theme` defining `getName`, `getTitle`,
`getEntity`, `getProductName`, `getSlogan`, `getBaseUrl`, `getColorPrimary`, `getColorBackground`.
`OC_Defaults` consults it method by method (`method_exists`), so anything not defined keeps
upstream's value.

**3. `themes/apsconecta/core/l10n/es.json`** — a two-key override. `Factory::getL10nFilesForApp()`
loads `themes/<theme>/<same relative path>` after the core file and `L10N::load()` merges with
`array_merge`, so later keys win and a two-key file overrides exactly two strings.

## Consequences

**Rule 1 of THEMING-MODEL has an exception, and it is load-bearing.** That rule says a variable
declared in `:root` is inert and needs `!important` on `body`. It is true *on framework-rendered
screens*, where the Theming app's generated sheets declare the same variables later. On the legacy
screens those sheets are absent, only the static `default.css` and `core/css/guest.css` are present,
and the theme's copy appends after both — so plain `:root` wins there and is overruled everywhere
else. That is not a loophole, it is the mechanism: it makes `guest.css` self-limiting, and it is why
the file carries no `!important`. Adding one would break `/login`, which loads this file too.

**`defaults.php` reintroduces an opcache dependency.** Editing it needs a container restart.
`provisioning/phases/15-branding.sh` had dropped that cost when the file was deleted; the file is
static and committed, so the cost is install-time, never per-seed. Its comment is corrected.

**Identity here is the product's, never the clinic's.** These screens stay byte-identical on every
install — no dependency on the generated `site.css`. The values duplicate `15-branding.sh`, which
stays the source of truth.

**One vendor exemption is named, not assumed.** The admin documentation link on the untrusted-domain
screen (`docs.nextcloud.com`, visible label "documentación") and the sync-client URL point at real
destinations. Renaming them would ship a lie, which is the worse defect — the CONTEXT.md
*vendor reference* rule. `getBaseUrl` is deliberately **not** in that exemption: `getShortFooter()`
wraps `getEntity()` in it, and leaving it upstream rendered `<a href="https://nextcloud.com">APS
Conecta Gestión</a>` — our name on the vendor's homepage, which is a mislabelled outbound vendor
link rather than a reference to anything.

**Static icons win over the Theming app's endpoint on every screen, not just these.**
`layout.guest.php` hardcodes `image_path('core', 'favicon.ico')` and friends, so the theme's files
now serve `/login` too, where `/apps/theming/favicon` used to. Same trade the repo already took for
`manifest.json`: the failure mode becomes **drift** from `occ theming:config` rather than absence,
and `scripts/smoke.sh` asserts against it. Note `imagePath()` caches under a key containing neither
a cachebuster nor the theme, so on an instance whose cache was warm before the files existed the
icons stay Nextcloud's until the cache is flushed.

**The gate is an enumeration, and that is the point.** `scripts/test.sh` asserts the count of
`->printPage()` call sites is exactly 7. Everything else verifies today's instance; this is the only
check that can notice an NC35 adding an eighth screen — a screen nobody has looked at. When it
fails, read the new site, decide whether `guest.css` already covers it, then move the number.

## Considered options

- **A branding app.** Retired by fact 1: no app is loaded in maintenance mode.
- **Patch core.** Forbidden by AGENTS.md; ADR-0002 covers *app* patches, not core.
- **A system config key for the identity strings.** None exists — `OC_Defaults` assigns
  `'Nextcloud'` as a literal.
- **Declare on `body` with `!important`, per Rule 1.** Would win on the legacy screens *and* on
  `/login`, overruling the Theming app where it is already correct. Losing on framework screens is
  the desired behaviour, not a compromise.
- **Restate `--color-background-plain-text` and `--color-primary-element-text`.** They are already
  `#ffffff` in the static `default.css`, and white on `#5315a8` is 10.3:1. A second place to drift.
