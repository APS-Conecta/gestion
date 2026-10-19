# Contributing — APS Conecta Gestión

One maintainer works here, owner and developer both (see [`CONTRIBUTORS.md`](CONTRIBUTORS.md)). The
review conventions below are written for more than one person on purpose: they are what makes the
history readable later, and they are the first thing that has to hold if anyone else joins. This file
is the operational contract; keep it current.

Principles, the language split and the data/secrets invariants are defined in
[`AGENTS.md`](AGENTS.md) and bind every contributor and agent.

Cross-repo ADR citations are `repo#ADR-NNNN` (`territorio#ADR-0016`); in-repo citations stay bare. The org-wide contracts index lives in `gestion/docs/CONTRACTS.md`. Cross-repo consumption of any app's surface is a
contract, not a grep accident: the index is the ADR-0011 home for those facts.

## Workflow (GitHub Flow)

1. Branch off `main` (short-lived): `feat/…`, `fix/…`, `docs/…`, `chore/…`.
2. Commit with **Conventional Commits** (`feat:`, `fix:`, `docs:`, `chore:`, `test:`…).
3. Open a PR and review it before merging. With one maintainer that is a **self-review checkpoint**,
   not an approval GitHub can record: it forbids approving your own pull request, and a private
   repository on the free plan cannot have protected branches or rulesets at all
   (`gh api repos/APS-Conecta/gestion/rulesets` → 403, *"Upgrade to GitHub Pro or make this
   repository public"*). So **CI green is the only mechanical gate there is.** Read your own diff as
   if someone else wrote it — that is the entire convention, and nothing enforces it but you.
4. AI-assisted PRs must be **labeled** (`ai-assisted`) and disclose AI involvement in the description.
5. The gate is `make test` (static checks) — run it before opening a PR. CI runs the same script on
   every PR and on pushes to `main` (`.github/workflows/ci.yml`). Nothing here boots a stack: the
   full clean boot is instalador's, and it reads this repository's `main` as the suite's data.

`CODEOWNERS` will auto-request reviewers the day a second account has access; with one owner GitHub
requests nobody, because it never asks a pull request's own author. Prefer small, reviewable PRs.

## Releases (ADR-0005, as the installer split changed it)

`main` is the trunk. A **release** is a tag, and it is cut on **instalador**, not here: gestion's tag
ritual retired when the install half moved (D4), and instalador's one tag packages the content of
this repository at that moment. The runbook is instalador's
[`aps/RELEASING.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/RELEASING.md); what it
asks of this repository:

1. `main` stays releasable: nothing merges without CI green and a review pass.
2. Content (apps, themes, the register, data packages) lands before the release commit. `main` is then
   **frozen** until the tag is pushed (RELEASING §4): the image bake and the package both read it at
   that moment, so a hotfix waits or the tag waits.
3. The release notes live on instalador's Release. [`CHANGELOG.md`](CHANGELOG.md) here is the history
   of the versions gestion itself released, plus an `Unreleased` section; it links rather than repeats.
4. Which app versions a release pins is `provisioning/apps/*/VENDOR`, validated here by
   `scripts/release-manifest.sh --validate`. Name them in the release notes.
5. A clinic installs the signed package ([`INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md) §2).
   Old gestion tags and their Releases stay intact and keep verifying.

**Our own apps are pinned at a milestone, not at every tag.** `epidemiologia` released six times in
one week (#137–#141); gestion bumps when we decide a version is the one to ship. There is no branch
called `production` and no second repository — the tag *is* the production artifact.

## How we track work

Work is tracked on the org **[GitHub Projects board](https://github.com/orgs/APS-Conecta/projects/5)** as
continuous flow — no fixed sprints; we work PR-by-PR. Cards move
**Backlog → Ready → In Progress → In Review → UAT → Done**: the owner fills Backlog, sets Ready priority, and
signs off **UAT** (acceptance); the developers pull from Ready through In Review. File new work as an issue
using the templates in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE) (a technical *Dev task/bug* and a
plain-language *Solicitud*).

## Planning

The design is committed under `docs/` (architecture in `docs/ARCHITECTURE.md`); status narrative in
`ROADMAP.md` — the repo is the SSOT, GitHub is its mirror.

## Local dev environment

Portable, machine-agnostic Docker Compose (Nextcloud 34 + PostgreSQL 18 + Redis 8) with Xdebug, VS Code
config, and a `Makefile`; each dev runs it **locally**. The step-by-step quickstart and the full `make`
reference live in **[`README.md`](README.md#quickstart)** — one owner per fact; don't duplicate them here.
Two invariants when you touch the stack: nothing VPS-specific or absolute-pathed in the core compose
(`host.docker.internal` must work cross-OS), and **all desired state goes through instalador's provisioning** — never
hand-click config into the running instance (AD-2).

**Secrets:** all passwords live in your gitignored `.env`, created by `make setup` — that file is
the whole list, and the canonical vault is **Proton Pass**. Never commit it.

`grep -v '^#' .env` if you want them on one screen. There is deliberately no target that renders
them into a file: a second copy only adds a place to leak from (the `make credentials` sheet was
deleted 2026-07-29 after one was pasted into a chat transcript).

Rotating the admin password: `.env` is read at INSTALL time only, so editing it does not change an
existing account. Reset it in Nextcloud first, then update `.env` to match:

```bash
NEW="$(openssl rand -hex 20)"        # hex: never contains the '$' Compose would interpolate
docker compose exec -T --user www-data -e OC_PASS="$NEW" nextcloud \
  php occ user:resetpassword --password-from-env admin
```

## Documentation rules

Docs must let someone **rebuild** the system, not just read about it. When you write or change a doc:

1. **Numbered steps, one action each** — the exact copyable command.
2. **Every step states its expected output and what to do if it fails.** A step you can't verify isn't one.
3. **Every command says where it runs** — host, or which container and as which user.
4. **Never assert what you haven't run.** If it's untested, the doc says so *there*, not in a preface.
5. **One owner per fact.** Others link; they don't repeat. A second copy desyncs the day it's written.
6. **Prefer generated over hand-written** (e.g. `make help` is the target list; don't copy it).
7. **Don't copy a gate's count into prose** — say what the gate *proves*; let it print the number.

And the guard that keeps it honest: **if a doc mentions something retired, it must acknowledge somewhere that
it is** (dated history is exempt; its date is the label). Dated history means **ADRs, `CHANGELOG.md`,
`BUGS.md` and `ROADMAP.md`** — the same four `repo-docs` exempts mechanically, named here so the two
cannot drift. They did: this line said "ADRs, changelogs" while the tool also exempted bug logs, and
`BUGS.md` relied on that exemption to name a retired `make` target.

### What the docs gate does not govern

`repo-docs` checks `*.md` and `*.markdown` (`tracked_md`). **`VENDOR` files, `Makefile` comments and
comments inside shell and PHP are outside that corpus**, deliberately: the corpus is what a reader
is pointed at, and widening it to every comment in the tree would make the gate a linter for prose
nobody navigates by.

The cost is real and has been paid once. `provisioning/apps/calendar/VENDOR` described its own size
*"after maps"* for the whole time `maps` did not exist (#172) — the retirement rule above applies to
it, and nothing could enforce it. **So the rule for these files is the rule for code comments: a
comment that names something retired is a defect, caught in review, not by a gate.** Prefer to
write one that cannot rot — measure a file against itself, not against a sibling that may be
dropped.

## Reference docs

Pull current docs from **Context7 MCP** (never hardcode) — see the table in [`README.md`](README.md).
