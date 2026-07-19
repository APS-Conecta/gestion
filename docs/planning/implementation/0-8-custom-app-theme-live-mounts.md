---
baseline_commit: 63296c80dd3d52b3edb0f43ea16624ee236ea55d
---

# Story 0.8: Custom app & theme live-mounts

Status: review

## Story

As a developer,
I want `apps/` and `themes/` bind-mounted into the running Nextcloud,
so that I can add and live-edit custom app/theme code without rebuilding the image or forking core.

## Acceptance Criteria

1. **Bind mounts wired.** `compose.yaml` mounts the repo's `./apps` → `/var/www/html/custom_apps` and
   `./themes` → `/var/www/html/theming` (the Nextcloud theming dir), on the `nextcloud` service. The mounts
   are inherited by the dev overlay (`compose.dev.yaml`) with no extra config. Both directories exist in the
   repo (tracked, with a README explaining their purpose + AD-9).

2. **Custom app is discoverable + enable-able.** A trivial custom app dropped into `apps/<id>/appinfo/info.xml`
   is discovered by the running instance — `occ app:list` shows it under **disabled**, and `occ app:enable
   <id>` enables it — **without** rebuilding the image. Editing the host file is reflected live in the
   container (same inode via bind mount).

3. **No fork / OCP-only boundary (AD-9).** Nothing here patches core or the official image; custom apps are the
   only extension surface and depend on Nextcloud only via OCP public APIs. Documented in `apps/README.md`.

4. **Portable + no regressions.** Loopback/secrets/AD-8 networking unchanged; `make up` / `make up-dev` still
   come up healthy with the mounts. Any Linux ownership caveat (the container runs as uid 33 / www-data) is
   documented, not assumed away.

## Tasks / Subtasks

- [x] **Task 1: Bind mounts in `compose.yaml`** (AC: 1, 4)
  - [x] On the `nextcloud` service, add volumes `- ./apps:/var/www/html/custom_apps` and
    `- ./themes:/var/www/html/theming` (verify the exact theming path against the running image —
    `occ config:system:get theming.… ` / the image layout — and use whichever the image actually reads).
  - [x] Confirm the dev overlay inherits them (compose merges service volumes) — no `compose.dev.yaml` change.

- [x] **Task 2: `apps/` and `themes/` scaffold** (AC: 1, 3)
  - [x] Create `apps/.gitkeep`, `themes/.gitkeep` (so the otherwise-empty dirs are tracked and the mount
    source exists on a clean clone).
  - [x] `apps/README.md` — what goes here (`custom_apps`, one dir per app with `appinfo/info.xml`), the **AD-9
    boundary** (OCP public APIs only, never patch core), and the minimal app skeleton. `themes/README.md` —
    what goes here (custom theming), live-mounted.

- [x] **Task 3: Verify** (AC: 2, 4)
  - [x] `make up`; drop a **throwaway** trivial app (`apps/apsconecta_hello/appinfo/info.xml`, id + NC34 dep)
    on the host; confirm `occ app:list` shows it under disabled, `occ app:enable apsconecta_hello` succeeds,
    and it appears enabled — no image rebuild.
  - [x] Live-edit proof: bump the app's `<version>` on the host, confirm the container sees the new value
    (`occ app:list`/`app:getpath` or re-scan) — same file via the mount. Then `occ app:remove`/disable and
    delete the throwaway (do **not** commit it).
  - [x] Confirm `themes/` mounts (a host file appears at the theming path in the container).
  - [x] Document the Linux ownership note if discovery needs `chown 33` (test root-owned first; only prescribe
    chown if actually required). `make up-dev` still healthy. Stop the stack.

## Dev Notes

**Extends Story 0.1** (`compose.yaml`). Adds only two bind mounts + the `apps/`/`themes/` scaffold — no image
change, no fork.

