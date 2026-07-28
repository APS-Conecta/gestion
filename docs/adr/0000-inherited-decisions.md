# ADR-0000 — Inherited architecture decisions (AD-1 … AD-10)

- **Status:** accepted (recorded 2026-07-27; the decisions themselves predate this file)
- **Affects:** everything — these are cited across ~19 files in the repo

## Context

The repo cites `AD-1`, `AD-2`, `AD-4`, `AD-5`, `AD-6`, `AD-7`, `AD-9` and `AD-10` as settled
architecture decisions — `AD-2` alone appears 14 times, in `README.md`, `CONTRIBUTING.md`,
`ROADMAP.md`, `BUGS.md`, `docs/ARCHITECTURE.md`, every provisioning phase and most scripts. **None
of them was ever defined anywhere.** They were agreed during the planning sprint of 2026-07-18/19
and referenced by number from then on, so a reader meeting `AD-2` in a shell comment had no way to
learn what it required.

This file is the cheapest thing that makes every existing citation resolvable: one paragraph each,
harvested from the citation sites themselves. It defines no new policy and changes no behaviour.

Numbering has gaps (`AD-3`, `AD-8`) — those numbers are not cited anywhere in the repo, and rather
than invent decisions to fill them, the gaps are left as they are.

## Decisions

### AD-1 — v1 ships no custom app; config-as-code only

The v1 scope is a *configured* Nextcloud, not a *programmed* one. `apps/` stays empty but mounted,
ready for Layer-2 apps on the roadmap (e.g. the REM app). This is why `/apps/*` is gitignored and
only `apps/README.md` is tracked.

### AD-2 — `make seed` is the single writer of instance state

Nothing else may mutate the running instance: no admin-panel clicking, no standalone scripts, no
manual `occ` runs as part of a procedure. Desired state lives in `provisioning/phases/*.sh`, each
idempotent, applied by `provisioning/seed.sh`.

The point is that a clean bring-up reproduces the instance exactly, and that every change is in git.
Two consequences seen in practice: the brand kit's standalone `occ-theming.sh` was deleted for
being a second entry point (ADR-0001), and brand images are *registered* from theme files rather
than uploaded through the admin UI, which also keeps admin credentials out of the seed runner.

**Correction (2026-07-28) — `make office-eurooffice` is a second writer, and always was.** As
written above, this decision reads as if `seed.sh` were the only path that mutates the instance. It
is not: the office target runs `app:install`, six `config:app:set` calls and a `trusted_domains`
write, and has done since Story 0.2. Recording it rather than leaving it implicit, because Epic 5
added a step there and the omission made that look like a new exception.

The office backend is deliberately out of the seed pipeline — it is an optional profile brought up
on demand (AD-5), and a phase that needs an app the pipeline has not installed yet would have to
either skip silently on a clean bring-up or force the profile on everyone. So AD-2's *rule* is
narrower than its wording: **desired state is declared in git and applied by a make target that is
idempotent and re-runnable**, and `seed.sh` is the writer for everything in the core stack. What
AD-2 actually forbids — hand-clicking, and one-off scripts nobody re-runs — still holds without
exception.

### AD-4 — Group Folders with allow-refinement, never deny

The Document Home is built from Nextcloud Group Folders. Access grants are **allow-only**: a group
either has read, or read+write, or no entry at all. No DENY rules — they compose unpredictably and
make the effective matrix impossible to reason about. Refinement narrows by adding more specific
allows, never by subtracting.

### AD-5 — Euro-Office is the office backend

Collaborative editing runs on the Euro-Office document server, brought up and wired by
`make office-eurooffice`, on an OSS image with no paid licence (audited by `make office-formats`).
`scripts/office-smoke.sh` proves the pipe end to end.

### AD-6 — White-labeling is config, not theme files *(superseded)*

Originally: branding would be `occ theming:config` plus `disable-user-theming`, with **no `themes/`
file and no `defaults.php`**, the latter rejected as fork-adjacent and because it needs an opcache
reset. Deferred until "a brand guide lands".

**Superseded on the `themes/` half** by [ADR-0001](0001-server-theme-for-branding.md): brand
typography needs `@font-face` with paths only a theme serves. **AD-6 was right about
`defaults.php`** — it was carried for one job a config key does, and it was deleted on 2026-07-27.

### AD-7 — Locale defaults are seeded, not forced

`10-locale.sh` sets `default_language=es_419` (the Latin-American Spanish translation Nextcloud
actually ships; a discrete `es_CL` UI translation does not exist), `default_locale=es_CL` for
Chilean date and number formatting, and `default_phone_region=CL`. These are **defaults**: users
and developers may change them. Timezone stays per-user, browser-detected. UI text is Spanish; all
code, identifiers and config keys are English.

### AD-9 — Custom apps use OCP public APIs only; core is never patched

A custom app may depend on Nextcloud only through `OCP\…`, never through private internals, and core
never depends on a custom app. Patching core or a third-party app would trigger AGPL §13 and would
be lost at the next upgrade. This is also why `apps/` and `themes/` are bind-mounted for live edit
rather than baked into a forked image.

### AD-10 — Xdebug lives in a derived dev image, off by default

`compose.dev.yaml`, `Dockerfile.dev` and `dev/xdebug.ini` build a derived image carrying Xdebug,
activated with `make up-dev`. The default `make up` path stays clean, so nobody pays the debugger's
overhead — or its logging quirks — unless they ask for it.

## Consequences

- Every existing `AD-n` citation now resolves. No citation was rewritten.
- New decisions get their own numbered ADR (`0001`, `0002`, …). The `AD-n` series is closed:
  it is history, not a place to add to.
- Where an inherited decision and a later ADR disagree, the ADR wins and says so explicitly, as
  ADR-0001 does for AD-6.
