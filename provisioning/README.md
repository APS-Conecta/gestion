# Provisioning framework

The **single writer of desired state** for the APS Conecta instance (AD-2). `make up` starts
services only; **`make seed`** applies all configuration/groups/folders/ACLs/fixtures by
running `seed.sh`, which sources the numbered phase files in `phases/` in fixed order.

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
    set only if different
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
