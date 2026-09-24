# ADR-0017 — metavox deferred; alert expiry is editorial

- **Status:** accepted (2026-09-24, with this plan's approval).
- **Affects:** the welcome screen's avisos workflow (`provisioning/intravox/es/noticias/`),
  `ROADMAP.md` entry #4, future vendoring decisions.

## Context

The IntraVox ecosystem ships a metavox companion that automates content lifecycle — publication
expiry dates, auto-unpublish. The welcome screen's alert block (avisos) is the surface that would
consume it: avisos are the content type with a natural lifetime (campaigns, deadlines, schedule
changes), and a stale aviso that nobody unpublished is exactly the rot an intranet dies of.

Design decision D6 weighed it: pilot aviso volume is a handful per week, every aviso has a named
publisher, and the editorial guide (`como-publicar`) makes the expiry duty explicit — an Editor
flips the aviso back to draft when it lapses. Vendoring metavox for that volume adds a second
engine to operate, license, and keep current for a duty one person can carry in minutes a week.

## Decision

**No metavox.** Avisos expire editorially: the duty is written into the seeded editorial guide
(flip to draft when lapsed; review weekly) and modelled by the seed `aviso-ejemplo`, whose body
explains the same rule. This is a deferred adoption, not a rejection.

**Adoption trigger** (ROADMAP #4): the pilot reports missed unpublishes, or aviso volume grows
past what manual flips can carry. Then: vendor metavox, pin `publication_expiration_date_field`,
and backfill expiry dates on live avisos — no content migration is needed, which is why deferring
is cheap now rather than expensive later.
