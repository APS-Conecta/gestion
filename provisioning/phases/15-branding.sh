# Phase 15 — APS Conecta white-label branding.  OWNER: Epic 5 (only Epic 5 edits this file).
# Applies the identity layer config-as-code (AD-2) and activates the server theme. Idempotent.
# Rationale, accepted costs and the live-verification snippet: docs/adr/0001-server-theme-for-branding.md
#
# What is NOT here, deliberately:
#   · Images. Logo, favicon and login background are FILES in themes/apsconecta/core/img/, served by
#     Nextcloud's theme-first image lookup. NC34's occ cannot set them, and uploading them through the
#     admin UI would be the hand-clicking AD-2 forbids.
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
# Complementary, both wanted: enforce_theme removes theme/appearance selection;
# disable-user-theming stops per-user background and colour overrides.
config_system_set enforce_theme light
app_config_set theming disable-user-theming yes

# --- Activate the server theme (themes/apsconecta, bind-mounted by compose.yaml) ---
config_system_set theme apsconecta

phase_end
