# ADR-0003 — This stack ships a custom app, from its own repository

- **Status:** accepted (2026-08-03)
- **Reverses:** [AD-1](0000-inherited-decisions.md) — *"v1 ships no custom app; config-as-code only"*
- **Does not touch:** [AD-9](0000-inherited-decisions.md) — see *Consequences*
- **Affects:** `provisioning/phases/12-apps.sh`, `provisioning/lib.sh`, `scripts/divergence.sh`,
  `.gitignore`, `docs/ARCHITECTURE.md`, `apps/README.md`, `README.md`

## Context

AD-1 said the v1 scope is a *configured* Nextcloud rather than a *programmed* one, and that `apps/`
carries no committed app. That was true when it was written and it is **false now**: the
`epidemiologia` app has been running on this instance since 2026-08-01 and is at 0.3.0 — a Nextcloud
34 app with its own repository, 66 unit tests, an OCS contract and a daily background job.

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

The app is installed from **its own git repository**, cloned into `apps/<appid>`, not from a
vendored tarball:

```sh
OWN_APPS="epidemiologia=https://github.com/APS-Conecta/epidemiologia.git"
```

A second inventory beside `APPS`, and a second function beside `ensure_vendored_app`, because the
two kinds of app are installed by **opposite rules**:

| | Vendored (`APPS`) | Ours (`OWN_APPS`) |
| --- | --- | --- |
| Bytes come from | a tarball pinned by sha256 in `VENDOR` | a git repository we control |
| On a version change | **re-imposed** — the instance converges on the repo (#117) | **checked and reported**, never overwritten |
| Why | the app store must never decide what runs here (#98) | `apps/` may hold a working tree someone is editing |

Both then share the parts that are the same and easy to forget by hand: `occ upgrade` when the
installed version and the on-disk version disagree, and `occ app:enable`.

`scripts/divergence.sh` reads both lists, so the check that found this stays able to find the next
one.

## Considered options

- **Vendor a release tarball, like the store apps.** Rejected: it adds a release step and a second
  copy of bytes we already own, and buys nothing here — a tarball's value is pinning code we do not
  control. Recorded in the app's own issue #21 alongside the measurement that a git tree is 2.2 MB
  with no `node_modules`, because `node_modules` and `tools/` are gitignored there.
- **Re-impose the working tree from git on every seed**, mirroring `ensure_vendored_app`. Rejected:
  `make seed` would silently discard uncommitted work in `apps/epidemiologia`. Re-imposition is
  right for third-party bytes and wrong for a working tree.
- **Leave AD-1 and note the exception in prose.** Rejected: three documents and a `.gitignore`
  comment already assert the opposite of what is running. A rule that the practice contradicts is
  worse than no rule, because a reader believes it.
- **Serve the app from a self-hosted app store** (`appstoreurl` plus static `apps.json`). Not
  rejected, deferred — it is the documented way to get install and update *through the UI*, and it
  is cheap here because nothing in provisioning contacts the store (`12-apps.sh:8`). It becomes
  worth doing when updating the app stops being the job of whoever writes it, or when a second
  clinic exists. Recorded in the app's #21.

## Consequences

- **`make install` on a clean machine now needs the clone.** `apps/` is gitignored, so a fresh
  gestion checkout has an empty `apps/`. `ensure_repo_app` fails loudly and prints the exact
  `git clone` command rather than reporting a missing directory.
- **A `git pull` in the app is enough**, followed by `make seed`: the phase notices the version
  moved and runs `occ upgrade` itself. Without that, Nextcloud answers almost nothing until an
  operator remembers the second command.
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
