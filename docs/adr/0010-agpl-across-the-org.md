# ADR-0010 — AGPL-3.0-or-later across the organisation

- **Status:** accepted (2026-08-07)
- **Supersedes:** [ADR 0007](0007-proprietary-across-the-org.md)
- **Moved:** 2026-08-08 from `aps-conecta-web/docs/adr/`, keeping its number: an org-wide decision
  does not live in one product's repository ([ADR 0011](0011-org-wide-facts-live-in-gestion.md)).

## Context

[ADR 0007](0007-proprietary-across-the-org.md) put every repository under a proprietary
licence, to stop the visual identity being given away by an MIT `LICENSE` that had been
shipped by mistake. It chose one posture for the whole organisation on the grounds that
"one rule is easier to hold to than a boundary that has to be policed file by file", and
explicitly rejected splitting the licence.

An audit of what the repositories actually link showed that posture was not available.

**The Nextcloud apps cannot be proprietary.** `territorio`, `analizador-rem` and
`epidemiologia` each import `@nextcloud/vue`, which is AGPL-3.0-or-later, and webpack
compiles it into the bundles committed under `js/` and served to staff. They also link
`@nextcloud/axios`, `initial-state`, `router` and `l10n`, all GPL-3.0-or-later. The
obligation is inherited from what the apps link; it was never ours to choose. All three
already declared AGPL in `composer.json` and `package.json`, so ADR 0007 had been
contradicted in practice from the start — `territorio` and `common` simply shipped no
`LICENSE` file at all, which is how it went unnoticed.

The AGPL matters here for a reason particular to this project. Section 13 adds a network
clause: users who interact with the software remotely are owed source. A CESFAM intranet
is exactly that. The obligation is live even though nothing is ever published.

That left a choice between two licences across the organisation, or one. One was still
achievable, because WordPress is GPL-2.0-**or-later**: taking the "or later" option to
GPL-3.0 makes AGPL-3.0 compatible, so the website could join the apps rather than the apps
splitting off.

## Decision

Every repository is **AGPL-3.0-or-later**: `gestion`, `territorio`, `analizador-rem`,
`epidemiologia`, `common`, `aps-conecta-web`, `repo-docs`. One identical `LICENSE` file in
each.

The identity is protected by **trademark**, not by copyright in the code. The logo, mono
logo, lockup and favicon are carved out under
[`aps-conecta-web/themes/apsconecta/assets/logo/LICENSE`](https://github.com/APS-Conecta/aps-conecta-web/blob/main/themes/apsconecta/assets/logo/LICENSE):
all rights reserved, marks reserved as contemplated by AGPL section 7(e), with express
permission to use the software with the marks in place and to name the project. Colour
tokens stay under the AGPL — colour values are functional data and copyright barely
reaches them.

This is the split ADR 0007 rejected. It is adopted now because the alternative it assumed
— proprietary everywhere — does not exist, and because a boundary drawn around four SVG
files is a boundary that can actually be policed.

## Considered Options

**Two tiers: AGPL where obliged, proprietary where free.** `gestion`, `aps-conecta-web`
and `repo-docs` would have stayed proprietary. Gives away nothing not already owed, and
preserves ADR 0007's reasoning intact. Rejected: it leaves two rules and a boundary that
has to be re-checked every time a dependency is added — the exact cost ADR 0007 was trying
to avoid, now attached to the harder question.

**Proprietary everywhere, by removing `@nextcloud/vue`.** Technically the only route to
ADR 0007's stated goal. It means rebuilding every screen in all three apps against raw
APIs and losing `@nextcloud/axios`, `router`, `initial-state` and `l10n` as well — weeks
of work to withhold code that only a single clinic will ever run.

**Keeping the apps AGPL and saying nothing.** The status quo. Rejected because it is what
produced the current state: three apps declaring AGPL in their manifests, two of them
shipping no licence file, and an ADR asserting the opposite.

## Consequences

- Anyone who receives the code, or uses it over a network, may request source, modify it
  and redistribute it. In practice the recipients are clinic staff, and honouring this is
  a matter of handing over a repository they can already reach.
- `gestion` and `repo-docs` were proprietary and are now copyleft. That is a real transfer
  of control, made deliberately in exchange for one rule instead of two.
- The organisation may no longer describe its own work as proprietary. ADR 0007's sentence
  "Nothing APS Conecta publishes may be presented as open source" is reversed: it now
  publishes open-source software and should say so.
- Anything reused from these repositories in a proprietary project later requires a
  relicence — the mirror of the constraint ADR 0007 recorded.
- The brand carve-out has to be maintained by hand. A fifth SVG added to
  `aps-conecta-web/themes/apsconecta/assets/logo/` is covered by the AGPL until someone lists it.
- `repo-docs` enforces the posture: `licence-declaration` fails any repository whose
  `LICENSE`, `appinfo/info.xml`, `composer.json` and `package.json` disagree, and
  `licence-inventory` fails a dependency absent from the notices.
