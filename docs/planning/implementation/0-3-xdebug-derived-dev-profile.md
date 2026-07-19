---
baseline_commit: 013fbb03e91b695a69eefcd9290c7f3c096d34ac
---

# Story 0.3: Xdebug derived dev profile

Status: review

## Story

As a developer,
I want to step-debug the running Nextcloud from my editor over a derived dev-only image,
so that I have a real feedback loop for building and verifying — without Xdebug ever touching the base/committed core.

## Acceptance Criteria

1. **Derived dev-only image (AD-10).** A `Dockerfile.dev` layers Xdebug onto the official `nextcloud:34-apache` image; a `compose.dev.yaml` overlay builds it and runs the `nextcloud` service from that derived image. The **base `compose.yaml` and the official image are unchanged** — `php -m` on the plain `nextcloud:34-apache` image shows **no** `xdebug`. Enabling debug is opt-in: `docker compose -f compose.yaml -f compose.dev.yaml up -d` (wrapped as `make up-dev`).

2. **Xdebug loaded + configured for step debugging.** In the dev-profile container, `php -m` lists `xdebug` and `xdebug.mode` includes `debug`, with `xdebug.client_host=host.docker.internal`, `xdebug.client_port=9003`, and a request-scoped trigger (`xdebug.start_with_request=trigger`). The core stack still comes up healthy (`occ status: installed`) — Xdebug does not break boot.

3. **Breakpoint pipe works end-to-end.** With a DBGp client listening on `9003` (VS Code, or a headless listener for CI-style verification), a triggered PHP request causes Xdebug to **initiate a debug session** to the client (the client receives the DBGp `init` packet). Variable inspection / breakpoints are available (verified in-editor; the headless check proves the connection initiates).

4. **Editor config committed.** `.vscode/launch.json` ships a "Listen for Xdebug" configuration (port 9003) with `pathMappings` from the repo's `apps/` to the container's `custom_apps` (ready for the Story 0.8 mount), documented so a developer can attach with no manual setup.

## Tasks / Subtasks

