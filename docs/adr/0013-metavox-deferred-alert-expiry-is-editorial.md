<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0013 — Metavox deferred; alert expiry is editorial

Accepted, 2026-09-24.

## Context

The IntraVox ecosystem ships a metavox companion that automates content lifecycle: publication expiry dates,
auto-unpublish. The welcome screen's alert block (avisos) is the surface that would consume it. Avisos are the
content type with a natural lifetime (campaigns, deadlines, schedule changes), and a stale aviso that nobody
unpublished is exactly the rot an intranet dies of.

Pilot aviso volume is a handful per week, and every aviso has a named publisher. Vendoring metavox adds a
second engine to operate, license and keep current.

## Decision

**No metavox.** Avisos expire editorially: the duty is written into the seeded editorial guide (flip to draft
when lapsed; review weekly) and modelled by the seed `aviso-ejemplo`, whose body explains the same rule. This
is a deferred adoption, not a rejection.

**Adoption trigger:** the pilot reports missed unpublishes, or aviso volume grows past what manual flips can
carry. Then: vendor metavox, pin `publication_expiration_date_field`, and backfill expiry dates on live
avisos. No content migration is needed, which is why deferring is cheap now rather than expensive later.

## Consequences

- An Editor carries the expiry duty, made explicit by the editorial guide (`como-publicar`): flip a lapsed
  aviso back to draft.
- At pilot volume that duty costs one person minutes a week.
