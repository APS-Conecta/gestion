<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0007 — Org-wide decisions live in this repository; cross-repo references are absolute URLs

Accepted, 2026-08-08.

## Context

The organisation's licence decision is one rule for every code repository, and other repositories cite it. A
filesystem-relative path across repositories depends on where each clone sits, and depth is machine-local: any
reference whose correctness depends on it is broken by construction, and only accidentally right where two
clones happen to be siblings.

Bare numbers fail the same way. An ADR number is unique inside a repository and meaningless outside one.

## Decision

1. **An org-wide decision lives in this repository's `docs/adr/`.** A decision about one product stays in that
   product's repository.
2. **Any reference crossing a repository boundary is an absolute `https://github.com/APS-Conecta/…` URL.**
   Never a relative path. A relative path may only address a file in its own repository.
3. **An ADR cited outside its own repository is named with that repository**: "territorio ADR-0021", never a
   bare "ADR-0021".
4. **Numbers are never reused and never renumbered.**

## Consequences

- Cross-repo references do not depend on where anyone cloned anything. They are checkable by a machine with
  network access and no sibling directory, which is what CI is.
- A cost, accepted: an absolute URL pins `main`. A reader on an old tag follows a link and gets today's
  document, where a relative path would have given them the contemporaneous one. A release is a tag of this
  repository alone and the other repositories are not tagged with it, so there is no contemporaneous cross-repo
  path to preserve.
