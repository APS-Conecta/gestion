# Phase 15 — APS Conecta white-label branding.  OWNER: Epic 5 (only Epic 5 edits this file).
# Applies the identity layer config-as-code (AD-2) and activates the server theme. Idempotent.
# Rationale, accepted costs and the live-verification snippet: docs/adr/0001-server-theme-for-branding.md
#
# What is NOT here, deliberately:
#   · A container restart. It was only ever needed for defaults.php's opcache, and defaults.php is
#     gone (2026-07-27) — see the customclient_ios_appid block below.
#   · Per-app icon overrides. Every enabled app was scanned on the live instance: zero multi-tint
#     icons, so nothing meets the clash criterion. themes/apsconecta/apps/ does not exist.
#   · Any CSS. What the theme's CSS can and cannot reach is docs/THEMING-MODEL.md; most of the
#     brand arrives through the keys set here, not through server.css.
phase_begin "15-branding" "APS Conecta white-label (Epic 5)"

# --- Identity ---
theming_set name       "APS Conecta Gestión"
theming_set slogan     "La salud primaria que compartimos es la que mejora"
theming_set url        "https://apsconecta.cl"
theming_set imprintUrl "https://apsconecta.cl"
theming_set privacyUrl "https://apsconecta.cl/privacidad"

# productName is a SEPARATE key, not a theming:config one. Without it "Nextcloud" leaks through
# status.php, OC.theme, the OCS capabilities and the public-share button.
app_config_set theming productName "APS Conecta Gestión"

# --- Colours ---
theming_set primary_color    "#7f21fe"
# background_color MUST match the dominant tone of the background image below. It is not
# decorative: CommonThemeTrait.php:82 derives --color-background-plain-text from THIS value
# (via Util::invertTextColor, contrast-vs-white < 4.5), and :83 derives
# --background-image-invert-if-bright from it too. White here told Nextcloud the backdrop was
# bright, so it computed BLACK text and inverted the header icons on top of a violet image.
# Measured on the live instance 2026-07-27: plain-text #000000, invert(100%).
theming_set background_color "#5315a8"

# --- iOS banner ---
# Kills the "Nextcloud — Abrir" smart-app banner. lib/private/legacy/OC_Defaults.php:44 reads
# this SYSTEM key (default '1125420102'), and core/templates/layout.{user,public,guest}.php
# emit <meta name="apple-itunes-app"> only when the id is not ''.
# This replaces themes/apsconecta/defaults.php, deleted 2026-07-27. ADR-0001 claimed no config
# key could do this and kept a whole OC_Theme class for it; that claim was wrong. Dropping the
# file also drops the opcache container restart it required. Verified by reading the pinned
# image, not a running stack.
config_system_set customclient_ios_appid ""

# --- Light theme only (owner decision — no dark mode) ---
# Complementary, both wanted: enforce_theme removes theme/appearance selection (a SYSTEM value,
# read by ThemesService); disable-user-theming stops per-user background and colour overrides.
# The latter is a theming:config key, NOT a raw app config: ThemingController stores it with
# setAppValueBool, and the theming ConfigLexicon types it. Writing the string "yes" directly
# would bypass that conversion.
config_system_set enforce_theme light
theming_set disable-user-theming yes 1   # writes 'yes', stores '1' — see theming_set in lib.sh

# --- Brand images ---
# occ DOES set these on NC34 — ImageManager::SUPPORTED_IMAGE_KEYS is
# ['background','logo','logoheader','favicon'] — it just requires an ABSOLUTE path that exists
# inside the container. themes/ is bind-mounted, so the theme's own files are already reachable.
# Using the Theming app's pipeline (rather than leaving these to theme-first image lookup) is what
# makes favicon rasterisation, the webmanifest and branded emails work — and it is the only way to
# set `background` at all, since core ships no background image for a theme to override.
# SVG is accepted for every key; only `favicon` requires imagick with the SVG delegate, which the
# nextcloud:34-apache image has.
IMG=/var/www/html/themes/apsconecta/core/img
theming_image_set logo       "$IMG/logo/logo.svg"
# Both keys carry the full lockup. The header slot was 62x44 px, which drew the wordmark at ~4 px
# and is why this used to be a mark-only file; server.css now widens that slot to 224 px and adds
# the INICIO label, so the lockup fits at its design size (owner decision 2026-07-30).
#
# BOTH lockups embed their own subset of Fraunces/Nunito Sans. An SVG served as an image is an
# isolated document and cannot reach server.css's @font-face, so `Fraunces, Georgia, serif` had
# been rendering GEORGIA on every page (B-011). Regenerate with themes/apsconecta/tools/embed-fonts.py.
theming_image_set logoheader "$IMG/logo/logo-header.svg"
theming_image_set favicon    "$IMG/favicon.svg"
# NOTE: this is the whole-UI background, not just the login screen — CommonThemeTrait feeds it into
# --image-background for the app theme. Under review for 8-hour legibility (ROADMAP Epic 5, P1).
# Fallback if it reads badly behind a file list:  theming:config background backgroundColor
theming_image_set background "$IMG/background.svg"

