<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0014 — Language reality is the engine's es-only default

Accepted, 2026-09-27.

## Context

Phase 41 used to converge `occ config:app:get/set intravox enabled_languages` to `["es","en"]` on every seed.
The engine's unset-key default was upstream's legacy `['nl','en','de','fr']` (the pre-1.6.0 upgrade-safety
contract), so es, the instance's only content language, was not in the set the admin UI and several engine
flows consulted. The convergence step was the deprecated write of a deprecated model:
`LanguageService::getEnabledLanguages()` is marked `@deprecated` ("a language is active when it has content…
the config key is no longer written by the admin UI"), and this repository was its last writer.

## Decision

The engine ([APS-Conecta/IntraVox](https://github.com/APS-Conecta/IntraVox)) owns the deployment's language
reality; this repository stops converging the key. The engine's unset-key default and the Version001600 seed
are `['es','en']`: es, the single content language the deployment writes in, plus en, the non-removable engine
floor (es-only KISS: «we will just write in Spanish in es, we do not need the rest of languages»). This
supersedes two rationales, a supersession the engine's companion docblocks also record in place:

- the phase-41 convergence step's rationale ("upstream's enabled-languages default is de,en,fr,nl — es is
  absent"), superseded by the engine default itself offering exactly es+en;
- Version001600's 1.6.0 upgrade contract (fresh installs must see the four pre-1.6.0 languages): the app
  shipped 2026-09-25, no install ever carried that set, and the vendor/upstream surface is deferred by the same
  class as the es demo data.

The same ownership covers `primary_language`: its unset-or-unavailable default is `es`, not `en`. Nobody writes
that key on a managed install (the admin UI is its only writer; this repository writes nothing), so with an
`en` default every roster user (no `core/lang`) resolved the chain `['en']` and was served an `en` home, tree
and news over es-only content. An admin's explicit choice still wins; `en` stays the engine's floor.

The deprecated key keeps its legacy readers working unchanged; existing installs keep their stored value (the
lab box: `["es","en"]`, identical to the new default, so nothing moves). A fresh clinic gets es+en and an es
primary from the engine (const defaults + migration seed) with no step in this repository.

## Consequences

- Phase 41 writes no app config for languages; its only remaining convergence concerns infrastructure
  (groupfolder, groups, grants). Seed-idempotence loses one write verb.
- The admin grid shows es enabled and primary on fresh installs without a seam write. Reads that resolve
  through the effective-language chain (home, tree, news, page links, comments) serve es to roster users. Feed
  and footer consult `isLanguageEnabled` on the reader's own `core/lang`: correct for es-profile users, but
  roster users with no `core/lang` still get `en` there until the engine consolidates their language source.
- The engine's multi-language capability stays dormant: content exists only where provisioned (es), reads
  derive served languages from real content, and en remains the engine's never-materialized fallback floor,
  not a deployment language.
