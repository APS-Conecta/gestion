<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Agent Guidelines for APS Conecta Gestión

Instructions for AI coding agents operating on this repository. Read them before generating
any code, commits, or pull requests.

This is APS Conecta's hard fork of [Nextcloud
All-in-One](https://github.com/nextcloud/all-in-one), maintained for Chilean
primary-healthcare clinics. It is **not** produced by, affiliated with, or endorsed by
Nextcloud GmbH (the full attribution lives in `readme.md`'s declaration block). Upstream's own
contribution files (`AI_POLICY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, the `.github`
templates) are carried as upstream ships them; the rules below govern work on this repository.

## The one-tree doctrine

`main` is ONE tree: upstream's history plus the fork's changes as committed bytes. There is
no patch queue, no mirror-parity fence, no replay machinery, no `upstream` remote, no
`aps/main` branch. An upstream release arrives the way every upstream change arrives: a
deliberate merge into `main`, merged with a merge commit (never a squash) so `main` records
Upstream as a parent, then an ordinary release (`aps/RELEASING.md` owns the ritual).
Every path where the tree differs from Upstream is a line of `aps/keep-list.txt` with its
reason; the merge moves the Keep-list's base to the new tag.

- NEVER force-push `main` — it is append-only; rollback is a revert.

## The gates

- `.github/workflows/ci.yml`, on every push and PR: the PR-title check, the secret scan (the
  pinned gitleaks over the full history), the static gate, `scripts/test.sh` — the shell
  lint over the fork's own scripts (`bash -n`, shellcheck's errors, the comm tripwire that
  keeps every tracked script in the sweep, the errexit arm), the SPDX-header arm and
  `python3 scripts/images.py --self-test` (hermetic: fixture inventory, stub registry and
  GitHub, no network) — then its `zizmor over our workflows` step (zizmor at medium severity
  over `ci.yml`, `images.yml`, `release.yml` and `issue-linker.yml`, without upstream's
  `zizmor.yml` and with the online audits), and the Keep-list check:
  `scripts/keep-list-test.py` plants an undeclared difference and a stale entry and must see
  `scripts/keep-list.py` red on each, then `scripts/keep-list.py` compares the tree with the
  Upstream commit `aps/keep-list.txt` names and fails on an undeclared difference or a stale
  entry.
- Upstream's own workflows beside it: codespell, shellcheck, docker-lint and json-validator,
  plus the PHP, Twig, YAML and Playwright checks on their paths. `scripts/validate.sh` runs
  the codespell, docker-lint and json-spec trio against any tree; the release chain runs it
  and the static gate on the tag.

CI is the only mechanical gate; where a behavior is not observable in CI, the check beside
it says so instead of pretending.

A red gate is information: fix the cause, or change the contract deliberately in a commit
that says so — never weaken a check to get a green run.

## Commits

Conventional Commits; the fork's own changes carry the `instalador` scope:

    ci(instalador): CI fails on real breakage, not on moving bytes

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

- `aps/keep-list.txt` — every path where this repo differs from Upstream, with its reason.
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
