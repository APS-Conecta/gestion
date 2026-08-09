# Security policy — APS Conecta Gestión

## Scope

Internal-operations tool for a CESFAM's own staff — one establishment per install, named in that
install's configuration and never in this repository. It holds **no patient/clinical data**;
development uses **synthetic fixtures only**. The `gestion` repository is **private**; only the
organization profile is public.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Use the repo's
**[Report a vulnerability](https://github.com/APS-Conecta/gestion/security/advisories/new)** button (GitHub
Private Vulnerability Reporting) to reach the maintainer privately. One person reads these, so expect a
first response in days rather than hours.

## Intentional local-dev choices (NOT vulnerabilities)

The dev stack runs locally, bound to loopback, with synthetic data. These are **deliberate local-dev
conveniences**, not production weaknesses, and are out of scope for vulnerability reports:

- **Redis without a password** (internal to the compose network, not published).
- Services bound to **`127.0.0.1`** only.

There is no production deployment in this repo. If one is ever built, these must be revisited.

## Secrets & the merge gate

Secret handling (all secrets in the gitignored `.env`, vault = Proton Pass) and the 1-approval
PR gate — including why the free plan can't *enforce* it — are owned by
**[`CONTRIBUTING.md`](../CONTRIBUTING.md)**; see it rather than a second copy here. A local pre-commit guard
(`.githooks/pre-commit`, enabled with `git config core.hooksPath .githooks`) blocks committing secret files.

## Hardening checklist (org & repo settings)

**Owner actions in GitHub settings** (free-tier; verified 2026-07-19), priority order:

### High
- [ ] **Enable Private Vulnerability Reporting** (Repo → Settings → Code security → Private vulnerability
      reporting) so the "Report a vulnerability" button above is active.
- [ ] **Enforce org-wide 2FA** (Org → Settings → Authentication security). Confirm all members are enrolled
      first — members without 2FA are removed when it's turned on.
- [ ] **Secret scanning + push protection on the public `.github` repo** (free for public repos).
- [ ] **Lock repo visibility & deletion to owners** (Org → Member privileges) so `gestion` can't be flipped
      public by accident.
- [x] **Enable Dependabot alerts** on `gestion` (free on private repos; zero config).
- [ ] **Enable Dependabot security updates** — the automatic fix PRs, a *separate* setting from
      alerts. Alerts tell you; updates open the pull request. This line and the one above were one
      checkbox until 2026-08-08, which could not be ticked honestly in either direction because alerts
      were on and updates were off.
- [x] **Enable the local secret-guard hook** on every clone — `.githooks/pre-commit`, enabled with
      `git config core.hooksPath .githooks`. It was committed non-executable in five repositories, so
      git skipped it silently; fixed 2026-08-08, and the docs gate now fails a hook that cannot run.

### Medium
- [ ] **Least-privilege base permission** (org base = Read/None). Grant explicit **Write** per person
      if anyone is added; today the only account with access is the owner.
- [x] **One Owner**: the organisation has one member, who is the owner. Re-check when that changes.
- [x] **GitHub Actions**: landed 2026-07-29 and now the merge gate — do not disable. Workflow
      permissions stay read-only.
- [ ] **Restrict third-party OAuth apps + require approval for fine-grained PATs** at the org level.

### Low
- [ ] Keep the public `.github` repo to the profile README plus the four generic org defaults
      [ADR-0012](../docs/adr/0012-only-the-generic-half-is-published-as-an-org-default.md) allows —
      and nothing that states security posture, a host path, or a person.
- [ ] `.gitignore` catch-alls for `*.pem`, `*.key`, `*.p12`, `id_rsa*`.
- [ ] Quarterly **visibility audit**: `gh repo list APS-Conecta --json name,visibility` — `gestion` private,
      `.github` public.
