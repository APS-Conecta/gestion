# ADR-0007 — APS Conecta code is proprietary; it consumes open source

- **Status:** Superseded by [ADR 0010](0010-agpl-across-the-org.md) on 2026-08-07 — the proprietary posture was not available; the Nextcloud apps link AGPL code.
- **Moved:** 2026-08-08 from `aps-conecta-web/docs/adr/`, keeping its number, so that it stays beside
  the decision that superseded it ([ADR 0011](0011-org-wide-facts-live-in-gestion.md)).

Everything APS Conecta produces — this Site, its theme, the brand assets, and the Nextcloud apps — is proprietary, all rights reserved, matching `APS-Conecta/gestion`. The dependencies it builds on are open source and self-hosted, with no paid licences. "We use only open source" describes what the project *consumes*, not how it *licences its own work*, and the two are routinely confused.

## What this changes

The theme package at `/srv/syncthing/apsconecta-web` shipped an **MIT** `LICENSE`. MIT grants anyone the right to use, modify, sublicense and sell — applied to a directory containing `aps-logo-primary.svg`, the lockup and the palette, it handed away the visual identity it exists to establish. **Replaced 2026-08-05** with a proprietary licence modelled on `APS-Conecta/gestion`, naming the copyright holder in the singular and explicitly covering the logo files, wordmark and colour system. The third-party notices (SIL OFL fonts, ISC/MIT icons) were kept — they license other people's work, not ours.

Also corrected in the same pass: `style.css` declared `License: MIT` and described the theme as *"Abierto, gratuito"*, and the package carried organisational plural ("el equipo editorial", "escríbenos y lo agregamos", "Quiénes somos") for what is a single developer.

Any repository in the organisation still declaring an open-source licence predates this decision and should be reconciled against it.

## Considered Options

**Splitting the licence** — MIT for code, all-rights-reserved for the logo and wordmark, as Mozilla, Rust and Docker do — was the alternative. Rejected in favour of a single posture across the organisation: one rule is easier to hold to than a boundary that has to be policed file by file, and nothing here is currently offered for reuse.

## Consequences

- Nothing APS Conecta publishes may be presented as open source. The public org profile already says the code is private; that stays accurate.
- Reusing anything from these repositories in an open-source project later requires an explicit relicence.
