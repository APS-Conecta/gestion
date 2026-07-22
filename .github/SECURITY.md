# Security policy — APS Conecta Gestión

## Scope

Internal-operations tool for a single CESFAM. It holds **no patient/clinical data**; development uses
**synthetic fixtures only**. The `gestion` repository is **private**; only the organization profile is public.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Use the repo's
**[Report a vulnerability](https://github.com/APS-Conecta/gestion/security/advisories/new)** button (GitHub
Private Vulnerability Reporting) to reach the maintainers privately. We'll respond as fast as a 3-person team
can.

## Intentional local-dev choices (NOT vulnerabilities)

The dev stack runs locally, bound to loopback, with synthetic data. These are **deliberate local-dev
conveniences**, not production weaknesses, and are out of scope for vulnerability reports:

- **Redis without a password** (internal to the compose network, not published).
- Services bound to **`127.0.0.1`** only; office images tracked at `:latest` (see `docs/LICENSING.md`).

There is no production deployment in this repo. If one is ever built, these must be revisited.

## Secrets & the merge gate

Secret handling (gitignored `.env` / `CREDENTIALS.local.md`, mode 600, `make credentials`) and the 1-approval
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
- [ ] **Enable Dependabot alerts + security updates** on `gestion` (free on private repos; zero config).
- [ ] **Enable the local secret-guard hook** on every clone.

### Medium
- [ ] **Least-privilege base permission** (org base = Read/None; the two devs get explicit **Write**).
- [ ] **One Owner**: confirm the two devs are `member`, not org admin.
- [ ] **Keep GitHub Actions disabled** until CI actually lands; pre-set workflow permissions to read-only.
- [ ] **Restrict third-party OAuth apps + require approval for fine-grained PATs** at the org level.

### Low
- [ ] Keep the public `.github` repo to **only** the profile README.
- [ ] `.gitignore` catch-alls for `*.pem`, `*.key`, `*.p12`, `id_rsa*`.
- [ ] Quarterly **visibility audit**: `gh repo list APS-Conecta --json name,visibility` — `gestion` private,
      `.github` public.
