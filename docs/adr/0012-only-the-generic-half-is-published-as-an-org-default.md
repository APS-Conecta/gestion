# ADR-0012 — only the generic half of the org defaults is published

- **Status:** accepted (2026-08-08)
- **Affects:** `APS-Conecta/.github` (`CONTRIBUTING.md`, `SECURITY.md`, `ISSUE_TEMPLATE/`,
  `PULL_REQUEST_TEMPLATE.md`), `.github/SECURITY.md` here, and the `missing-required` findings in
  `common`, `epidemiologia`, `territorio` and `analizador-rem`

## Context

`repo-docs` enforces a rule called *org before repo*: if every repository wants the file, it belongs
in `APS-Conecta/.github`, and a repo-local copy is justified only where it must differ. The rule has
never once been executed. `git ls-files` in that repository returns **exactly one path**,
`profile/README.md`. Nothing has ever been served to anything.

The result is not neutral. `common` has no `CONTRIBUTING.md`, no `SECURITY.md`, no `CODEOWNERS`, no
pull-request template and no issue forms at all; `territorio` and `analizador-rem` are the same;
`epidemiologia` lacks four of them. Sixty-odd `missing-required` findings across the organisation are
one unimplemented rule.

Two constraints decide the shape of the fix. The first is ours: `.github` is the **only public
repository** of the eight, and everything it serves is world-readable, so `repo-docs` forbids
hardening checklists, vault names, bind addresses, host paths and contributor names there. The second
is GitHub's, verified 2026-08-08:

- Default community health files require the `.github` repository to be **public**; a private one is
  not supported.
- `CODEOWNERS` is **not** among the inheritable files. Neither are workflows or git hooks.
- A repository holding **any** file in its own `.github/ISSUE_TEMPLATE` ignores the organisation's
  defaults for that folder entirely — it is all or nothing per folder, not per file.

So the honest question is not whether to be DRY. It is which documents can be both *shared* and
*public*, because those are different tests and a document has to pass both.

## Decision

**Publish from `.github`** — generic, written for a stranger:

- `CONTRIBUTING.md`: how work is run, reviewed and tracked. No host paths, no infrastructure.
- `SECURITY.md`: the reporting route only — where to report and what to expect.
- `ISSUE_TEMPLATE/` and `PULL_REQUEST_TEMPLATE.md`: mechanical, identical everywhere by definition.

**Keep per-repo, and private** — anything a stranger should not be handed:

- Security **posture**: the 2FA, secret-scanning and Dependabot checklist stays in each repo's own
  `SECURITY.md`, because it describes what is switched on rather than how to reach a maintainer.
- Any document naming a host path, a volume, an internal address, or a contributor.

**Keep per-repo because GitHub cannot inherit them** — `CODEOWNERS`,
`.github/workflows/docs.yml`, `.githooks/pre-commit`. Their `canon-drift` findings are per-repo work
and will never be closed by an org default. This is a mechanical fact, not a preference.

## Considered Options

**Retire the rule and duplicate everything per repo.** Defensible: nothing new becomes public, and
one mental model instead of two. Rejected because it means the same five documents copied across
seven repositories — the precise DRY failure the rule was written to prevent — and because a rule
that never fires should be deleted rather than left standing as a dead letter, which would then be
the third stale instruction in a tool whose whole job is finding stale instructions.

**Publish the full set, including the security posture.** Maximum DRY, one copy of everything.
Rejected: it publishes the hardening checklist of seven private repositories, and `repo-docs`
forbids exactly that in exactly that repository.

## Consequences

- The public surface grows from one document to five. Each is now written as if a stranger will read
  it, because one will.
- A repository that must differ keeps a local copy, and the local copy wins the lookup. That is the
  rule's escape hatch and it stays.
- `gestion` keeps its own issue forms, so it inherits **nothing** from `ISSUE_TEMPLATE` — GitHub's
  all-or-nothing rule for that folder, not a decision made here.
- Two `SECURITY.md` documents now exist with different jobs: the public one routes a report, the
  local one states posture. Neither may drift into the other's territory, and the split is the reason
  the public one can exist at all.
- **`.github` now carries the same `LICENSE`.** [ADR-0010](0010-agpl-across-the-org.md) enumerates
  seven *code* repositories and does not name this one, so it had none — and a repository with no
  licence is all-rights-reserved by default. That was tolerable while it served one page to nobody;
  now that it publishes four documents the organisation asks other people to work from, an unstated
  posture on the only world-readable repository is the one place ambiguity costs something. Same file,
  byte for byte, as the other seven.