- **AD-9 (custom-code boundary):** custom apps live in `apps/` → `custom_apps` and depend on Nextcloud **only
  through OCP public APIs** — never patch core, never rely on private internals; core never depends on a
  custom app. This is the sole v1 extension surface. [Source: ARCHITECTURE-SPINE.md#AD-9]
- **AD-1 / NFR-5 (no fork):** the official image is used unmodified; custom code is bind-mounted, never baked
  or forked. [Source: #AD-1]
- **`custom_apps` is a real Nextcloud apps path:** the official image configures `/var/www/html/custom_apps`
  as a writable `apps_paths` entry, so an app dropped there is discovered on the next request/`occ` scan. The
  bundled `apps/` (core apps) is separate and untouched — we mount only `custom_apps`.
- **Theming dir:** confirm whether the image reads `/var/www/html/themes` or `/var/www/html/theming` for
  custom themes (Nextcloud's server-side theming dir is `themes/`; the `theming` app is different). Mount the
  one the running image actually uses; verify before pinning.
- **Linux ownership (the one caveat):** the container runs as **www-data (uid 33)**. App *code* only needs to
  be readable, so a root-owned, world-readable `apps/` is usually discoverable as-is; if discovery/enable
  fails on a dev's Linux host, the fix is `sudo chown -R 33:33 apps themes` (documented, Linux-only). Test the
  root-owned path first and only prescribe chown if actually needed.
- **`occ` invocation:** `docker compose exec -T --user www-data nextcloud php occ …`. App discovery may need
  `occ app:list` (scans) — no restart required for a bind-mounted app.
- **Scope guards:** v1 ships **no** custom app (apps/ stays empty but mounted — AD-1 zero-custom-PHP); this
  story delivers the *mount mechanism*, verified with a throwaway app that is not committed.

### Project Structure Notes

- **Modified:** `compose.yaml` (+2 bind mounts). **New:** `apps/.gitkeep`, `apps/README.md`, `themes/.gitkeep`,
  `themes/README.md`. Matches ARCHITECTURE-SPINE.md#Structural Seed (`apps/` custom_apps, `themes/`).

### References

- [Source: docs/planning/epics.md#Story 0.8] — user story + ACs
- [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-9, #AD-1, #Structural Seed]
- [Source: docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md#FR-6] custom app/theme live-edit mounts
- [Source: docs/planning/implementation/0-1-portable-core-compose-stack.md] base compose extended

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

Verified live on the NC34.0.1 + PG18.4 stack:

- **Paths confirmed against the running image** (before wiring): `occ config:system:get apps_paths` → `/var/www/html/custom_apps` (writable:true); the theming dir is `/var/www/html/**themes**` (not `theming`) — the image ships a `themes/example` scaffold + README there (a reference template, safely masked).
- **Mounts live:** after `docker compose up -d`, both `custom_apps/README.md` and `themes/README.md` (from the repo) appear in the container; `make smoke` green.
- **AC2:** dropped a throwaway `apps/apsconecta_hello/appinfo/info.xml` (root-owned) → `occ app:list` showed it under **disabled** (`apsconecta_hello: 0.0.1`); `occ app:enable apsconecta_hello` → "enabled"; it moved to the enabled list. **No image rebuild, no `chown`** — root-owned/world-readable was discoverable as-is.
- **Live-edit proof:** `echo hello-v1 > apps/.livetest` → container `cat` shows `hello-v1`; edit on host → container immediately shows `hello-v2-edited` (same inode via bind mount). *(Note: `occ app:list` reports the DB-cached app version, not the on-disk info.xml — so the file-read is the correct live-mount probe, not app:list.)*
- **AC4:** `make up-dev` → the derived Xdebug image **inherits both mounts** (both READMEs present) + xdebug loaded + `make smoke` green; dev-overlay compose valid. Throwaway app removed; `apps/` left clean (`.gitkeep` + `README.md`).

### Completion Notes List

- Two bind mounts on the `nextcloud` service overlay the named volume at exactly the paths the image reads:
  `./apps → /var/www/html/custom_apps` (writable apps path) and `./themes → /var/www/html/themes`. No image change, no fork (AD-1/AD-9).
- **Linux ownership caveat resolved by test, not assumption:** discovery/enable worked with a **root-owned** `apps/` — `chown 33` is only needed if a dev's host blocks it, so both READMEs document it as a conditional fallback, not a required step.
- `themes/` mount **masks** the image's `example` theme scaffold — documented honestly in `themes/README.md`; safe because v1 white-labeling is config (AD-6, `10-branding`), not theme files.
- v1 ships **no** custom app (AD-1 zero-custom-PHP) — the dirs stay empty-but-mounted (`.gitkeep`), ready for Layer-2 apps. `compose.yaml` is the only code change; `make up`/`up-dev`/`seed`/gate all still green. Stack stopped after verification.

### File List

- `compose.yaml` (modified — +2 bind mounts: apps→custom_apps, themes→themes)
- `apps/.gitkeep`, `apps/README.md` (new — custom_apps scaffold + AD-9 boundary)
- `themes/.gitkeep`, `themes/README.md` (new — themes scaffold + masking note)

## Change Log

- 2026-07-19 — Story drafted (create-story): bind-mount `apps/`→`custom_apps` + `themes/`→theming; `apps/`/`themes/` scaffold + READMEs (AD-9). Verified trivial app discoverable/enable-able via a throwaway. Status → ready-for-dev.
- 2026-07-19 — Implemented (dev-story): 2 bind mounts (paths verified against the image — `custom_apps` + `themes`) + `apps/`/`themes/` scaffold. Verified live: throwaway app discovered + enabled (root-owned, no chown), live-edit proven by in-container file read, dev overlay inherits mounts + xdebug. Also flips Story 0.7 → done. **Completes Epic 0.** Status → review.
