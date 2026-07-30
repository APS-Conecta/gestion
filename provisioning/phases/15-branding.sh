# Phase 15 — APS Conecta white-label branding.  OWNER: Epic 5 (only Epic 5 edits this file).
# Applies the identity layer config-as-code (AD-2) and activates the server theme. Idempotent.
# Rationale and accepted costs: docs/adr/0001-server-theme-for-branding.md. What the theme's CSS can
# and cannot reach: docs/THEMING-MODEL.md — most of the brand arrives through the keys set here.
#
# Deliberately absent: a container restart (only ever needed for defaults.php's opcache, and that
# file is gone) and per-app icon overrides (every enabled app was scanned: zero multi-tint icons, so
# themes/apsconecta/apps/ does not exist).
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
# MUST match the dominant tone of the background image below, and is not decorative:
# CommonThemeTrait.php:82-83 derives --color-background-plain-text and
# --background-image-invert-if-bright from THIS value. White here told Nextcloud the backdrop was
# bright, so it computed BLACK text and inverted the header icons on top of a violet image.
theming_set background_color "#5315a8"

# Kills the "Nextcloud — Abrir" smart-app banner: OC_Defaults.php:44 reads this SYSTEM key and the
# layout templates emit <meta name="apple-itunes-app"> only when the id is not ''. This replaced
# themes/apsconecta/defaults.php, and dropped the opcache container restart that file required.
config_system_set customclient_ios_appid ""

# --- Light theme only (owner decision — no dark mode) ---
# Complementary, both wanted: enforce_theme removes theme/appearance selection; disable-user-theming
# stops per-user background and colour overrides. The latter goes through theming:config, NOT a raw
# app config — ThemingController stores it with setAppValueBool, which writing "yes" directly bypasses.
config_system_set enforce_theme light
theming_set disable-user-theming yes 1   # writes 'yes', stores '1' — see theming_set in lib.sh

# --- Brand images ---
# occ DOES set all four on NC34 (ImageManager::SUPPORTED_IMAGE_KEYS) — it just needs an ABSOLUTE
# path resolvable inside the container, which the themes/ bind mount provides. Going through the
# Theming app's pipeline is what makes favicon rasterisation, the webmanifest and branded emails
# work, and is the only way to set `background` at all, since core ships no background image.
IMG=/var/www/html/themes/apsconecta/core/img
theming_image_set logo       "$IMG/logo/logo.svg"
# Both keys carry the full lockup — server.css widens the 62x44 header slot to 224px and adds the
# INICIO label, so it fits at design size. BOTH lockups embed their own font subset: an SVG served
# as an image cannot reach server.css's @font-face, so `Fraunces, Georgia, serif` rendered GEORGIA
# on every page (B-011). Regenerate with themes/apsconecta/tools/embed-fonts.py.
theming_image_set logoheader "$IMG/logo/logo-header.svg"
theming_image_set favicon    "$IMG/favicon.svg"
# The whole-UI background, not just the login screen — CommonThemeTrait feeds it into
# --image-background. Under review for 8-hour legibility (ROADMAP Epic 5, P1).
theming_image_set background "$IMG/background.svg"

# --- Navigation chrome ---
# side_menu is installed by 12-apps; only its colour is set here. It paints itself from a DERIVED
# colour — CssController.php:87 falls back to getDarkenPrimaryColor(), which came out #661bcc, a
# third violet nobody chose. Pointing it at the brand backdrop collapses three near-identical
# purples into two.
app_config_set side_menu background-color "#5315a8"
app_config_set side_menu background-color-to "#5315a8"

# Where INICIO lands. server.css labels `#nextcloud` (always the home link) with the word; this is
# the other half — what "home" means. URLGenerator::linkToDefaultPageUrl() resolves
# ?redirect_url -> core/defaultpage -> per-user defaultapp -> system defaultapp -> hardcoded
# 'dashboard,files'. Both keys were unset, so the destination was that hardcoded fallback: correct
# by accident. Setting it pins today's behaviour. First ENABLED navigation entry wins, so `files`
# covers dashboard ever being restricted by 16-app-policy.
#
# Not set: `core/defaultpage`, which would win over all of this and takes a raw path — the lever if
# "home" ever needs to be a specific folder.
config_system_set defaultapp "dashboard,files"

# --- New users start with an empty home, not Nextcloud's (#49) ---
# Nextcloud copies core/skeleton/ into every new user's files: an English Readme.md rendering as
# "Welcome to Nextcloud!" at the top of the Files view, plus English Documents/Photos/Templates.
# On an es-CL instance that is both a white-label and a language leak, on the landing view staff use
# all day. Empty rather than a Spanish skeleton because Epic 3 already put the real structure in
# Team Folders (owner decision 2026-07-29).
#
# copySkeleton() guards on `if (!empty($skeletonDirectory))`, so "" genuinely means copy nothing.
# Affects NEW users only. ACCEPTED COST: initializeTemplateDirectory() sits inside that same guard,
# so new users get no Templates/ folder and "+ New" offers no template entries (owner decision
# 2026-07-30). Revisit when someone wants a standard acta or informe.
config_system_set skeletondirectory ""

# --- Activate the server theme (themes/apsconecta, bind-mounted by compose.yaml) ---
config_system_set theme apsconecta

phase_end
