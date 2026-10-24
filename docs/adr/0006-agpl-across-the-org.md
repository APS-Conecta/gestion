<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0006 — AGPL-3.0-or-later across the organisation

Accepted, 2026-08-07.

## Context

**The Nextcloud apps cannot be proprietary.** `territorio` and `epidemiologia` each import
`@nextcloud/vue`, which is AGPL-3.0-or-later, and webpack compiles it into the bundles committed under
`js/` and served to staff. They also link `@nextcloud/axios`, `initial-state`, `router` and `l10n`, all
GPL-3.0-or-later. The obligation is inherited from what the apps link; it was never ours to choose.

The AGPL matters here for a reason particular to this project. Section 13 adds a network clause: users who
interact with the software remotely are owed source. A CESFAM intranet is exactly that.

That left a choice between two licences across the organisation, or one. One is achievable, because
WordPress is GPL-2.0-**or-later**: taking the "or later" option to GPL-3.0 makes AGPL-3.0 compatible, so
the website can join the apps rather than the apps splitting off.

## Decision

Every repository is **AGPL-3.0-or-later**: this repository, `territorio`, `epidemiologia`, `common`,
`aps-conecta-web`, `repo-docs`. One identical `LICENSE` file in each.

The identity is protected by **trademark**, not by copyright in the code. The logo, mono logo, lockup and
favicon are carved out under
[`aps-conecta-web/mu-plugins/assets/brand/LICENSE`](https://github.com/APS-Conecta/aps-conecta-web/blob/main/mu-plugins/assets/brand/LICENSE):
all rights reserved, marks reserved as contemplated by AGPL section 7(e), with express permission to use
the software with the marks in place and to name the project. Colour tokens stay under the AGPL: colour
values are functional data and copyright barely reaches them.

This split between code and marks is adopted because a proprietary posture everywhere does not exist,
and because a boundary drawn around four SVG files is a boundary that can actually be policed.

## Consequences

- Anyone who receives the code, or uses it over a network, may request source, modify it and redistribute
  it. In practice the recipients are clinic staff, and honouring this is a matter of handing over a
  repository they can already reach.
- The organisation may not describe its own work as proprietary. It publishes open-source software and
  should say so.
- Anything reused from these repositories in a proprietary project requires a relicence.
- The brand carve-out has to be maintained by hand. A fifth SVG added to
  `aps-conecta-web/mu-plugins/assets/brand/` is covered by the AGPL until someone lists it.
