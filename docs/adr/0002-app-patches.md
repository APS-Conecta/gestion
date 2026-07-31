# ADR-0002 — Store apps stay unforked; their edits live as patches in provisioning

- **Status:** accepted, 2026-07-29
- **Clarifies:** AD-5 (what "opt-in" covers)
- **Affects:** `provisioning/phases/12-apps.sh`, `provisioning/apps/`, `provisioning/lib.sh`,
  `Makefile`, `scripts/office-smoke.sh`, `scripts/smoke.sh`

## Context

This instance is going to keep adding store apps, and some of them need edits we cannot get
from configuration. The first is already here: the `eurooffice` connector's admin section name
is a bare PHP literal with no `t()` call, so no locale and no config key can reach it.

Three problems had accumulated:

1. **No inventory.** `groupfolders` was installed by `30-folders`, `side_menu` by `15-branding`,
   `eurooffice` by the `Makefile`. Answering "which apps does this instance run" meant grepping
   three files, and the answer would get worse with every app added.
2. **`apps/` is gitignored** (AD-1), so an app edit cannot be committed, and an app update wipes
   it. The only thing that restores it is re-running whatever made it.
3. **The edit was two `sed`s, and `sed` exits 0 when it matches nothing.** An upstream change to
   either line turned the rename into a silent no-op. That needed a separate gate in
   `office-smoke.sh` to be noticed at all — and this repo has now been bitten five times by the
   same species of silent no-op (BUGS.md B-001, `lib.sh` query-before-set, the TTF swallowing
   woff2 404s, this `sed`, and `app_disable` treating an absent key as "no").

## Decision

**Apps come from the store; the repo holds the patch, never the app.** Vendoring was rejected on
measurement: `eurooffice` alone is 11 MB and 410 files, and committing it pins the version so
store updates stop arriving.

- `provisioning/phases/12-apps.sh` names every app in one `APPS` line and installs them.
- An app needing edits gets `provisioning/apps/<appid>/`, whose `*.patch` files are applied in
  name order. Apps with nothing to patch have no directory — no placeholder files.
- Patches are applied with `patch`, not `sed`. **`patch` fails when its context stops matching**,
  so the silent no-op is gone by construction rather than by a gate placed next to it.
  *(Amended 2026-07-30: this originally said the greps in `office-smoke.sh` "were removed as
  redundant". They were, and then restored — `patch` only gates the moment it is applied, and an
  `occ app:update` reverts the edit with nothing running `make seed` afterwards. The greps assert
  the state of the served files and are load-bearing; do not delete them on this ADR's authority.)*
- `apply_patch` (`provisioning/lib.sh`) distinguishes **three** outcomes: forward `--dry-run`
  succeeds → apply; reverse `--dry-run` succeeds → already applied, continue; neither → upstream
  moved, **abort the seed** naming the file. The common `--forward --dry-run && patch` idiom
  collapses that third case into the second and is the silent no-op again.
- **The seed does not update apps.** `occ app:update` is a deliberate act; run it, then
  `make seed`, which re-applies or fails loudly. Auto-updating would make two identical seeds
  produce different instances depending on the day.
- **A patched app loses its vendor signature** — `12-apps.sh` deletes `appinfo/signature.json`
  after patching. That file asserts the app's files are exactly as the vendor shipped them; our
  patches make the assertion false. See *Code integrity* below.

### AD-5's "opt-in" means the container, not the app

`eurooffice` is installed by `make seed` now. The office backend is still opt-in: what is
optional is the ~2 GB documentserver behind `--profile eurooffice`. The connector is a PHP app
that does nothing until `make office-eurooffice` gives it a URL and a secret, and having it
installed on every instance is what lets its patches be re-applied on every seed. It also lets
CI exercise install-and-patch without pulling the image.

## Code integrity

Store apps ship a signed manifest, so patching one fails Nextcloud's code-integrity check and
`Settings > Administration > Overview` shows a permanent red *"Some files have not passed the
integrity check"* (#71 — the warning is cached in appconfig, so it survives page loads).

Measured in the pinned image, `lib/private/IntegrityCheck/Checker.php:536-555`: an app is verified
if it is **shipped**, *or* if it carries `appinfo/signature.json`. A store app is not shipped, so
that file is the only reason it is checked at all.

**We delete it after patching.** The alternative readings were worse: keeping a signature that no
longer describes the files leaves one alarm permanently red, which trains admins to ignore the one
signal that would catch real tampering — the always-green sin of B-001 with the colour reversed.
Dropping the patches instead would put "Nextcloud Office" back in the admin sidebar and app list,
and vendoring the app was already rejected at 11 MB / 410 files.

What this costs, stated plainly: **no tamper detection for `eurooffice`.** Core keeps its check, so
does every unpatched app, and `scripts/smoke.sh` check 10 fails if a patched app is signed again —
which is what an `occ app:update` from the UI does, since it restores the pristine files *and* the
signature. Recovery from a warning already cached is the **Rescan…** link inside the warning
(`CheckSetupController::rescanFailedIntegrityCheck` → `runInstanceVerification`, which clears the
cached result first); a core upgrade does the same.

## Three words this repo was using as one

They have different lifetimes, which is why they live in different places:

| | What | Survives an app update? | Where it lives |
|---|---|---|---|
| **install** | `occ app:install` | n/a | `12-apps.sh` |
| **configure** | `occ config:app:set` | **yes** — it is in the database | `14-office`, `15-branding`, `16-app-policy` |
| **patch** | editing files in `apps/<id>/` | **no** — wiped | `provisioning/apps/<id>/*.patch` |

Reading "we changed the app" as one act is what put the connector's rename in the `Makefile`
next to its JWT secret, where a `make seed` could not restore it.

## Consequences

- An app update that moves a patched line **stops the seed**. That is the intended cost: the
  alternative is the rename silently reverting and nobody noticing until a user sees "Nextcloud
  Office". Regenerate the patch and re-run.
- Adding an app is one word in `APPS`; adding an edit is one file in a directory.
- `make office-eurooffice` no longer installs anything, so on a fresh instance `make seed` must
  run first. It already had to, for groups and folders.

## Verified

Exercised in all three states on 2026-07-29 against a live instance: reverting the file to
upstream made the phase log `applied` and the rename returned; re-running logged `already
applied` with no rewrite; changing the surrounding context made the phase print `no longer
applies; upstream moved, regenerate it`, and `make seed` exited non-zero at `FATAL: phase
12-apps.sh failed`.