# --- Navigation chrome ---
# Sidebar navigation instead of the top app grid. Third-party (Simon Vieille, NC34-supported).
# Installed by 12-apps; only its colour is configured here.
#
# side_menu paints itself from a DERIVED colour, not a brand one. CssController.php:87 reads its
# own `background-color` app value and falls back to getDarkenPrimaryColor() — a 20%-darker
# primary, which came out as #661bcc. That is a third violet sitting between brand primary
# (#7f21fe) and brand backdrop (#5315a8): not wrong, but not a colour anyone chose.
# Pointing it at the backdrop violet the brand already defines collapses three near-identical
# purples into two, so the palette reads as a system rather than a gradient of accidents.
app_config_set side_menu background-color "#5315a8"
app_config_set side_menu background-color-to "#5315a8"

# Where INICIO lands. server.css labels `#nextcloud` (which has always been the home link) with the
# word INICIO; this is the other half — what "home" means. Measured chain in NC34,
# URLGenerator::linkToDefaultPageUrl():  ?redirect_url  →  appconfig core/defaultpage (a path)  →
# per-user core/defaultapp  →  system defaultapp  →  hardcoded 'dashboard,files'.
#
# Both keys were unset here, so the destination was the hardcoded fallback: correct by accident.
# Setting it explicitly pins today's behaviour so an upstream change to that fallback cannot move
# where a word we put on screen goes. Comma-separated, first entry that is an ENABLED navigation
# entry wins (NavigationManager::getDefaultEntryIds filters against the live entries), so `files`
# is the fallback if dashboard is ever restricted by 16-app-policy.
#
# Not set: `core/defaultpage`. It would win over all of this and takes a raw path, which is the
# lever if "home" ever needs to be a specific folder — a decision, not a default.
config_system_set defaultapp "dashboard,files"

# --- New users start with an empty home, not Nextcloud's (#49) ---
# Nextcloud copies core/skeleton/ into every new user's files at creation: an English Readme.md
# whose heading renders as "Welcome to Nextcloud!" at the top of the Files view, plus English
# Documents/ Photos/ Templates/ folders. On an es-CL instance that is both a white-label leak and a
# language leak, and it sits on the landing view of the app staff use all day — a more visible leak
# than B-008 ever was.
#
# Empty rather than a Spanish skeleton: Epic 3 already put the real structure in Team Folders, so a
# second personal tree would compete with it for attention and staff would have to learn which one
# matters. Owner decision 2026-07-29. If a personal starter structure is ever wanted, Nextcloud
# resolves a {lang} placeholder in this path natively (TemplateManager::copySkeleton), so it stays a
# directory we ship rather than code we write.
#
# TemplateManager::copySkeleton() guards the copy with `if (!empty($skeletonDirectory))`, so the
# empty string genuinely means "copy nothing" — it is not a fallback to the default.
# Affects NEW users only; the fixture users created before this keep their English tree.
#
# IT ALSO TURNS OFF DOCUMENT TEMPLATES, which was not the intent and is now an accepted cost (owner
# decision 2026-07-30). initializeTemplateDirectory() is called INSIDE that same guard
# (TemplateManager.php:485-492), so new users get no Templates/ folder and the Files "+ New" menu
# offers no "from template" entries. Accepted because nobody has asked for templates; revisit when
# someone wants a standard acta or informe, and check whether the `templatedirectory` system key can
# restore them without bringing back the English skeleton — unverified against the pinned image.
config_system_set skeletondirectory ""

# --- Activate the server theme (themes/apsconecta, bind-mounted by compose.yaml) ---
config_system_set theme apsconecta

phase_end
