<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0011 — Welcome content seeds through an ungated own-app phase

Accepted, 2026-09-24.

## Context

The repository's other two content seams for own apps are territorio's operator-paste import
(`host/aps-conecta`) and the phase-50+ fixture partition (`SEED_FIXTURES=0` skips them). The welcome screen is
neither: it is structure every clinic must have from the first seed, and it is the repository's first
provisioning-driven own-app content import. Staff edits to seeded pages are data: a re-seed that overwrote them
would destroy editorial work while every gate stayed green.

The ACL approach rests on live evidence (a `--test` probe on groupfolders 22.0.6): a baseline-deny rule for
`IntraVox Users` plus a target-allow rule for the owning group resolve through `Rule::mergeRules` (allow ORs
over deny **across mappings on the same path**), so a multi-group user (a jefatura who is also all-staff) keeps
read while a plain member loses it:

```
user in BOTH IntraVox Users + cat-jefaturas:  +read, +write, +create, +delete, +share
plain member of IntraVox Users only:          -read, +write, +create, +delete, +share
```

The trailing `+`s are the CLI's base-permission shape; the sign of `read` is the signal.

## Decision

`41-intravox.sh` is numbered below the fixture gate: **ungated by design**, because welcome structure is not a
fixture. The phase carries, in order: fail-closed identity guards (a missing `SITE_*` is a FATAL, never a
default); a declare-driven app guard (undeclared → the loud clinic skip; declared-not-enabled → FATAL);
`intravox:setup --skip-demo`; the registry→engine group map (adds-only, query-before-set, one `group:list`
answering both sides); the templated `es` import through a staged render → `docker cp` → `occ intravox:import`
→ clean transport; and path-scoped page ACL (baseline-deny + target-allow, written once). Payload lives in
`provisioning/intravox/es/` as product: clinic-agnostic placeholders, identity substituted at render time from
the site file's identity block, zero new identity variables.

Territorio's operator-paste boundary is crossed deliberately, with its disciplines inherited:
upsert-by-stable-id, write verbs visible to `seed-idempotent.sh`, query-before-set.

## Consequences

- Every clinic seeds its welcome structure, `SEED_FIXTURES=0` included.
