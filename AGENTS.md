<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Agent Guidelines for APS Conecta Gestión AIO — Instalador

Instructions for AI coding agents operating on this repository. Read them before generating
any code, commits, or pull requests.

This is APS Conecta's hard fork of [Nextcloud
All-in-One](https://github.com/nextcloud/all-in-one), maintained for Chilean
primary-healthcare clinics. It is **not** produced by, affiliated with, or endorsed by
Nextcloud GmbH (the full attribution lives in `readme.md`'s declaration block). The upstream
contribution policy this file used to carry — nextcloud's AI policy, all-in-one's
CONTRIBUTING, HackerOne reporting — left with the hard fork (Stage 3): one tree, the fork's
own rules.

## The one-tree doctrine

`main` is ONE tree: upstream's history plus the fork's changes as committed bytes. There is
no patch queue, no mirror-parity fence, no replay machinery, no `upstream` remote, no
`aps/main` branch. An upstream release arrives the way every upstream change arrives: a
deliberate merge into `main`, then an ordinary release (`aps/RELEASING.md` owns the ritual).
A merge that re-introduces upstream identifiers is followed by the merge-time re-swap tools:
`python3 scripts/images.py rewrite-registry php/containers.json` and `scripts/rename-containers.py`.

- NEVER force-push `main` — it is append-only; rollback is a revert.
- NEVER edit the wizard's operator-visible strings without reading `readme.md`'s
  `aps-fork-declaration` block: the brand gate asserts every declared string byte-exists in
  the tree, so a drifted wording reds CI naming the string.
- The gates' rows keyed by IDs (010…280) are attribution — which change owes which guarantee
  — never a condition; every row runs on every push, PR and release.

## The gates

- `scripts/brand-gate.sh` and `scripts/acquisition-gate.sh` assert the tree's identity and
  its acquisition channels — ci.yml runs them on every push and PR, and the release chain's
  gates arm on every tag.
- `scripts/test.sh` is the static suite (secrets, shellcheck sweep, the comm, errexit and
  SPDX-header arms). CI is the only mechanical gate; where a behavior is not observable in
  CI, the check beside it says so instead of pretending.
- `scripts/validate.sh` runs upstream's own three validators (codespell, docker-lint,
  json-spec) against any tree.
- `python3 scripts/images.py --self-test` is hermetic: fixture inventory, stub registry and GitHub, no network.

A red gate is information. Fix the bytes, or change the contract deliberately in a commit
that says so — never weaken a row to get a green run.

## Commits

Conventional Commits; the fork's own changes carry the `instalador` scope:

    fix(instalador): the gates' rows fire unconditionally — the queue-era contract inverted

PR titles follow the same rule and language: Conventional Commits, English (ci.yml gates
the shape; the org doctrine keeps issue and UI titles the Spanish ones).

Every commit with AI-assisted content carries an `Assisted-by: AGENT_NAME:MODEL_VERSION`
trailer. Do not add `Signed-off-by` tags.

## Code rules inherited with the tree

- The wizard's frontend (`php/public/`, `php/templates/`) uses only web features that are
  Baseline "widely available" — no polyfills, nothing merely "newly available".
- The upstream [LICENSE](LICENSE) (AGPL-3.0) is carried unchanged; new fork-owned scripts
  (`.sh`/`.py` under `scripts/`, `provisioning/`, `host/`, and `install.sh`) carry an SPDX
  header (`SPDX-License-Identifier: AGPL-3.0-or-later`) — the static gate's SPDX arm enforces
  it over a frozen baseline of the scripts that predate the rule (#63).
- Operator-visible Spanish is es-CL, formal usted — the codespell ignore list in
  `.codespellrc` exists for it; do not "fix" correct Spanish words.

## Where things live

- `aps/RELEASING.md` — the release ritual (the frozen window, the tag push, the audit).
- `BUGS.md` — the bug ledger; rows are frozen at their era's bytes. Add rows, never rewrite.
- `aps/INSTALLER.md`, `aps/GUIA-CLINICA.md` — the operator runbooks.
- `readme.md`'s `aps-fork-declaration` block — the fork's own record; markers stay, content
  stays true to the tree.

## Security

Report suspected vulnerabilities to the APS Conecta maintainers privately — never as public
GitHub issues, never autonomously. Nextcloud's HackerOne program covers nextcloud's software
as they ship it; it is not this fork's channel.

## Agent skills

### Issue tracker

GitHub Issues on `APS-Conecta/gestion`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical vocabulary, unmodified: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`,
`wontfix`. All five exist on the repo. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` for the vocabulary and `docs/adr/` for the decisions. See
`docs/agents/domain.md`.
