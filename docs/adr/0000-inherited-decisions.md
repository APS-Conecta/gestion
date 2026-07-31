# ADR-0000 — Inherited architecture decisions (AD-1 … AD-10)

- **Status:** accepted (recorded 2026-07-27; the decisions themselves predate this file)
- **Affects:** everything — these are cited throughout the repo

## Context

The repo cites `AD-1` … `AD-10` as settled architecture decisions, in `README.md`,
`CONTRIBUTING.md`, `ROADMAP.md`, `BUGS.md`, `docs/ARCHITECTURE.md`, every provisioning phase and
most scripts. **None of them was ever defined anywhere.** They were agreed during the planning
sprint of 2026-07-18/19 and referenced by number from then on, so a reader meeting `AD-2` in a shell
comment had no way to learn what it required.

This file is the cheapest thing that makes every existing citation resolvable: one paragraph each,
harvested from the citation sites themselves. It defines no new policy and changes no behaviour.

*Corrected 2026-07-30.* This section used to claim `AD-3` and `AD-8` were "not cited anywhere in the
repo" and leave them undefined. They are cited, eight times: `AD-3` in `.env.example` and
`14-office.sh`, `AD-8` in `compose.yaml` (three sites), `dev/xdebug.ini` and `14-office.sh` — which
is exactly the failure this file exists to close, reproduced inside its own justification. Both are
now defined below, harvested from those sites like the rest.

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

**Correction (2026-07-28, narrowed 2026-07-30) — `make office-eurooffice` is a second writer.** As
written above, this decision reads as if `seed.sh` were the only path that mutates the instance.
It is not, though it is now much closer than it was: the app install moved to phase `12-apps` and
the connector's config to phase `14-office`, so all that remains outside the pipeline is one
`trusted_domains` repair (an install-time value, indexed into an array, which the config guards do
not model). The target then runs `seed.sh` itself.

The office backend is deliberately out of the seed pipeline — it is an optional profile brought up
on demand (AD-5), and a phase that needs an app the pipeline has not installed yet would have to
either skip silently on a clean bring-up or force the profile on everyone. So AD-2's *rule* is
narrower than its wording: **desired state is declared in git and applied by a make target that is
idempotent and re-runnable**, and `seed.sh` is the writer for everything in the core stack. What
AD-2 actually forbids — hand-clicking, and one-off scripts nobody re-runs — still holds without
exception.

### AD-3 — Secrets live in `.env`, never in git and never in a log

Credentials reach the stack through `.env` (gitignored, `.env.example` carries placeholders only)
and never appear in the repo, in a committed file, or in output. `14-office.sh` writes the office
JWT secret through an inline guard rather than `app_config_set`, because that helper's log line
would put the value on stdout; it logs the ` -> ` write marker without the value, so
`seed-idempotent.sh` can still see a rewrite. `.githooks/pre-commit` blocks the obvious file shapes.

### AD-4 — Group Folders with allow-refinement, never deny

The Document Home is built from Nextcloud Group Folders. Access grants are **allow-only**: a group
either has read, or read+write, or no entry at all. No DENY rules — they compose unpredictably and
make the effective matrix impossible to reason about. Refinement narrows by adding more specific
allows, never by subtracting.

### AD-5 — Euro-Office is the office backend

Collaborative editing runs on the Euro-Office document server, brought up and wired by
`make office-eurooffice`, on an OSS image with no paid licence. `scripts/office-smoke.sh` proves the
pipe end to end and asserts the image provenance.

**Clarified by [ADR-0002](0002-app-patches.md):** what is opt-in is the ~2 GB documentserver
container behind `--profile eurooffice`. The `eurooffice` *connector app* is installed by
`make seed` (phase `12-apps`) on every instance — it is inert until this target gives it a URL
and a secret, and being installed is what lets its patches be re-applied each seed.

### AD-6 — White-labeling is config, not theme files *(superseded)*

Originally: branding would be `occ theming:config` plus `disable-user-theming`, with **no `themes/`
file and no `defaults.php`**, the latter rejected as fork-adjacent and because it needs an opcache
reset. Deferred until "a brand guide lands".

**Superseded on the `themes/` half** by [ADR-0001](0001-server-theme-for-branding.md): brand
typography needs `@font-face` with paths only a theme serves. **AD-6 was right about
`defaults.php`** — it was carried for one job a config key does, and it was deleted on 2026-07-27.

### AD-7 — Locale defaults are seeded, not forced

`10-locale.sh` sets `default_language=es`, `default_locale=es_CL` for Chilean date and number
formatting, and `default_phone_region=CL`. The locale stays a **default** users may change.

*Corrected 2026-07-30.* As written this decision said `es_419` and called it "the Latin-American
Spanish translation Nextcloud actually ships". It ships no such translation: `es_419` is a valid ICU
locale but not a language, so `languageExists()` rejects it and the key was inert (B-009). The
language is now `es` and is **forced** (`force_language=es`), because `findLanguage()` consults the
browser's Accept-Language before the default. The locale half was always right. Timezone stays per-user, browser-detected. UI text is Spanish; all
code, identifiers and config keys are English.

### AD-8 — Containers reach each other by service name; `host.docker.internal` is host-only

Container-to-container traffic uses the compose service name over the compose network — `nextcloud`,
`db`, `redis`, `eurooffice` — never `localhost` and never a host-published port. That is why
`14-office.sh` sets `DocumentServerInternalUrl=http://eurooffice/` and `StorageUrl=http://nextcloud/`
while `DocumentServerUrl` (the BROWSER's view) uses `localhost:$OFFICE_PORT`, and why
`make office-eurooffice` must add `nextcloud` to `trusted_domains`.

`host.docker.internal` is reserved for the other direction, container -> host, and on Linux it needs
an explicit `extra_hosts: host-gateway` mapping. Its one real consumer is Xdebug connecting out to
the IDE (`dev/xdebug.ini`, AD-10).

### AD-9 — Custom apps use OCP public APIs only; core is never patched

A custom app may depend on Nextcloud only through `OCP\…`, never through private internals, and core
never depends on a custom app. Patching core or a third-party app would trigger AGPL §13 and would
be lost at the next upgrade. This is also why `apps/` and `themes/` are bind-mounted for live edit
rather than baked into a forked image.

### AD-10 — Xdebug lives in a derived dev image, off by default

`compose.dev.yaml`, `Dockerfile.dev` and `dev/xdebug.ini` build a derived image carrying Xdebug,
activated with `make up-dev`. The default `make up` path stays clean, so nobody pays the debugger's
overhead — or its logging quirks — unless they ask for it.

## The `FR-n` / `NFR-n` / `PRD §x` citations

The repo also cites requirement numbers — `FR-10`, `FR-11`, `FR-14`, `NFR-2`, `NFR-3`, `PRD §4.4`.
**Those come from the planning documents of 2026-07-18/19 (brief → PRD → architecture → epics), which
are not in this repo**, so unlike `AD-n` they cannot be made resolvable here. Read them as pointers
into that history, not as something to look up.

Where one of them carries a rule this repo must keep, the rule is stated where it applies rather than
left as a bare number — the access matrix in `40-acl.sh`, the synthetic-data rule in `AGENTS.md`, the
OSS-first mandate in `docs/LICENSING.md` §2. Prefer that over adding new numbered citations.

## Consequences

- Every existing `AD-n` citation now resolves. No citation was rewritten.
- New decisions get their own numbered ADR (`0001`, `0002`, …). The `AD-n` series is closed:
  it is history, not a place to add to.
- Where an inherited decision and a later ADR disagree, the ADR wins and says so explicitly, as
  ADR-0001 does for AD-6.
