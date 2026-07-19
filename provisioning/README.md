# Provisioning framework

The **single writer of desired state** for the APS Conecta instance (AD-2). `make up` starts
services only; **`make seed`** applies all configuration/branding/groups/folders/ACLs/fixtures by
running `seed.sh`, which sources the numbered phase files in `phases/` in fixed order.

```
provisioning/
  seed.sh            # the runner (make seed → this)
  lib.sh             # shared idempotency-guard helpers (source, don't execute)
  phases/
    10-branding.sh   # Epic 1 — branding + es-CL locale
    20-groups.sh     # Epic 2 — role/category/team group registry
    30-folders.sh    # Epic 3 — hybrid four-area Group Folders tree
    40-acl.sh        # Epic 3 — first-cut access matrix (allow-refinement, no DENY)
    50-users.sh      # Story 0.6 — synthetic sample users  (FIXTURE)
    60-fixtures.sh   # Story 0.6 — synthetic sample content (FIXTURE)
```

## Contract

- **Fixed phase order 10 → 60.** `seed.sh` sorts numerically. Structure (10–40) before fixtures (50–60).
- **One epic per file.** Each phase file is owned by exactly one epic/story (see the header of each). An
  epic **only edits its own** phase file — so parallel epics never conflict. Add capability by *filling a
  stub*, never by editing another epic's file or a monolith.
- **Idempotent by guard (query-before-create).** Every mutating step must inspect current state and
  skip/patch — never blind-create. `make seed` is safe to run any number of times. Use the `lib.sh` helpers:
  - `ensure_group GID` — via `occ group:list`
  - `ensure_user UID DISPLAY PASSWORD`, `add_user_to_group UID GID`
  - `ensure_groupfolder MOUNT` → prints id — via `occ groupfolders:list` (**`groupfolders:create` is NOT
    idempotent by name** — always query first)
  - `config_system_set KEY VALUE`, `config_app_set APP KEY VALUE` — set only if different
  - `require_installed`, and `phase_begin`/`phase_end`/`log`
- **Structure-vs-fixtures partition.** Phases 10–40 own *structure* (groups, folders, ACLs, branding,
  locale). Phases 50–60 own *only* fixtures (synthetic sample users into **already-existing** groups, and
  sample content). Run structure-only with `SEED_FIXTURES=0 make seed` (production would). One owner per
  artifact — fixtures never create structure.
- **No real data, ever.** Fixtures are deterministic synthetic dev data only (NFR-2).

## Filling a stub (worked example)

Epic 1 fills `phases/10-branding.sh` — the `phase_begin`/`phase_end` frame stays; the body uses guarded
helpers:

```bash
phase_begin "10-branding" "APS Conecta branding + es-CL locale (Epic 1)"
occ theming:config name "APS Conecta"
config_system_set default_language es
config_system_set default_locale es_CL
phase_end
```

Then `make seed` (or just re-run it) applies it idempotently alongside every other phase.
