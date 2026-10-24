<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0008 — Only the generic half of the org defaults is published

Accepted, 2026-08-08.

## Context

The rule is *org before repo*: if every repository wants the file, it belongs in `APS-Conecta/.github`, and a
repo-local copy is justified only where it must differ.

Two constraints decide its shape. The first is ours: everything `.github` serves is world-readable, so hardening
checklists, vault names, bind addresses, host paths and contributor names stay out of it. The second is
GitHub's, verified 2026-08-08:

- Default community health files require the `.github` repository to be **public**; a private one is not
  supported.
- `CODEOWNERS` is **not** among the inheritable files. Neither are workflows or git hooks.
- A repository holding **any** file in its own `.github/ISSUE_TEMPLATE` ignores the organisation's defaults for
  that folder entirely: it is all or nothing per folder, not per file.

So the honest question is not whether to be DRY. It is which documents can be both *shared* and *public*,
because those are different tests and a document has to pass both.

## Decision

**Publish from `.github`** — generic, written for a stranger:

- `CONTRIBUTING.md`: how work is run, reviewed and tracked. No host paths, no infrastructure.
- `SECURITY.md`: the reporting route only — where to report and what to expect.
- `ISSUE_TEMPLATE/` and `PULL_REQUEST_TEMPLATE.md`: mechanical, identical everywhere by definition.

**Keep per-repo, and private** — anything a stranger should not be handed:

- Security **posture**: the 2FA, secret-scanning and Dependabot checklist stays in each repo's own
  `SECURITY.md`, because it describes what is switched on rather than how to reach a maintainer.
- Any document naming a host path, a volume, an internal address, or a contributor.

**Keep per-repo because GitHub cannot inherit them** — `CODEOWNERS`, `.githooks/pre-commit`.
(`.github/workflows/docs.yml` once sat beside them, as the vendored docs checker's runner; it left every
repo with the checker itself — the docs-SSOT S2a wave — and no workflow is inheritable either way.)
Their `canon-drift` findings are per-repo work
and will never be closed by an org default. This is a mechanical fact, not a preference.

## Consequences

- Each published document is written as if a stranger will read it, because one will.
- A repository that must differ keeps a local copy, and the local copy wins the lookup. That is the rule's
  escape hatch and it stays.
- This repository kept its own issue forms, so it inherited **nothing** from `ISSUE_TEMPLATE` — until the
  docs-SSOT S2a wave removed the per-repo forms and the pull-request template entirely: the org defaults in
  `APS-Conecta/.github` serve them now, and the folder inherits everything. GitHub's all-or-nothing rule for
  that folder is what made the removal all-or-nothing; the files were the decision, not the rule.
- Two `SECURITY.md` documents have different jobs: the public one routes a report, the local one states
  posture. Neither may drift into the other's territory, and the split is the reason the public one can exist
  at all.
- **`.github` carries the same `LICENSE`**, byte for byte. [ADR-0006](0006-agpl-across-the-org.md) does not name
  it, and a repository with no licence is all-rights-reserved by default. On a repository that publishes
  documents the organisation asks other people to work from, an unstated posture is the one place ambiguity
  costs something.
