# ADR-0018 — language reality is the engine's es-only default

- **Status:** accepted (2026-09-27, with the es-only language mechanics plan's approval).
- **Affects:** `provisioning/phases/41-intravox.sh` (the enabled_languages convergence
  step), the IntraVox engine's `LanguageService` (`DEFAULT_ENABLED_LANGUAGES`) and its
  `Version001600Date20260609000000` migration seed.

## Context

Phase 41 used to converge `occ config:app:get/set intravox enabled_languages` to
`["es","en"]` on every seed: the engine's unset-key default was upstream's legacy
`['nl','en','de','fr']` (the pre-1.6.0 upgrade-safety contract), so es — the instance's
only content language — was not in the set the admin UI and several engine flows consulted.
The convergence step was the deprecated write of a deprecated model:
`LanguageService::getEnabledLanguages()` is marked `@deprecated` ("a language is active
when it has content… the config key is no longer written by the admin UI"), and gestion
was its last writer.

## Decision

The engine owns the deployment's language reality; gestion stops converging the key.
The engine's unset-key default and the Version001600 seed are `['es','en']` — es, the
single content language the deployment writes in, plus en, the non-removable engine
floor (M4 es-only KISS: «we will just write in Spanish in es, we do not need the rest of
languages»). This supersedes (each superseded wording is preserved below; the engine's
companion docblock rewrites record the same supersession in place):

- the phase-41 convergence step's rationale ("upstream's enabled-languages default is
  de,en,fr,nl — es is absent") — superseded by the engine default itself offering exactly
  es+en;
- Version001600's 1.6.0 upgrade contract (fresh installs must see the four pre-1.6.0
  languages) — the app shipped 2026-09-25, no install ever carried that set, and the
  vendor/upstream surface is deferred by the same class as the es demo data (L1-15).

The deprecated key keeps its legacy readers working unchanged; existing installs keep
their stored value (the lab box: `["es","en"]` — identical to the new default, so nothing
moves). A fresh clinic gets es+en from the engine (const default + migration seed) with no
gestion step.

## Consequences

- Phase 41 no longer writes app config for languages; its only remaining convergence
  concerns infrastructure (groupfolder, groups, grants). Seed-idempotence loses one write
  verb.
- Feed/footer/admin-grid flows that consult `isLanguageEnabled('es')` are correct on
  fresh installs without the seam write (they previously degraded es-profile users to
  'en').
- The engine's multi-language capability stays dormant: content exists only where
  provisioned (es), reads derive served languages from real content, and en remains the
  engine's never-materialized fallback floor — not a deployment language.
