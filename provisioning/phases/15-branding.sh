# Phase 15 — APS Conecta white-label branding.  OWNER: Epic 5 (only Epic 5 edits this file).
# Applies the identity layer config-as-code (AD-2) and activates the server theme. Idempotent.
# Rationale, accepted costs and the live-verification snippet: docs/adr/0001-server-theme-for-branding.md
#
# What is NOT here, deliberately:
#   · A container restart. defaults.php is bind-mounted and present before PHP boots, so on a fresh
#     `make up` it compiles on first use. A restart is only needed after EDITING defaults.php, which
#     is a dev-loop concern — `docker compose restart nextcloud` then.
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
theming_set background_color "#ffffff"

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
theming_image_set logoheader "$IMG/logo/logo.svg"
theming_image_set favicon    "$IMG/favicon.svg"
# NOTE: this is the whole-UI background, not just the login screen — CommonThemeTrait feeds it into
# --image-background for the app theme. Under review for 8-hour legibility (ROADMAP Epic 5, P1).
# Fallback if it reads badly behind a file list:  theming:config background backgroundColor
theming_image_set background "$IMG/background.svg"

# --- Activate the server theme (themes/apsconecta, bind-mounted by compose.yaml) ---
config_system_set theme apsconecta

phase_end
