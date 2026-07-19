---
baseline_commit: 8181ba5f2d8c46cfa9d01f15e2887c45f0d33eee
---

# Story 0.1: Portable core Compose stack

Status: review

## Story

As a developer,
I want to bring up Nextcloud 33 + PostgreSQL 16 + Redis with one command on any OS,
so that I can start working without hand-assembling services.

## Acceptance Criteria

1. **One-command bring-up.** From a clean clone and `cp .env.example .env`, a single documented command (`make up`) starts Nextcloud + PostgreSQL 16 + Redis, and Nextcloud is reachable in a browser at the documented local URL (`http://localhost:${HTTP_PORT}`).
2. **Healthy install.** `docker compose exec --user www-data nextcloud php occ status` reports `installed: true` against PostgreSQL, and Redis is active as Nextcloud's memcache (local + locking).
3. **Portable.** On Linux, container→host callbacks resolve via `extra_hosts: ["host.docker.internal:host-gateway"]`; the core compose has **no absolute host paths** and nothing VPS-specific (no Tailscale, no machine-specific mounts). Two developers on different OSes get the same running instance.
4. **Secrets discipline.** `.env` is gitignored; only `.env.example` (placeholders, no real secrets) is committed. No secrets or product data land in git or the image.

## Tasks / Subtasks

- [x] **Task 1: `compose.yaml` with the three core services** (AC: 1, 3)
  - [x] `nextcloud` service — image `nextcloud:33-apache`; publish `${HTTP_PORT}:80`; `depends_on` postgres + redis with `condition: service_healthy`; named volume `nextcloud_data:/var/www/html`; `extra_hosts: ["host.docker.internal:host-gateway"]`.
  - [x] `db` service — image `postgres:16-alpine`; named volume `postgres_data:/var/lib/postgresql/data`; healthcheck `pg_isready -U ${POSTGRES_USER}`.
  - [x] `redis` service — image `redis:8-alpine`; healthcheck `redis-cli ping`.
  - [x] Reference all tunables from `.env` (no hard-coded ports/credentials).
