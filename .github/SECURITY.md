# Security policy — APS Conecta Gestión

## Scope

This is an **internal-operations** tool for a single CESFAM. It holds **no patient or clinical data**;
development uses **synthetic fixtures only**. The `gestion` repository is **private**; only the
organization profile (`APS-Conecta/.github`) is public.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Report it privately to the project owners at
**[NEEDS: contact — e.g. a project email or GitHub private vulnerability report]**. We'll acknowledge and
respond as fast as a 3-person team can.

## Intentional local-dev choices (NOT vulnerabilities)

The dev stack runs locally on each developer's machine, bound to loopback, with synthetic data. The
following are **deliberate local-dev conveniences**, not production weaknesses, and are out of scope for
vulnerability reports:

- Collabora's **self-signed HTTPS** on `localhost:9980`.
- **Redis without a password** (internal to the compose network, not published).
- Services bound to **`127.0.0.1`** only; office images tracked at `:latest` (see `docs/LICENSING.md`).

There is no production deployment in this repo. If one is ever built, these must be revisited.

## Secret discipline

- `.env` and `CREDENTIALS.local.md` are **gitignored** and written **mode 600**; they are never committed.
  `CREDENTIALS.local.md` is generated from `.env` by `make credentials` — see `CONTRIBUTING.md`.
- A **local pre-commit guard** (`.githooks/pre-commit`) blocks committing `.env`, `CREDENTIALS.local.md`,
  and key files, and runs `gitleaks` if it's installed. Enable it once per clone:
  `git config core.hooksPath .githooks`.

## Hardening checklist (org & repo settings)

These are **owner actions in GitHub settings** (free-tier; verified 2026-07-19). Priority order:

### High
- [ ] **Enforce org-wide 2FA** (Org → Settings → Authentication security). First confirm all members are
      enrolled — members without 2FA are removed when it's turned on.
- [ ] **Secret scanning + push protection on the public `.github` repo** (free for public repos) — blocks a
      key from ever becoming world-readable.
- [ ] **Lock repo visibility & deletion to owners** (Org → Member privileges: uncheck "allow members to
      change repository visibilities" and "delete/transfer repositories") — guardrail so `gestion` can't be
      flipped public by accident.
- [ ] **Enable Dependabot alerts + security updates** on `gestion` (free on private repos; zero config —
      distinct from the deferred version-update `dependabot.yml`).
- [ ] **Enable the local secret-guard hook** (above) on every clone.

### Medium
- [ ] **Least-privilege base permission**: org base permission = Read (or None); grant the two devs explicit
      **Write** on `gestion` only.
- [ ] **One Owner**: confirm `juliomosorio` and `mmaartinn` are `member` (not org admin); only `ddespinoza`
      is Owner.
- [ ] **Keep GitHub Actions disabled** until CI actually lands (no workflows exist yet), and pre-set
      workflow permissions to read-only.
- [ ] **Restrict third-party OAuth apps + require approval for fine-grained PATs** at the org level.

### Low
- [ ] Keep the public `.github` repo to **only** the profile README — nothing else.
- [ ] `.gitignore` catch-alls for `*.pem`, `*.key`, `*.p12`, `id_rsa*`.
- [ ] Quarterly **visibility audit**: `gh repo list APS-Conecta --json name,visibility` — `gestion` private,
      `.github` public.

## On the merge gate — an honest limitation

The **1-approval PR gate is a team convention, not an enforced control**: on the GitHub Free plan, branch
protection and required reviews are unavailable for private repos, so anyone with Write access can push to
`main` or self-merge. Our mitigations are `CODEOWNERS` auto-request, the local `make test` + secret-guard
hooks, and team discipline (always PR, never push to `main` directly). Hard enforcement would require a
paid plan (GitHub Team) — a deliberate, deferred trade-off.