- [x] **Task 1: `Dockerfile.dev` — derived Xdebug image** (AC: 1, 2)
  - [x] `FROM nextcloud:34-apache`; `RUN pecl install xdebug && docker-php-ext-enable xdebug` (PHP 8.5 base — if the latest stable Xdebug doesn't yet support 8.5, pin the first version that does and note it).
  - [x] Drop an Xdebug ini (e.g. `COPY dev/xdebug.ini /usr/local/etc/php/conf.d/zz-xdebug.ini`, `zz-` prefix so it wins) with: `xdebug.mode=debug`, `xdebug.start_with_request=trigger`, `xdebug.client_host=host.docker.internal`, `xdebug.client_port=9003`, `xdebug.log=/tmp/xdebug.log`, `xdebug.discover_client_host=false`.
  - [x] Keep it minimal — no other changes to the image; the entrypoint/CMD are inherited from the base.

- [x] **Task 2: `compose.dev.yaml` overlay** (AC: 1)
  - [x] Override the `nextcloud` service to `build: { context: ., dockerfile: Dockerfile.dev }` (derived image) instead of `image:`. Inherit everything else from `compose.yaml` (ports, env, volumes, `extra_hosts` — `host.docker.internal:host-gateway` is already there and is what Xdebug calls back to).
  - [x] Optionally set `XDEBUG_MODE`/trigger via env if cleaner than the ini; keep one source of truth.
  - [x] Do **not** touch the office profiles or db/redis.

- [x] **Task 3: `.vscode/launch.json`** (AC: 4)
  - [x] "Listen for Xdebug" (type `php`, request `launch`, port 9003) with `pathMappings`: `"/var/www/html/custom_apps": "${workspaceFolder}/apps"` (forward-looking for Story 0.8). Add a commented note for mapping NC core if a dev needs it.

- [x] **Task 4: `make up-dev` target** (AC: 1)
  - [x] `up-dev`: precheck `.env`, then `docker compose -f compose.yaml -f compose.dev.yaml up -d --build`. Add to `.PHONY` and `help`. Leave `up`/`down` and office targets untouched.

- [x] **Task 5: Verify** (AC: 1, 2, 3)
  - [x] Base clean: `docker run --rm nextcloud:34-apache php -m | grep -i xdebug` → empty (AD-10).
  - [x] `make up-dev` → derived image builds; `occ status: installed`; `php -m | grep xdebug` present; `php -i | grep xdebug.mode` shows `debug`.
  - [x] Step-debug pipe: run a headless DBGp listener on host `:9003`, trigger a request with the Xdebug trigger (`XDEBUG_TRIGGER` cookie/GET/env), confirm the listener receives an `<init ... xmlns="urn:debugger_protocol_v1">` packet (Xdebug connected). Record it.
  - [x] Tear back to the plain profile (`make down` / `make up`) and stop.

## Dev Notes

**Extends Story 0.1** (base `compose.yaml`). Xdebug is strictly a **derived overlay** — nothing in the base image or `compose.yaml` changes (AD-10 / AD-1: no fork, no base mutation).

- **AD-10 (Xdebug derived):** step-debugging comes from a derived image / `compose.dev.yaml` layered on the official image, dev-only — never baked into the base or committed core. [Source: ARCHITECTURE-SPINE.md#AD-10; PRD#FR-2]
- **AD-8 (networking):** Xdebug in the container connects **back to the IDE on the host** — that's a container→host call, so `host.docker.internal` is correct here (already provided via `extra_hosts` in the base compose). [Source: #AD-8]
- **Base image facts (verified 2026-07-19):** `nextcloud:34-apache` is **PHP 8.5.8**, based on `php:8.5-apache`; ships `pecl` + `docker-php-ext-enable`; conf.d at `/usr/local/etc/php/conf.d/`; **no xdebug** in the base. Install via `pecl install xdebug && docker-php-ext-enable xdebug`.
- **Xdebug 3 config** (v3 renamed everything from v2): `xdebug.mode=debug` (not the old `remote_enable`), `xdebug.start_with_request=trigger` (only debug when a trigger is present — avoids debugging every request), `xdebug.client_host` + `xdebug.client_port=9003` (v3 default port, not 9000), `xdebug.discover_client_host=false` (use the fixed host). Trigger via `XDEBUG_TRIGGER` cookie/GET/POST or the `XDEBUG_SESSION` cookie.
- **PHP 8.5 caveat:** the base is PHP 8.5 (new). `pecl install xdebug` pulls latest stable — confirm it supports 8.5; if the build errors, pin the minimal supporting version and note it in Completion Notes.
- **Verification without an IDE:** Xdebug connects *out* to `client_host:9003`. A headless listener (`nc -l 9003`, or a tiny socket read) on the host receiving the DBGp `init` XML proves the pipe end-to-end; full breakpoint/variable inspection is confirmed in-editor (documented, not scriptable here).
- **Scope guards:** `smoke`/`test`/`seed` = Stories 0.4/0.5; the `apps/`+`themes/` bind mounts = Story 0.8 (the launch.json path mapping is prepared but the mount lands there). Office profiles unchanged.

### Project Structure Notes

- **New files:** `Dockerfile.dev`, `compose.dev.yaml`, `dev/xdebug.ini` (or inline), `.vscode/launch.json`. **Modified:** `Makefile` (+`up-dev`). Matches ARCHITECTURE-SPINE.md#Structural Seed (dev overlay lives alongside the base compose).
- The derived image is **not** pushed anywhere — built locally on demand (`--build`).

### References

- [Source: docs/planning/epics.md#Story 0.3] — user story + ACs (Given/When/Then)
- [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-10, #AD-8, #AD-1]
- [Source: docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md#FR-2] live PHP step-debug
- [Source: docs/planning/implementation/0-1-portable-core-compose-stack.md] base compose this overlays
- Xdebug 3 docs (mode/start_with_request/client_host/client_port); Nextcloud image = `php:8.5-apache` base

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

Verified live on the NC34.0.1 + PG18.4 stack:

- `make up-dev` → derived image `apsconecta-gestion/nextcloud-xdebug:dev` built (`pecl install xdebug` succeeded on **PHP 8.5.8** → **Xdebug 3.5.3**); nextcloud recreated from it; `occ status: installed` (34.0.1), stack healthy.
- `php -m` → `xdebug` present; `php -i` → `xdebug.mode=debug`, `xdebug.start_with_request=trigger`, `xdebug.client_host=host.docker.internal`, `xdebug.client_port=9003`.
- **AD-10 held:** `docker run --rm nextcloud:34-apache php -m` → **no** xdebug (base/official image untouched).
- **Step-debug pipe proven** (AC3, headless): DBGp listener on the host gateway `10.0.0.1:9003`; a PHP run with `XDEBUG_TRIGGER=1` caused Xdebug to connect from the container (10.0.6.4) and send the DBGp `init` packet — `<init xmlns="urn:debugger_protocol_v1" … xdebug:language_version="8.5.8"><engine version="3.5.3">Xdebug</engine>…`. That is exactly the init a VS Code "Listen for Xdebug" session consumes.

### Completion Notes List

- Xdebug is a **derived overlay only** — `Dockerfile.dev` + `compose.dev.yaml`; the base `compose.yaml` and official image are byte-for-byte unchanged (AD-10/AD-1). `make up` still runs the plain image.
- Xdebug **3.5.3** cleanly supports the base's **PHP 8.5.8** — no version pin needed (the story flagged this as the risk; it didn't materialize).
- **Trigger-based** (`start_with_request=trigger`) so debugging is opt-in per request (via `XDEBUG_TRIGGER`/`XDEBUG_SESSION`), not on every request — no perf tax on normal `up-dev` use.
- The **breakpoint-hit + variable-inspection** experience is the in-editor step (a browser/IDE can't be driven here); the headless DBGp `init` capture proves the transport the IDE rides on. `.vscode/launch.json` ships ready-to-use (port 9003, `custom_apps` ↔ `apps/` mapping for the Story 0.8 mount).
- Stack stopped after verification.

### File List

- `Dockerfile.dev` (new — official image + Xdebug via PECL)
- `dev/xdebug.ini` (new — Xdebug 3 step-debug config)
- `compose.dev.yaml` (new — dev overlay building the derived nextcloud image)
- `.vscode/launch.json` (new — "Listen for Xdebug" + path mapping)
- `Makefile` (modified — +`up-dev`)

## Change Log

- 2026-07-19 — Story drafted (create-story): Xdebug as a derived dev-only image (`Dockerfile.dev` + `compose.dev.yaml`), `.vscode/launch.json`, `make up-dev`. Base image/compose untouched (AD-10). Status → ready-for-dev.
- 2026-07-19 — Implemented (dev-story): `Dockerfile.dev` + `dev/xdebug.ini` + `compose.dev.yaml` + `.vscode/launch.json` + Makefile `up-dev`. Verified live on NC34.0.1: Xdebug 3.5.3 on PHP 8.5.8, config correct, base image clean (AD-10), and the DBGp step-debug pipe proven via a headless listener receiving Xdebug's `init` packet. Status → review.
