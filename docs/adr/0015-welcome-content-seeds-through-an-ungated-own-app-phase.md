# ADR-0015 — welcome content seeds through an ungated own-app phase

- **Status:** accepted (2026-09-24, with this plan's approval).
- **Affects:** `provisioning/phases/41-intravox.sh`, `provisioning/intravox/es/`,
  `provisioning/seed.sh` (phase numbering), `scripts/divergence.sh` (tolerances).

## Context

The repo's two existing content seams for own apps are: territorio's operator-paste import
(`host/aps-conecta:380-424`) and the phase-50+ fixture partition (`SEED_FIXTURES=0` skips them).
The welcome screen is neither: it is structure every clinic must have from the first `make seed`
(FR-5), and it is the repo's first provisioning-driven own-app content import. Import-once
matters because staff edits to seeded pages are data (D2) — a re-seed that overwrote them would
destroy editorial work while every gate stayed green.

The ACL approach was frozen on live evidence (Phase 0's T-5 probe, groupfolders 22.0.6, folder
`IntraVox` id 20): a baseline-deny rule for `IntraVox Users` plus a target-allow rule for the
owning group resolve through `Rule::mergeRules` — allow ORs over deny **across mappings on the
same path** — so a multi-group user (a jefatura who is also all-staff) keeps read while a plain
member loses it. Verbatim `--test` output from the probe:

```
user in BOTH IntraVox Users + cat-jefaturas:  +read, +write, +create, +delete, +share
plain member of IntraVox Users only:          -read, +write, +create, +delete, +share
```

(The trailing `+`s are the CLI's base-permission shape; the sign of `read` is the signal.)

## Decision

New `41-intravox.sh`, numbered below the fixture gate: **ungated by design** — welcome structure
is not a fixture. The phase carries, in order: fail-closed identity guards (L5-03 class — a
missing `SITE_*` is a FATAL, never a default); declare-driven app guard (undeclared → the loud
clinic skip; declared-not-enabled → FATAL); `intravox:setup --language es --skip-demo`; the
registry→engine group map (adds-only, query-before-set, one `group:list` answering both sides);
the templated `es` import through a staged render → `docker cp` → `occ intravox:import` → clean
transport; and path-scoped page ACL (baseline-deny + target-allow, written once, with the first
import). Payload lives in `provisioning/intravox/es/` as product — clinic-agnostic placeholders,
identity substituted at render time from the existing site-file block, zero new `SITE_*`
variables.

Territorio's operator-paste boundary is crossed deliberately, with its disciplines inherited:
upsert-by-stable-id, write verbs visible to `seed-idempotent.sh`, query-before-set. Import-once
is guarded on in-container presence of `es/home.json` (the `gf_files_path` shape, `lib.sh:596` —
the `/files/` segment is load-bearing); the documented recovery for a half-imported tree is
delete-`es/`-and-reseed.
