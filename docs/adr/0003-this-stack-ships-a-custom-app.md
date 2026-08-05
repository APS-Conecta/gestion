# ADR-0003 — This stack ships a custom app, from its own repository

- **Status:** accepted (2026-08-03)
- **Reverses:** [AD-1](0000-inherited-decisions.md) — *"v1 ships no custom app; config-as-code only"*
- **Does not touch:** [AD-9](0000-inherited-decisions.md) — see *Consequences*
- **Affects:** `provisioning/phases/12-apps.sh`, `provisioning/lib.sh`, `scripts/divergence.sh`,
  `.gitignore`, `docs/ARCHITECTURE.md`, `apps/README.md`, `README.md`

## Context

AD-1 said the v1 scope is a *configured* Nextcloud rather than a *programmed* one, and that `apps/`
carries no committed app. That was true when it was written and it is **false now**: the
`epidemiologia` app has been running on this instance since 2026-08-01 and was at 0.4.0 when this was
written — a Nextcloud 34 app with its own repository, 66 unit tests, an OCS contract and a daily
background job. `VENDOR` carries the version now; this line is not kept up to date.

The repo did not notice. Before this ADR, `grep -ri epidemiolog` over the tracked tree returned
**zero matches**, while `make divergence` reported the opposite from the running instance:

```
app 'epidemiologia' is unpacked in apps/ but not in APPS
  — provisioning will not reproduce it on a clean install
```

That is the concrete cost, and it is not documentation tidiness: **`make install` on a clean machine
produces an instance without the app**, silently, because nothing declares it.

## Decision

**This stack ships a custom app, and provisioning installs it.** AD-1 is reversed, not clarified —
its premise ("no custom app") no longer describes reality, so narrowing it would be fiction.

**The app ships as a tarball, exactly like every other app here** — `provisioning/apps/epidemiologia/`
holds exactly one `epidemiologia-<version>.tar.gz` (~550 KB) and a `VENDOR` file pinning version,
sha256 and the tag it was built from. **An install needs no network, no git and no GitHub**, which is
the property the whole `#98` design exists to protect and there is no reason our own app should be
the exception.

The tarball is *built*, not downloaded, because there is no upstream to fetch from. The exact command
lives in that `VENDOR` file beside the pin it produces, so a bump edits one place rather than two —
this ADR deliberately does not repeat it.

`git archive` exports the tracked tree, so the 288 MB of `node_modules` and 14 MB of `tools/` that
sit in a developer's checkout are simply absent — they are gitignored in the app's repo. `gzip -n`
keeps the mtime out of the header, so rebuilding the same tag reproduces the same bytes and the
pinned sha256 stays checkable.

**The one real difference from a third-party app is the development machine.** There, `apps/<id>` is
not an unpacked tarball but a live git clone with uncommitted work in it, and `ensure_vendored_app`
clears the directory before unpacking — which would be `rm -rf` over a working tree.

So `ensure_own_app` **dispatches on a fact rather than a flag**: does `apps/<id>/.git` exist?

| | `.git` absent — a server | `.git` present — a developer |
| --- | --- | --- |
| What happens | hands off to `ensure_vendored_app`: pinned sha256, re-imposed, schema reconciled | checks the version, runs `occ upgrade` if it moved, **never overwrites** |
| Why | reproducibility: the same seed must produce the same instance (#117) | `make seed` must never discard someone's work in progress |

Nobody has to remember to set anything, and the wrong branch is not reachable by forgetting. The
`OWN_APPS` entry carries a clone URL, but **nothing in an install fetches it** — it is only printed,
to tell a developer where the code lives.

`scripts/divergence.sh` reads both inventories, so the check that found this stays able to find the
next one.

## Considered options

- **Clone from GitHub at install time**, with no tarball at all. **Tried first and rejected**: it
  makes a clinic install depend on git being present, on network egress to GitHub, and on that
  repository staying reachable — three new failure modes for a server that is meant to come up from
  the bytes in this repo. It also cannot be pinned: a tag can move. The whole reason `#98` stopped
  the installer contacting the app store applies here word for word.
- **Re-impose the working tree from git on every seed**, mirroring `ensure_vendored_app`
  unconditionally. Rejected: on a development machine `make seed` would `rm -rf` a live checkout.
  Re-imposition is right for bytes that came from a tarball and wrong for a working tree, which is
  why the dispatch above exists rather than a single rule.
- **Commit the app's source into `apps/`** by un-ignoring it. Rejected: the same files would then
  have two histories, and every change would need committing twice. `.gitignore` now says this
  explicitly so nobody "fixes" it that way.
- **Leave AD-1 and note the exception in prose.** Rejected: three documents and a `.gitignore`
  comment already assert the opposite of what is running. A rule that the practice contradicts is
  worse than no rule, because a reader believes it.
- **Serve the app from a self-hosted app store** (`appstoreurl` plus static `apps.json`). Not
  rejected, deferred — it is the documented way to get install and update *through the UI*, and it
  is cheap here because nothing in provisioning contacts the store (`12-apps.sh:8`). It becomes
  worth doing when updating the app stops being the job of whoever writes it, or when a second
  clinic exists. Recorded in the app's #21.

## Consequences

- **`make install` on a clean machine needs nothing but this repo.** The tarball is committed, so a
  clinic server with no git and no internet still gets the app. That is the point of the change.
- **Releasing the app is now two steps, not one.** Tag it, then rebuild the tarball and update all
  three `VENDOR` lines together — the same discipline the third-party apps already carry. If the
  tarball and `VENDOR` stop describing each other, `ensure_vendored_app` refuses on the sha256 check
  rather than installing something nobody chose.
- **Cost in the repo: 532 KB per release**, and a full copy per bump, recorded here rather than
  hidden — the same accounting `12-apps.sh` already does for the ~61 MB of third-party tarballs.
  Ours is the cheapest thing in `provisioning/apps/` by two orders of magnitude: `git archive`
  exports the tracked tree, so no `node_modules` and no toolchain.
- **On a development machine nothing changes.** `apps/epidemiologia` stays a git checkout, `make seed`
  reports its version and leaves it alone, and a `git pull` followed by `make seed` is enough — the
  phase notices the version moved and runs `occ upgrade` itself.
- **AD-9 is untouched and worth restating**: this app reaches Nextcloud only through `OCP\…`, and
  core is not patched. The app's own `AGENTS.md` and its ADRs keep it that way. Reversing AD-1 says
  a custom app exists; it says nothing about how it may reach the platform.
- **The no-backup posture is unaffected.** Everything the app holds is a cache of public MINSAL and
  ISP pages, re-derivable in one refetch, so it adds nothing that would need backing up — which is
  the property `ARCHITECTURE.md` calls load-bearing elsewhere.
- Three statements in this repo were false the moment the app started running and are corrected in
  the same commit: `docs/ARCHITECTURE.md` ("zero custom PHP in v1"), `apps/README.md` ("v1 ships
  none (AD-1)") and `README.md` ("No custom app lives here yet"), plus the `.gitignore` comment that
  cites AD-1.
