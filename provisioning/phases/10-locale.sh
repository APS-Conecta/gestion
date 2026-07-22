# Phase 10 — es-CL locale defaults.  OWNER: Epic 1 (only Epic 1 edits this file).
# Seeds Chilean-Spanish locale defaults config-as-code (AD-7), idempotent. Values are UNLOCKED —
# users/devs may change them.
phase_begin "10-locale" "es-CL locale defaults (Epic 1)"

# es_419 = the UI translation Nextcloud actually ships (a discrete es_CL translation does not exist);
# es_CL = a valid ICU locale for Chilean date/number formatting. Timezone is a per-user setting.
config_system_set default_language "es_419"
config_system_set default_locale "es_CL"
config_system_set default_phone_region "CL"

phase_end
