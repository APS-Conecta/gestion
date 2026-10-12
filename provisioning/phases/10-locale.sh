# Phase 10 — es-CL locale defaults.  OWNER: Epic 1 (only Epic 1 edits this file).
# Seeds Chilean-Spanish locale defaults config-as-code (AD-7), idempotent. Values are UNLOCKED —
# users/devs may change them.
phase_begin "10-locale" "es-CL locale defaults (Epic 1)"

# `es` is the only Spanish TRANSLATION NC34 core ships (alongside es_EC and es_MX). es_419 was set
# here until B-009: it is a valid ICU *locale* but not a language, so languageExists() rejects it
# and Factory::findLanguage() step 4 can never return it — the key was inert and the browser's
# Accept-Language decided, with English as the floor. Language and locale are separate slots and
# only the language one was wrong: es_CL remains correct for Chilean date/number formatting.
config_system_set default_language "es"
# Without this the default only applies to users whose browser asks for nothing Nextcloud has —
# findLanguage() reads the request header BEFORE the default, and persists it as a user setting.
# Same call this instance already made for the theme (enforce_theme) and the editor
# (customizationTheme): a personal client setting does not change what staff see.
config_system_set force_language "es"
config_system_set default_locale "es_CL"
config_system_set default_phone_region "CL"

phase_end
