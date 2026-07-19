# Phase 10 — branding + es-CL locale.  OWNER: Epic 1 (only Epic 1 edits this file).
# White-labels the instance as APS Conecta in Chilean Spanish, config-as-code (AD-6/AD-7), idempotent.
# NOTE: NC34's `occ theming:config` sets text/color keys only — logo/favicon/background are NOT
# CLI-settable (admin-UI uploads). See docs/planning/implementation/1-1-white-label-branding-phase.md.
phase_begin "10-branding" "APS Conecta branding + es-CL locale (Epic 1)"

# --- Story 1.1: white-label branding (AD-6) — text + colors via occ theming:config ---
theming_set name "APS Conecta"
theming_set slogan "Gestión interna CESFAM"
theming_set url "https://github.com/APS-Conecta/gestion"
# Provisional brand palette (professional healthcare teal) — owner to confirm against a brand guide.
theming_set primary_color "#17667a"
theming_set background_color "#ffffff"
# Keep the brand consistent for all users (no per-user re-theming). AD-6.
theming_set disable-user-theming "yes"

# --- Story 1.2: es-CL locale defaults (AD-7) — seeded but UNLOCKED (users/devs may change) ---
# es_419 = the UI translation Nextcloud actually ships (a discrete es_CL translation does not exist);
# es_CL = a valid ICU locale for Chilean date/number formatting. Timezone is a per-user setting.
config_system_set default_language "es_419"
config_system_set default_locale "es_CL"
config_system_set default_phone_region "CL"

phase_end