- [x] **Task 2: `.env.example`** (AC: 1, 3, 4)
  - [x] Keys: `HTTP_PORT`, `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `NEXTCLOUD_TRUSTED_DOMAINS` (placeholders only).
  - [x] `.gitignore` already ignores `.env`/`.env.*` (bootstrap) — verified with `git check-ignore .env`; no change needed.
- [x] **Task 3: `Makefile` — `up` / `down` only** (AC: 1)
  - [x] `up` → `docker compose up -d` (services only — **no seeding/provisioning**; that is `make seed` in Story 0.5).
  - [x] `down` → `docker compose down` (keep volumes; do not add `-v`).
- [x] **Task 4: Redis wiring + install verification** (AC: 2)
  - [x] Redis wired via `REDIS_HOST=redis`; the official image auto-set `memcache.distributed` + `memcache.locking` to `\OC\Memcache\Redis` (verified via `occ config:system:get`).
  - [x] Verified `occ status` → `installed: true` (v33.0.6.2) against PostgreSQL 16.14; `redis-cli ping` → PONG.
- [x] **Task 5: Portability check** (AC: 3, 4)
  - [x] Confirmed no absolute host paths / VPS-specific config in `compose.yaml`.
  - [x] Confirmed `host.docker.internal` resolves inside the nextcloud container (`10.0.0.1` via `host-gateway`).

## Dev Notes

**This story is the first code in the repo.** Keep it minimal and correct; later stories extend the same files.

- **AD-1 (no fork):** use the **official `nextcloud:33-apache` image** only. No source fork, no `defaults.php` overrides, no core patch. All config via env / `occ`. [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-1]
- **AD-8 (networking):** services reach each other by **compose service name** (`db`, `redis` as hostnames in Nextcloud's DB/Redis config). `host.docker.internal` is **only** for host↔container; on Linux add `extra_hosts: ["host.docker.internal:host-gateway"]`. Do not route container↔container through the host. [Source: #AD-8]
- **AD-3 / NFR-2 (data ownership + secrets):** `nextcloud_data` volume owns product content, PostgreSQL owns metadata, Redis owns cache/locks. Repo owns config only. **No secrets/product data in git**; `.env` gitignored, `.env.example` has placeholders. [Source: #AD-3; PRD#NFR-2]
- **AD-2 (provisioning boundary):** `make up` starts **services only**. Branding, groups, folders, ACLs, fixtures are the **separate** `make seed` provisioning pipeline delivered starting Story 0.5 — **do not** bake any provisioning into `up`. [Source: #AD-2; epics.md Conventions "`make up` starts services only (no seeding)"]
- **Stack pins (verified current 2026-07-19):** `nextcloud:33-apache` (33.0.6 head), `postgres:16-alpine`, `redis:8-alpine` (Redis 8 = AGPL/OSS). [Source: #Stack]
- **Nextcloud official-image env vars** (confirm against the image README on Docker Hub `nextcloud` / the docker-library/nextcloud docs): `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST` (= `db`); `REDIS_HOST` (= `redis`), `REDIS_HOST_PASSWORD` (optional); `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`; `NEXTCLOUD_TRUSTED_DOMAINS`. The apache image auto-runs first-boot install when admin + DB env vars are present — that satisfies AC-2's `installed: true` without manual `occ maintenance:install`.
- **`occ` invocation:** `docker compose exec --user www-data nextcloud php occ <cmd>`.
- **Scope guards (do NOT do here):** Collabora is **Story 0.2**; Xdebug/`compose.dev.yaml` is **Story 0.3**; `smoke`/`test`/`seed` Makefile targets are **Stories 0.4/0.5**; `apps/`+`themes/` bind mounts are **Story 0.8**. Leave `compose.yaml` cleanly extensible for these, but implement none of them now.

### Project Structure Notes

- **Files created (all NEW, at repo root):** `compose.yaml`, `.env.example`, `Makefile`, and a `.gitignore` entry for `.env`. Matches the source-tree scaffold in ARCHITECTURE-SPINE.md#Structural Seed (`compose.yaml`, `.env.example`, `Makefile` at root).
- **Boot-check precedent:** the bootstrap already verified NC **33.0.6** + PG **16** come up clean (`occ status: installed`) with pins `nextcloud:33-apache`, `postgres:16-alpine` — replicate that known-good config. [Source: ROADMAP.md#Completed — Bootstrap]
- **Compose file name:** use `compose.yaml` (modern Compose spec, no `version:` key needed).

### References

- [Source: docs/planning/epics.md#Story 0.1] — user story + ACs + governing ARs (AR-1, AR-8, AR-11, AR-12)
- [Source: docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md#FR-1] one-command bring-up; [#NFR-1] portability; [#NFR-2] security/secrets
- [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-1, #AD-2, #AD-3, #AD-8, #Stack, #Structural Seed, #Consistency Conventions]
- [Source: docs/ARCHITECTURE.md#Runtime topology, #Stack, #Data ownership & flows]
- Nextcloud Docker image env/config: Docker Hub `nextcloud:33-apache` README; Context7 `/websites/nextcloud_server_admin_manual` (Redis caching + `occ`).

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

- `make up` → pulled nextcloud:33-apache / postgres:16-alpine / redis:8-alpine; db+redis healthy; nextcloud started (~40s).
- `occ status --output=json` → `{"installed":true,"version":"33.0.6.2",...,"maintenance":false}`.
- `curl http://localhost:8091/status.php` → HTTP 200, `installed:true`.
- `occ config:system:get memcache.locking` & `memcache.distributed` → `\OC\Memcache\Redis`; `redis` → host `redis:6379`; `redis-cli ping` → PONG.
- `occ config:system:get dbtype` → `pgsql`; `select version()` → PostgreSQL 16.14.
- `getent hosts host.docker.internal` (nextcloud container) → `10.0.0.1`.
- `docker compose stop` after verification (reversible; images + volumes retained).

### Completion Notes List

- All 4 ACs verified end-to-end against a live stack (verification run on free host port 8091; `.env.example` ships `HTTP_PORT=8080`). Stack **stopped** after verification to free shared-host resources — restart with `make up`.
- Redis locking + distributed cache are auto-configured by the official image from `REDIS_HOST=redis` — no custom config, no fork (AD-1).
- `make up` starts services **only** (AD-2); `seed`/`smoke`/`test`, Collabora (0.2), Xdebug (0.3), and app/theme mounts (0.8) are intentionally **not** implemented here.
- No unit-test framework exists yet (the `test`/`smoke` gate is Story 0.4); this infra story's verification is the live bring-up + `occ`/HTTP/Redis/DB checks above.
- `.gitignore` already ignored `.env`/`.env.*` (bootstrap), so AC-4 required no change.

### File List

- `compose.yaml` (new)
- `.env.example` (new)
- `Makefile` (new)

## Change Log

- 2026-07-19 — Story 0.1 implemented: portable core Compose stack (Nextcloud 33 + PostgreSQL 16 + Redis 8), `make up`/`down`, `.env.example`. All ACs verified against a live stack (installed:true v33.0.6, Redis locking, PG 16.14, `host.docker.internal`). Status → review.
