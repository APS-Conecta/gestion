# Phase 15 — APS Conecta white-label branding.  OWNER: Epic 5 (only Epic 5 edits this file).
# Applies the identity layer config-as-code (AD-2) and activates the server theme. Idempotent.
# Rationale and accepted costs: docs/adr/0001-server-theme-for-branding.md. What the theme's CSS can
# and cannot reach: docs/THEMING-MODEL.md — most of the brand arrives through the keys set here.
#
# Deliberately absent: per-app icon overrides (every enabled app was scanned: zero multi-tint icons,
# so themes/apsconecta/apps/ does not exist).
#
# themes/apsconecta/defaults.php CAME BACK in ADR-0004, so the opcache restart this phase used to
# note is real again — but it is not this phase's job. That file is static and committed, identical
# on every install, and nothing here writes it: it changes on a git pull, not on a seed. Restart the
# container after one of those, never after this.
phase_begin "15-branding"

# org L5-03: this phase's OUTPUT is a pure function of the site identity. An unset name
# writes `--aps-clinic: "";` into site.css and every following seed sees it "already right".
# The :? forms refuse loudly instead — unset and empty are the same defect here.
: "${SITE_NOMBRE_CORTO:?sites/$SITE/site.sh must set SITE_NOMBRE_CORTO}"

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
# `logo` is the login lockup; `logoheader` is the lockup the SIDE MENU shows (`.cm-logo`), because
# server.css swaps the header slot's art for `logo-mark.svg` (#84).
# BOTH lockups embed their own font subset: an SVG served
# as an image cannot reach server.css's @font-face, so `Fraunces, Georgia, serif` rendered GEORGIA
# on every page (B-011). Regenerate with themes/apsconecta/tools/embed-fonts.py.
theming_image_set logoheader "$IMG/logo/logo-header.svg"
theming_image_set favicon    "$IMG/favicon.svg"
# The whole-UI background, not just the login screen — CommonThemeTrait feeds it into
# --image-background. Under review for 8-hour legibility (ADR-0001 § Decision, brand-images bullet).
theming_image_set background "$IMG/background.svg"

# --- Navigation chrome ---
# side_menu is installed by 12-apps; only its colour is set here. It paints itself from a DERIVED
# colour — CssController.php:87 falls back to getDarkenPrimaryColor(), which came out #661bcc, a
# third violet nobody chose. Pointing it at the brand backdrop collapses three near-identical
# purples into two.
app_config_set side_menu background-color "#5315a8"
app_config_set side_menu background-color-to "#5315a8"

# Where the header's home icon lands. server.css turns `#nextcloud` (always the home link) into
# a house; this is the other half — what "home" means. URLGenerator::linkToDefaultPageUrl() resolves
# ?redirect_url -> core/defaultpage -> per-user defaultapp -> system defaultapp -> hardcoded
# 'dashboard,files'.
#
# intravox, ADR-0014: the welcome screen IS the intranet surface — a login lands on it. The
# value is deliberately bare (no ,files tail): while the app is absent or disabled, resolution
# falls through to the hardcoded 'dashboard,files', so rollback needs no counter-edit — disable
# the app and the pre-flip landing is back. Browser-open proof preceded this flip (farmacia
# lesson 2a32278): a default-language user opens on the seeded es welcome, verified live
# 2026-09-26 with the promotion's vendored build before this line changed.
#
# Not set: `core/defaultpage`, which would win over all of this and takes a raw path — the lever if
# "home" ever needs to be a specific folder.
config_system_set defaultapp "intravox"

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

# --- The establishment's name, into the theme (#84) ---
# The ONLY per-install byte in themes/. server.css @imports this file and reads `--aps-clinic` in
# the header slot and above the login heading; everything else in the theme is identical on every
# install, which is what keeps themes/ a single committed artifact across establishments.
#
# Written on the HOST, not through occ: themes/ is a bind mount, so the file the container serves
# is this one. It is NOT tracked — its content depends on which establishment is installed, so it
# follows the same rule as sites/<slug>/site.sh and .env. A checkout that has never run this phase
# therefore has no such file: server.css's `var(--aps-clinic, "APS Conecta Gestión")` fallback
# renders the product's own name, and scripts/test.sh's asset guard skips this one path by name for
# that reason (every other themed path it checks is a static asset that must exist).
#
# Not query-before-set. Comparing would mean parsing CSS to recover one string; rewriting two lines
# is cheaper than the guard, and the content is a pure function of SITE_NOMBRE_CORTO. It is written
# unconditionally BUT ONLY WHEN IT WOULD CHANGE — seed-idempotent.sh reads the log for write verbs,
# so an unconditional log line would redden a second seed that changed nothing.
SITE_CSS=themes/apsconecta/core/css/site.css
# A double quote in a clinic name would close the CSS string early and swallow the rest of the
# file. This said "DEIS has none today", which was never true — four names in the shipped
# register carry one, e.g. DEIS 201079 `SAPU "Dr. Juan Lozic Perez"`. The escape below was
# always the thing doing the work, not the premise above it.
_clinic_escaped=$(printf '%s' "$SITE_NOMBRE_CORTO" | sed 's/["\\]/\\&/g')
if ! grep -qF -- "--aps-clinic: \"${_clinic_escaped}\";" "$SITE_CSS" 2>/dev/null; then
  cat > "$SITE_CSS" <<CSS
/* GENERATED by provisioning/phases/15-branding.sh — do not edit by hand, do not commit.
   Rewritten on every \`make install\` that finds a different establishment. Gitignored: its content
   is the one thing in themes/ that depends on which establishment this install serves. Absent until
   the first install, and server.css's fallback renders the product name until then. */
:root {
  --aps-clinic: "${_clinic_escaped}";
}
CSS
  log "site.css -> --aps-clinic: $SITE_NOMBRE_CORTO"
else
  log "site.css already names $SITE_NOMBRE_CORTO"
fi

phase_end
