<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0002 — Inherited architecture decisions (AD-n)

Accepted, 2026-07-27.

## Context

Provisioning phases and scripts cite `AD-n` as settled architecture decisions. They were agreed during
the planning sprint of 2026-07-18/19 and referenced by number from then on, so a reader meeting `AD-2`
in a shell comment needs one place that says what it requires. This is that place: one paragraph each,
harvested from the citation sites. It defines no new policy.

The repository also cites requirement numbers: `FR-n`, `NFR-n`, `PRD §x`. They come from the planning
documents of 2026-07-18/19 (brief → PRD → architecture → epics), which are not in this repository, so
they cannot be made resolvable here.

## Decision

### AD-2 — The seed is the single writer of instance state

Nothing else may mutate the running instance: no admin-panel clicking, no standalone scripts, no manual
`occ` runs as part of a procedure. Desired state lives in `provisioning/phases/*.sh`, each idempotent,
applied by `provisioning/seed.sh`. A clean bring-up reproduces the instance exactly, and every change is
in git. So there is no standalone theming script, which would be a second entry point
([ADR-0003](0003-server-theme-for-branding.md)), and brand images are registered from theme files
rather than uploaded through the admin UI, which also keeps admin credentials out of the seed runner.
AD-2 holds without exception: `seed.sh` is the only writer.

### AD-3 — Secrets live in `.env`, never in git and never in a log

Credentials reach the stack through `.env` (gitignored; `.env.example` carries placeholders only) and
never appear in the repository, in a committed file, or in output. `14-office.sh` writes the office JWT
secret through an inline guard rather than `app_config_set`, because that helper's log line would put
the value on stdout; it logs the ` -> ` write marker without the value, so `seed-idempotent.sh` can
still see a rewrite.

### AD-4 — Group Folders with allow-refinement, never deny

The Document Home is built from Nextcloud Group Folders. Access grants are allow-only: a group has read,
or read+write, or no entry at all. No DENY rules: they compose unpredictably and make the effective
matrix impossible to reason about. Refinement narrows by adding more specific allows, never by
subtracting.

### AD-5 — Euro-Office is the office backend

Collaborative editing runs on the Euro-Office document server, on an OSS image with no paid licence.
`scripts/office-smoke.sh` proves the pipe end to end and asserts the image provenance. `12-apps`
installs the connector and `14-office` configures it on every seed. The accepted costs are named where
they are paid: [arquitectura](https://aps-conecta.github.io/documentation/administracion/arquitectura.html)
(the ~8 GB floor) and `.github/workflows/cleanboot.yml` (the CI pull).

### AD-7 — Locale defaults are seeded, not forced

`10-locale.sh` sets `default_language=es`, `default_locale=es_CL` for Chilean date and number
formatting, and `default_phone_region=CL`. The locale stays a default users may change. The language is
forced (`force_language=es`), because `findLanguage()` consults the browser's Accept-Language before the
default. A user's timezone stays per-user, browser-detected; the instance default (`default_timezone`, what
server-side code reads through `IDateTimeZone::getDefaultTimeZone()`) is the zone chosen in AIO, seeded from
the Nextcloud container's `TZ`. UI text is Spanish; all code, identifiers and config keys are English.

### AD-8 — Containers reach each other by service name; `host.docker.internal` is host-only

Container-to-container traffic uses the service name over the container network (`nextcloud`, `db`,
`redis`, `eurooffice`), never `localhost` and never a host-published port. That is why `14-office.sh`
sets `DocumentServerInternalUrl=http://eurooffice/` and `StorageUrl=http://nextcloud/` while
`DocumentServerUrl` (the browser's view) uses `localhost:$OFFICE_PORT`, and why the same phase adds
`nextcloud` to `trusted_domains`: Nextcloud answers HTTP 400 to a fetch at an untrusted host.

`host.docker.internal` is reserved for the other direction, container → host, and on Linux it needs an
explicit `host-gateway` mapping.

### AD-9 — Custom apps use OCP public APIs only; core is never patched

A custom app may depend on Nextcloud only through `OCP\…`, never through private internals, and core
never depends on a custom app. Core is never patched.

## Consequences

- Every `AD-n` citation resolves.
- New decisions get their own numbered ADR. The `AD-n` series is closed.
- Where an inherited decision and a later ADR disagree, the ADR wins and says so explicitly.
- `FR-n`, `NFR-n` and `PRD §x` are pointers into the planning history, not something to look up. Where
  one carries a rule this repository must keep, the rule is stated where it applies, as the access
  matrix in `40-acl.sh` does, rather than left as a bare number. Prefer that over adding numbered
  citations.
