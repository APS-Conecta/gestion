# ADR-0005 — `main` is the development trunk; a release is a tag

- **Status:** accepted (2026-08-08)
- **Affects:** `CONTRIBUTING.md`, `README.md`, `CONTEXT.md`, `AGENTS.md`, `docs/ARCHITECTURE.md`
  (added 2026-08-08 — the design SSOT had no mention of this decision, and the omission from this
  list is why), `dev/lab-apps.sh`,
  `provisioning/phases/12-apps.sh`, `provisioning/seed.sh`, `scripts/divergence.sh`,
  `scripts/test.sh`, `.github/workflows/cleanboot.yml`

## Context

The question that produced this ADR was "gestion is production, we should develop the apps
somewhere else". Measuring the repo said otherwise on both halves.

**gestion is not production.** `sites/los-castanos/site.sh` sets `SITE_DOMINIO=""` — *"Empty = local
dev"* — the production posture is #75 and unbuilt, and no clinic runs this. gestion is the dev stack.

**Development is already outside this repo's history.** `git ls-files apps` returns **one** file
(`apps/README.md`). App clones, their `node_modules` and every experiment have never been committed
here. Of 108 tracked files, ~85 are the product and ~23 are process docs.

So the thing actually missing was not separation. It was an **address**: `git tag` returned nothing.
Every app gestion ships is pinned by version and sha256, and gestion itself had no version at all —
a clinic would have installed whatever `main` happened to be that day, and a bug report could not
have named the bytes that produced it.

A second, smaller gap sat beside it: an app of ours under development had nowhere to be *declared*.
`ensure_own_app` (ADR-0003) already leaves a git checkout alone, so running one worked — but
`make divergence` reported it as drift on every run, which is how a report stops being read.

## Decision

**`main` is the trunk. A release is a tag plus a GitHub Release, and that tag is what a clinic
installs.** No `develop` branch, no `production` branch, no second repository. GitFlow's branch model
exists to support several shipped versions at once; there is one clinic and no back-versions to
patch, so branches would buy nothing and cost merges. A branch is also a moving pointer — it cannot
answer "which bytes does that instance have?" — and a tag can.

`provisioning/seed.sh` prints `git describe --tags --always --dirty` in its header, so a run says
which gestion produced it. **No `VERSION` file**: it would only be a second copy of what the tag
already says, free to drift from it.

**Apps of ours under development are "lab apps", declared in `dev/lab-apps.sh`.** That file is
**tracked and inert** — the posture `compose.dev.yaml`, `Dockerfile.dev` and `dev/xdebug.ini`
already use here. `12-apps.sh` sources it and acts on an entry **only where `apps/<id>/.git`
exists**, so a clinic reads the file and falls through. `divergence.sh` reads it as a third
inventory beside `APPS` and `OWN_APPS`.

Clones live under `gestion/apps/<id>`, which retires the sibling `custom apps/` drawer. A symlink
was never an option: `apps/` is a bind mount, so a symlink to a target outside it dangles inside the
container.

**Our own apps are pinned at a milestone, not at every tag.** gestion took six `epidemiologia` bumps
in the week to 2026-08-05 (#137–#141), each a permanent ~570 KB blob — that is gestion acting as the
app's CI. It now pins the version it decided to ship.

## Considered options

- **A `production` branch, or a second repository.** Rejected. Measured, the production repo would
  be ~85 identical files with a second history — the shape ADR-0003 already rejected for apps — and
  a branch answers "what is live?" with "whatever it points at right now".
- **A gitignored lab inventory** (`provisioning/apps.local.sh`). Rejected: it dies with the working
  tree, cannot be reviewed, and a fresh clone bootstraps nothing. This repo was deleted once and
  survived only on GitHub's 90-day restore window. "These five apps are under development" is a
  shared decision, not a machine-local secret; secrets stay in `.env`.
- **Splitting `themes/` into its own repo with a pinned tarball.** Rejected on measurement: 18
  commits, every one issue-linked, no untracked cruft, bind-mounted so already live-editable, and
  byte-identical on every clinic but for the generated `--aps-clinic`. Rules about independent
  lifecycles do not apply to something with one consumer.
- **A stale-pin reporter for our own apps.** Deferred, not rejected. `scripts/app-versions.sh`
  excludes them because they are not in the NC34 store index, so under milestone pinning nothing
  reports a fossil. Four lines close it when it matters: `git ls-remote --tags` against the URL
  `OWN_APPS` and `LAB_APPS` already carry. One developer today; this is cheap to add and cheaper to
  skip.

## Consequences

- **A clinic install now has a name.** `git clone --branch vX.Y.Z`, and `make install` logs which
  release it is converging.
- **The `.git` test in the lab loop is load-bearing, and was proved so rather than asserted.** With
  the line removed and the clone hidden, phase 12 died with
  `FAILED territorio — no vendored tarball in provisioning/apps/territorio/` — i.e. every clinic
  install. `ensure_own_app` keeps its fallthrough to `ensure_vendored_app`, which is correct for the
  apps we do ship; the guard belongs at the lab call site.
- **`dev/**` joined `cleanboot.yml`'s path filter.** `12-apps.sh` sources `dev/lab-apps.sh`, so a
  syntax error there kills a clean install even though the file is inert — it is part of the install
  path now, and `dev/*.sh` joined `scripts/test.sh`'s lint sweep for the same reason.
- **`apps/` roughly doubled, to ~1.3 GB**, since both clones carry `node_modules`, and
  `fix-mount-perms` chowns it on every `make up`. Recorded rather than hidden;
  `rm -rf apps/<id>/node_modules` when not building that app.
- **`maps` and `news` left the shipped set** in the same change (−25 MB). Not part of this decision
  and easily reversed, so no ADR of its own: geography is Territorio's, by that repo's ADR-0001, and
  epidemiologia now carries the feeds `news` was there for.
