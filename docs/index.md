# Documentation index — APS Conecta Gestión

Where each document lives, what mode it is written in, and which facts it is the authority for. One
page, one mode: nothing here mixes a tutorial with a reference. When two documents seem to state the
same fact, the one named here as its authority wins and the other should link instead.

## Start here

| Document | Mode | It is the authority for |
|---|---|---|
| [`README.md`](../README.md) | how-to + reference | How to stand the stack up, and what a release pins |
| [`CONTEXT.md`](../CONTEXT.md) | reference | **The vocabulary.** Product identity, clinic identity, screens, releases, the four kinds of app |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | how-to | **The documentation doctrine** every repository in the organisation inherits, and how work is run and reviewed |
| [`AGENTS.md`](../AGENTS.md) | reference | The repo rules an AI agent must follow, and the invariants |

## Explanation — why it is built this way

| Document | It is the authority for |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The stack and its boundaries |
| [`THEMING-MODEL.md`](THEMING-MODEL.md) | How branding reaches a screen, including the ones drawn before the apps load |
| [`LICENSING.md`](LICENSING.md) | Our own licence, every third-party licence the stack runs, and whether any obligation reaches our code |
| [`adr/`](adr/) | Decisions, and the reasoning that was live when each was taken |

## Reference and how-to for one directory

| Document | It is the authority for |
|---|---|
| [`../apps/README.md`](../apps/README.md) | What may live in `apps/`, and the difference between a vendored, own and lab app |
| [`../provisioning/README.md`](../provisioning/README.md) | The provisioning phases and their order |
| [`../themes/README.md`](../themes/README.md) | The server theme directory |
| [`CONVENTIONS.md`](CONVENTIONS.md) | *Spanish, staff-facing.* The shared folder structure a clinic works in |
| [`BRANDING.md`](BRANDING.md) | The `occ` keys that apply the brand |
| [`../themes/apsconecta/MAPEO.md`](../themes/apsconecta/MAPEO.md) | Brand-kit token mapping |

`CONVENTIONS.md` is Spanish deliberately, because clinic staff read it; [`AGENTS.md`](../AGENTS.md)
owns the rule.

## Status and history

| Document | It is the authority for |
|---|---|
| [`../CHANGELOG.md`](../CHANGELOG.md) | What changed in each installable version |
| [`../ROADMAP.md`](../ROADMAP.md) | What is planned and what is done |
| [`../BUGS.md`](../BUGS.md) | Known defects |
| [`../CONTRIBUTORS.md`](../CONTRIBUTORS.md) | Who has access — a record, not a roster of invitations |

## A note on the ADR numbers

Numbers are never reused and never renumbered, so the series has permanent gaps. **0006, 0008 and
0009 do not exist and never will:** `0007` and `0010` arrived from `aps-conecta-web` in 2026-08-08
keeping the numbers they were cited by, because renumbering them would have broken every reference
that already pointed at them ([ADR-0011](adr/0011-org-wide-facts-live-in-gestion.md)). Three missing
files would otherwise read as three deletions.

`ADR-0000` is not a decision. It defines the `AD-1`…`AD-10` decisions that predate the ADR series and
are cited throughout the code, so that a reader meeting `AD-2` in a shell comment can find out what it
requires.

Org-wide decisions live here; a decision about one product lives in that product's repository. A
reference that crosses a repository boundary is an absolute URL, never a relative path.
