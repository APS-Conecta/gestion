# Provisioning framework

The **single writer of desired state** for the APS Conecta instance (AD-2). `make up` starts
services only; **`make seed`** applies all configuration/groups/folders/ACLs/fixtures by
running `seed.sh`, which sources the numbered phase files in `phases/` in fixed order.

**`make install` is the front door** ([#79](https://github.com/APS-Conecta/gestion/issues/79)): it
brings the stack up, waits for Nextcloud's own installer, runs this pipeline with the phase log going
to `.install.log`, and health-checks the result. `make seed` stays the verbose inner command — it is
what `scripts/seed-idempotent.sh` runs and greps, so its output format is load-bearing.

```
provisioning/
  seed.sh            # the runner (make seed → this)
  lib.sh             # shared idempotency-guard helpers (source, don't execute)
  apps/              # per-app *.patch files, applied by 12-apps (ADR-0002)
    eurooffice/
  phases/
    05-security.sh   # session hardening + outbound defaults
    06-jobs.sh       # background jobs from cron, not ajax
    10-locale.sh     # Epic 1 — es-CL locale defaults
    12-apps.sh       # ADR-0002 — which apps we install, and the edits inside them
    14-office.sh     # AD-5 — Euro-Office CONNECTOR config (the backend is `make office-eurooffice`)
    15-branding.sh   # Epic 5 — APS Conecta white-label
    16-app-policy.sh # admin keeps everything; staff get the reduced set
    20-groups.sh     # Epic 2 — role/category/team group registry
    30-folders.sh    # Epic 3 — hybrid four-area Group Folders tree
    40-acl.sh        # Epic 3 — first-cut access matrix (allow-refinement, no DENY)
    50-users.sh      # Story 0.6 — synthetic sample users  (FIXTURE)
    60-fixtures.sh   # Story 0.6 — synthetic sample content (FIXTURE)
```

## The clinic's own data

One stack serves one CESFAM, and everything specific to it is **data**: `sites/<slug>/site.sh`.
`SITE` in `.env` names the directory; `seed.sh` sources the file once, in the parent shell, *before*
the phase loop — each phase already runs in a subshell of that, so every phase sees the arrays and
none can write back. An unset `SITE`, or a missing file, is fatal before any phase runs.

**No clinic ships in this repo** — a fresh clone has no site at all, and `make seed` refuses to run
until you write one. Choosing the clinic is the first step of an install, not a file you inherit.
The weekly clean-boot job does exactly the same thing before it seeds, so that path is tested.

| In the site file | In the phases (identical everywhere) |
|---|---|
| Identity: name, type, address, comuna, DEIS code | `all-staff`, the four `cat-*`, the 21 `role-*` |
| `SITE_TEAMS` — the `prog-*` and `sector-*` teams | The `LÉEME — Convenciones.md` text |
| `SITE_FOLDERS`, `SITE_SUBFOLDERS` | Phases 05, 06, 10, 12, 14, 15, 16 |
| `SITE_ACL` — the whole grant matrix, `mount\|group\|perms` | |

Write a new one with [`scripts/deis.py`](../scripts/deis.py): it finds the clinic in the shipped DEIS
register, fills the identity from it, and **asks** for the sectors and programs — a register knows
neither how many sectors a CESFAM has nor whether they are numbered, coloured or named after a
neighbourhood.

```
scripts/deis.py cesfam florida        # find the code
scripts/deis.py 114302 --new mi-cesfam
```

The file it writes is complete and standalone: **nothing is inherited at seed time**. Adding a unit
later is one line in `SITE_FOLDERS` plus its rows in `SITE_ACL`.

## Contract

- **Fixed phase order 05 → 60.** Structure (05–40) before fixtures (50–60). The order comes from the
  shell's glob sort, not a numeric sort, so every prefix must stay two digits — a `100-` phase would
  run between `10-` and `12-`.
- **One epic per file.** Each phase file is owned by exactly one epic/story (see the header of each). An
  epic **only edits its own** phase file — so parallel epics never conflict. Add capability by adding
  a phase file, never by editing another epic's file or a monolith.
- **Idempotent by guard (query-before-create).** Every mutating step must inspect current state and
  skip/patch — never blind-create. `make seed` is safe to run any number of times. Use the `lib.sh` helpers:
  - `ensure_group GID` — via `occ group:list`
  - `ensure_user UID DISPLAY PASSWORD`, `add_user_to_group UID GID`
  - `ensure_groupfolder MOUNT` — via `occ groupfolders:list` (**`groupfolders:create` is NOT
    idempotent by name** — always query first)
  - `config_system_set KEY VALUE [TYPE]`, `app_config_set APP KEY VALUE`, `theming_set KEY VALUE` —
    set only if different; `theming_image_set KEY ABSOLUTE_PATH` for the brand images (the one
    helper that rewrites on every run — `seed-idempotent.sh` exempts it by name)
  - `ensure_app APPID`, `apply_patch APPID PATCHFILE`, `app_restrict_to_groups`, `app_disable`
  - `gf_grant MOUNT GROUP [read|write|share|delete]`, then `gf_prune` once at the end of the ACL phase
  - `ensure_gf_subfolder`, `ensure_gf_file`, `ensure_sample_file`
  - `require_installed`, and `phase_begin`/`phase_end`/`log`

  `occ` itself comes from [`scripts/env.sh`](../scripts/env.sh), which `seed.sh` sources before
  `lib.sh`.
- **Structure-vs-fixtures partition.** Phases 05–40 own *structure* (locale, groups, folders, ACLs).
  Phases 50–60 own *only* fixtures (synthetic sample users into **already-existing** groups, and
  sample content). Run structure-only with `SEED_FIXTURES=0 make seed` (production would). One owner per
  artifact — fixtures never create structure.
- **No real data, ever.** Fixtures are deterministic synthetic dev data only (NFR-2).

## Adding a phase

Keep the `phase_begin`/`phase_end` frame and use the guarded helpers for the body. Read
[`phases/10-locale.sh`](phases/10-locale.sh) — it is short, live, and the model to copy. No snippet
is reproduced here on purpose: the one that used to be had drifted from the file it described and
still carried a bug the real phase had already fixed.
