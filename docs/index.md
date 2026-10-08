# Documentation index — APS Conecta Gestión

Where each document lives, what mode it is written in, and which facts it is the authority for. One
page, one mode: nothing here mixes a tutorial with a reference. When two documents seem to state
the same fact, the one named here as its authority wins and the other should link instead.

## Start here

| Document | Mode | Reader | It is the authority for |
|---|---|---|---|
| [`README.md`](../README.md) | how-to + reference | developer | How to stand the **dev stack** up, and what a release pins; the clinic install lives in INSTALLER.md |
| [`INSTALLER.md`](INSTALLER.md) | how-to | operator | **How to stand a clinic up** (the AIO installer: preflight, wizard, Provisionador, timers, backups, the map, updates) |
| [`GUIA-CLINICA.md`](GUIA-CLINICA.md) | how-to (Spanish) | operator | The same clinic walkthrough in the operator's language — the eight manual-QA scenarios and the credentials ritual |
| [`CONTEXT.md`](../CONTEXT.md) | reference | everyone | **The vocabulary.** Product identity, clinic identity, screens, releases, the four kinds of app |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | how-to | contributor | **The documentation doctrine** every repository in the organisation inherits, and how work is run and reviewed |
| [`AGENTS.md`](../AGENTS.md) | reference | agent, developer | The repo rules an AI agent must follow, and the invariants |
| [`ORG-MAP.md`](ORG-MAP.md) | reference | everyone | **Which repository owns what**, why two live inside another, which decisions were reversed, and what has no owner |

## Explanation — why it is built this way

| Document | Mode | Reader | It is the authority for |
|---|---|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | explanation | developer | The stack and its boundaries |
| [`threat-model.md`](threat-model.md) | reference | developer | What an attacker wants, the entry points and their guards; the Breaker agent starts here |
| [`THEMING-MODEL.md`](THEMING-MODEL.md) | explanation | developer, designer | How branding reaches a screen, including the ones drawn before the apps load |
| [`LICENSING.md`](LICENSING.md) | reference | developer | Our own licence, every third-party licence the stack runs, and whether any obligation reaches our code |
| [`CONTRACTS.md`](CONTRACTS.md) | reference | developer | What app A may consume from app B — every cross-module surface with an owner and a stability status |
| [`adr/`](adr/) | explanation | developer | Decisions, and the reasoning that was live when each was taken |

## The operator manuals

The three-manual set lives under [`manuals/`](manuals/) — moved under version control
(org L8-03) after shipping as an unversioned orphan at the org root. One page per audience:

| Document | Mode | Reader | It is the authority for |
|---|---|---|---|
| [`manuals/USER_MANUAL.md`](manuals/USER_MANUAL.md) | how-to (Spanish) | staff | Healthcare staff operations — the screens, the rituals, in the operator's language |
| [`manuals/DEVELOPER_MANUAL.md`](manuals/DEVELOPER_MANUAL.md) | reference | developer | Developer reference — topology, app taxonomy, theming, licensing |
| [`manuals/ADMIN_MANUAL.md`](manuals/ADMIN_MANUAL.md) | reference | operator | Server administration — the orchestrated topology and its operational boundaries |

`manuals/README.md` is the suite's own cover page and carries the brand stylesheet
(`manuals/style.css`); the screenshots it embeds live beside it.

## Operating runbooks

| Document | Mode | Reader | It is the authority for |
|---|---|---|---|
| [`MIGRATION.md`](MIGRATION.md) | how-to | operator | Migrating the pilot to the AIO stack, rehearsal-first |
| [`WELCOME-SCREEN.md`](WELCOME-SCREEN.md) | how-to + reference | operator, editor | The welcome tree — what phase 41 seeds, when, and how to edit it |

## Reference and how-to for one directory

| Document | Mode | Reader | It is the authority for |
|---|---|---|---|
| [`../apps/README.md`](../apps/README.md) | reference | developer | What may live in `apps/`, and the difference between a vendored, own and lab app |
| [`../provisioning/README.md`](../provisioning/README.md) | reference | operator, developer | The provisioning phases and their order |
| [`../themes/README.md`](../themes/README.md) | reference | developer | The server theme directory |
| [`CONVENTIONS.md`](CONVENTIONS.md) | reference (Spanish) | staff | *Spanish, staff-facing.* The shared folder structure a clinic works in |
| [`BRANDING.md`](BRANDING.md) | how-to | operator | The `occ` keys that apply the brand |
| [`../themes/apsconecta/MAPEO.md`](../themes/apsconecta/MAPEO.md) | reference | designer | Brand-kit token mapping |

`CONVENTIONS.md` is Spanish deliberately, because clinic staff read it; [`AGENTS.md`](../AGENTS.md)
owns the rule.

## Status and history

| Document | Mode | Reader | It is the authority for |
|---|---|---|---|
| [`../CHANGELOG.md`](../CHANGELOG.md) | history | operator | What changed in each installable version |
| [`../ROADMAP.md`](../ROADMAP.md) | status | everyone | What is planned and what is done |
| [`../BUGS.md`](../BUGS.md) | history | developer | Known defects |
| [`../CONTRIBUTORS.md`](../CONTRIBUTORS.md) | reference | everyone | Who has access — a record, not a roster of invitations |

## A note on the ADR numbers

Numbers are never reused and never renumbered, so the series has permanent gaps. **0006, 0008 and
0009 do not exist and never will:** `0007` and `0010` arrived from the Site's repository in 2026-08-08
keeping the numbers they were cited by, because renumbering them would have broken every reference
that already pointed at them ([ADR-0011](adr/0011-org-wide-facts-live-in-gestion.md)). Three missing
files would otherwise read as three deletions.

`0013` arrived the same way from `epidemiologia` on 2026-08-09, but **took a new number**: unlike
`0007` and `0010`, its old number was already taken here. Its old address keeps a stub, and `0003`
in this series remains a different decision — five repositories have an `ADR-0003` and no two are
the same, so a citation of one names its repository.

`ADR-0000` is not a decision. It defines the `AD-1`…`AD-10` decisions that predate the ADR series and
are cited throughout the code, so that a reader meeting `AD-2` in a shell comment can find out what it
requires.

Org-wide decisions live here; a decision about one product lives in that product's repository. A
reference that crosses a repository boundary is an absolute URL, never a relative path.
