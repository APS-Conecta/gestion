---
baseline_commit: 4f2ac81cf0f4f8ba911f8afc80971c9b3d3205b3
---

# Story 0.2: Dual office suite — Collabora + Euro-Office, switchable, with editing smoke

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a developer,
I want each office backend (Collabora CODE and Euro-Office) as its own standalone container reachable from Nextcloud Office through its own connector, switchable one-at-a-time with a single command and an editing smoke each,
so that we can trial both suites end-to-end and pick the best, with the editing pipe proven before feature work.

## Acceptance Criteria

1. **Two office profiles, standalone servers.** `compose.yaml` defines an office backend per **compose profile**: profile `collabora` → a standalone `collabora/code` container; profile `eurooffice` → a standalone `ghcr.io/euro-office/documentserver` container. The core services (`db`, `redis`, `nextcloud`) carry **no** profile and always come up; each office server comes up **only** when its profile is activated. The built-in `richdocumentscode` app is **NOT** installed (AD-5). Both connectors — `richdocuments` (Collabora) and `eurooffice` (Euro-Office) — are installed on Nextcloud, each reached from Nextcloud Office at that server's own URL.

2. **`make office-collabora` activates exactly Collabora.** Running it: stops any running Euro-Office container; brings up the `collabora` profile; **enables** `richdocuments` and configures it server-side to `http://collabora:9980` (WOPI), browser-side to the published host URL, with the WOPI allow-list covering the compose subnet and Collabora running `--o:ssl.enable=false` (plain-HTTP dev); and **disables** `eurooffice`. After it completes, `occ app:list` shows `richdocuments` enabled and `eurooffice` disabled, and Collabora's `GET /hosting/discovery` returns HTTP 200 XML.

3. **`make office-eurooffice` activates exactly Euro-Office.** Running it: stops any running Collabora container; brings up the `eurooffice` profile; **enables** `eurooffice` and configures its `DocumentServerUrl` (browser), `DocumentServerInternalUrl` (`http://eurooffice/`, server-side), `StorageUrl` (Nextcloud as seen from the doc server), and shared `jwt_secret` (= `OFFICE_JWT_SECRET`); and **disables** `richdocuments`. After it completes, `occ app:list` shows `eurooffice` enabled and `richdocuments` disabled, Euro-Office `GET /healthcheck` returns HTTP 200, and `occ eurooffice:documentserver --check` reports the server reachable.

4. **Exactly one backend active (AD-11).** At no point are both office servers running or both connectors enabled. Each switch target leaves precisely one office container up and precisely one connector claiming the office MIME types (docx/xlsx/pptx) — no MIME-handler conflict.

5. **Editing smoke per backend.** A documented smoke (per backend) proves the pipe: the office server health endpoint returns 200, the active connector is enabled + configured (verifiable via `occ config:app:get`), and the connector's own reachability check passes (Collabora: `richdocuments:activate-config` succeeds / discovery reachable from the `nextcloud` container; Euro-Office: `occ eurooffice:documentserver --check` OK). The smoke **fails loudly** on a connector/host/round-trip error. Full in-browser co-editing is confirmed manually (open a doc as admin → it loads in the active editor).

6. **Secrets & portability preserved.** New office vars live in `.env.example` as placeholders (`OFFICE_JWT_SECRET`, `OFFICE_PORT`, Collabora admin creds) — no real secrets committed. Office server host ports bind **loopback only** (`127.0.0.1`, rule 16). Container↔container traffic uses compose **service names** (AD-8); `host.docker.internal` stays host↔container only. The core `make up` / Story 0.1 behavior is unchanged (office servers never start under the default profile).

## Tasks / Subtasks

- [x] **Task 1: Add the two office profiles to `compose.yaml`** (AC: 1, 4, 6)
  - [x] `collabora` service — image `collabora/code:latest` (NC34-compatible; pin an exact tag if byte-identical envs are needed later); `profiles: ["collabora"]`; `restart: "no"`; `cap_add: ["MKNOD"]`; publish `127.0.0.1:${OFFICE_PORT:?set OFFICE_PORT in .env}:9980`; env `aliasgroup1=http://localhost:${HTTP_PORT}` (the NC host the **browser** uses — a regex; escape dots on real domains, e.g. `cloud\.example\.com`), `username=${COLLABORA_ADMIN_USER:?...}`, `password=${COLLABORA_ADMIN_PASSWORD:?...}`, `dictionaries=en_US es_ES`, `DONT_GEN_SSL_CERT=true`, `extra_params=--o:ssl.enable=false` (no `ssl.termination` — there is no TLS-terminating proxy in dev).
  - [x] `eurooffice` service — image `ghcr.io/euro-office/documentserver:9.3.2` (current stable; `latest` also valid); `profiles: ["eurooffice"]`; `restart: "no"`; publish `127.0.0.1:${OFFICE_PORT:?...}:80` (internal port is **80**); env `JWT_ENABLED=true`, `JWT_SECRET=${OFFICE_JWT_SECRET:?set OFFICE_JWT_SECRET in .env}`, `ALLOW_PRIVATE_IP_ADDRESS=true` (**required** so the doc server may fetch documents over the private compose network). The image is self-contained (bundles its own PG/Redis/RabbitMQ) — do **not** wire it to the core `db`/`redis`.
  - [x] Both office servers publish on the **same** `${OFFICE_PORT}` (default 9980) — safe because AD-11 guarantees only one runs at a time, and it keeps the browser-facing URL identical across backends.
  - [x] Healthchecks: Collabora `curl -f http://localhost:9980/hosting/discovery`; Euro-Office `curl -f http://localhost/healthcheck`. **Verify `curl` exists in each image** before relying on it — if absent, use `wget -qO- ... || exit 1` or a bare TCP check. Document whichever you use.
  - [x] Do **not** give the office services any profile-less presence — confirm `docker compose up -d` (no `--profile`) still starts only `db`/`redis`/`nextcloud` (Story 0.1 unchanged).

- [x] **Task 2: Office vars in `.env.example`** (AC: 6)
  - [x] Add (placeholders only): `OFFICE_PORT=9980`; `OFFICE_JWT_SECRET=change-me-32-plus-char-hex` (note: ≥32 chars — `openssl rand -hex 32`); `COLLABORA_ADMIN_USER=admin`; `COLLABORA_ADMIN_PASSWORD=change-me-in-your-env`.
  - [x] Keep the existing `$$`-escaping note relevant to any `$` in secrets.

- [x] **Task 3: `Makefile` — `office-collabora` switch target** (AC: 2, 4)
  - [x] Define reusable macros near the top: `OCC = docker compose exec -T --user www-data nextcloud php occ`; source `OFFICE_PORT` / `OFFICE_JWT_SECRET` from `.env` (e.g. `OFFICE_PORT := $(shell grep -E '^OFFICE_PORT=' .env | cut -d= -f2)`).
  - [x] `office-collabora`: precheck `.env`; `docker compose stop eurooffice 2>/dev/null || true`; `docker compose --profile collabora up -d collabora`; wait for `/hosting/discovery` to answer; install/enable the connector (`$(OCC) app:install richdocuments || $(OCC) app:enable richdocuments`); wire it —
    - `$(OCC) config:app:set richdocuments wopi_url --value="http://collabora:9980"` (server-side, compose service name — AD-8),
    - `$(OCC) config:app:set richdocuments public_wopi_url --value="http://localhost:$(OFFICE_PORT)"` (browser-side, published port),
    - `$(OCC) config:app:set richdocuments wopi_allowlist --value="<compose subnet CIDR>"` (accept WOPI callbacks from Collabora's container),
    - `$(OCC) richdocuments:activate-config`;
    - then `$(OCC) app:disable eurooffice || true`.
  - [x] Handle the **WOPISrc round-trip** (see Dev Notes → *Known challenge*): Collabora must reach Nextcloud at a container-resolvable host, not the browser's `localhost`. Ensure `nextcloud` is a trusted domain and, if the editor fails to load the file, set `overwrite.cli.url` / `overwritehost` so the WOPISrc host is `nextcloud`. This is the crux of the story — verify a real round-trip, don't just set config.

- [x] **Task 4: `Makefile` — `office-eurooffice` switch target** (AC: 3, 4)
  - [x] `office-eurooffice`: precheck `.env`; `docker compose stop collabora 2>/dev/null || true`; `docker compose --profile eurooffice up -d eurooffice`; wait for `/healthcheck`; install/enable the connector (`$(OCC) app:install eurooffice || $(OCC) app:enable eurooffice` — see Dev Notes if the app store lacks it); wire it —
    - `$(OCC) config:app:set eurooffice DocumentServerUrl --value="http://localhost:$(OFFICE_PORT)/"` (browser),
    - `$(OCC) config:app:set eurooffice DocumentServerInternalUrl --value="http://eurooffice/"` (server-side, service name, port 80),
    - `$(OCC) config:app:set eurooffice StorageUrl --value="http://nextcloud/"` (Nextcloud as the doc server reaches it),
    - `$(OCC) config:app:set eurooffice jwt_secret --value="$(OFFICE_JWT_SECRET)"` (must equal the server `JWT_SECRET`),
    - optional dev: `$(OCC) config:app:set eurooffice verify_peer_off --value="true"`;
    - verify `$(OCC) eurooffice:documentserver --check`;
    - then `$(OCC) app:disable richdocuments || true`.
  - [x] Ensure `nextcloud` is in `NEXTCLOUD_TRUSTED_DOMAINS` (the `StorageUrl` host) so the doc server's callbacks are accepted — coordinate with `.env.example` (`NEXTCLOUD_TRUSTED_DOMAINS=localhost nextcloud`).

- [x] **Task 5: Editing smoke per backend** (AC: 5)
  - [x] Add a small smoke (script under `scripts/` or a `make office-smoke` target) that, for the **active** backend, asserts: (a) office health endpoint → 200; (b) active connector enabled (`occ app:list`); (c) connector configured (`occ config:app:get ... wopi_url` / `... DocumentServerInternalUrl` non-empty); (d) reachability check passes (Collabora discovery reachable from the `nextcloud` container via `docker compose exec nextcloud curl -f http://collabora:9980/hosting/discovery`; Euro-Office `occ eurooffice:documentserver --check`). Exit non-zero on any failure.
  - [x] Document that **full in-browser co-editing** (open a doc → editor renders → type) is a **manual** confirmation step per backend (a shell smoke proves wiring/round-trip, not the rendered editor).

- [x] **Task 6: Switch-integrity + portability check** (AC: 4, 6)
  - [x] After `make office-collabora` then `make office-eurooffice` (and back), confirm exactly one office container runs (`docker compose ps`) and exactly one connector is enabled each time.
  - [x] Confirm no absolute host paths / nothing VPS-specific added; office host ports bound to `127.0.0.1`.
  - [x] Resource check first (`free -h`) — Euro-Office wants ~4–8 GB; only one server runs at a time so the footprint stays modest. Stop the stack after verification.

## Dev Notes

**Extends Story 0.1** (`compose.yaml`, `.env.example`, `Makefile` at repo root). Reuse its patterns: `${VAR:?msg}` guards, loopback binds, `restart: "no"`, `occ` via `docker compose exec --user www-data nextcloud php occ`. Do not refactor Story 0.1's core services.

- **AD-5 (switchable office):** editing is served by a **standalone document-server container**, backend switchable between **Collabora CODE** (`collabora/code` via `richdocuments`/WOPI) and **Euro-Office** (`ghcr.io/euro-office/documentserver` via the `eurooffice` connector + shared JWT). Built-in `richdocumentscode` **not installed**. [Source: ARCHITECTURE-SPINE.md#AD-5]
- **AD-11 (one active):** the two backends are **never both active**; the switch brings up the chosen profile, enables its connector, disables the other — exactly one connector claims each MIME type. [Source: #AD-11]
- **AD-8 (networking):** container↔container via **compose service names** (`http://collabora:9980`, `http://eurooffice/`, `http://nextcloud/`); `host.docker.internal` is host↔container only. The **browser-facing** URLs (`public_wopi_url`, `DocumentServerUrl`) use the published `127.0.0.1:${OFFICE_PORT}`. [Source: #AD-8; docs/ARCHITECTURE.md#Runtime topology]
- **AD-1 (no fork) / NFR-5:** official images + `occ`/app config only; no core patches. [Source: #AD-1]

### Verified deployment specifics (web-researched 2026-07-19 — copy verbatim)

**Collabora CODE** (`collabora/code`; internal port 9980; `--cap-add MKNOD` required):
- Env: `aliasgroup1` = full URL of the NC host the browser uses, e.g. `http://localhost:${HTTP_PORT}` (a regex — escape dots on real domains). **Prefer `aliasgroup1` over the deprecated `domain=`** (modern images warn on `domain`). `username`/`password` = admin console (`/browser/dist/admin/admin.html`); `dictionaries=en_US es_ES`; `DONT_GEN_SSL_CERT=true`; `extra_params=--o:ssl.enable=false`.
- Dev TLS: `--o:ssl.enable=false` → coolwsd serves **plain HTTP** on 9980, so `wopi_url`/`public_wopi_url` use `http://`. Add `--o:ssl.termination=true` **only** with a TLS-terminating proxy (we have none → omit it, else discovery advertises broken `https://` links).
- richdocuments config: `wopi_url` (server-side, `http://collabora:9980`), `public_wopi_url` (browser, `http://localhost:${OFFICE_PORT}`), `wopi_allowlist` (CIDR of the compose subnet), then `occ richdocuments:activate-config`. Known flake: `activate-config` doesn't always "take" — fallback is saving the WOPI host once in Admin → Nextcloud Office UI (richdocuments #2201/#1007).
- **NC34 → richdocuments 11.0.1** from the app store (`occ app:install richdocuments`). Do **not** use the GitHub `main` branch (it targets NC35). Do **not** install `richdocumentscode` (the bundled CODE server — separate app, conflicts).
- Smoke endpoints: `GET /hosting/discovery` (XML), `GET /hosting/capabilities` (JSON) — 200 = up + WOPI reachable.

**Euro-Office** (`ghcr.io/euro-office/documentserver:9.3.2`; internal port **80**; AGPL fork of ONLYOFFICE Document Server — ONLYOFFICE connector docs are the de-facto reference for unspecified keys):
- Env: `JWT_ENABLED=true`, `JWT_SECRET` (≥32 chars, HS256), `JWT_HEADER` (default `Authorization`), **`ALLOW_PRIVATE_IP_ADDRESS=true`** (the classic ONLYOFFICE gotcha — required for same-network compose so the server may fetch from NC's private IP). Healthcheck `GET /healthcheck` → `true`. Image is self-contained (bundles PG/Redis/RabbitMQ); needs ~4 GB RAM.
- Connector app id **`eurooffice`** (current v11.0.1; `info.xml` min-version 33 / max-version 35 → **NC34 supported**). Install: try the app store (`occ app:install eurooffice`); if the store lacks it, the fallback is cloning `github.com/euro-office/eurooffice-nextcloud` into `custom_apps` + `npm run build` + `composer install` — but that needs the `apps/` mount (Story 0.8). **If `app:install eurooffice` fails, surface it** rather than pulling Story 0.8 forward silently.
- Config keys (`occ config:app:set eurooffice <key> --value=<v>`): `DocumentServerUrl` (browser), `DocumentServerInternalUrl` (server-side, `http://eurooffice/`), `StorageUrl` (NC as the server reaches it, `http://nextcloud/`), `jwt_secret` (= server `JWT_SECRET`), `jwt_header` (= server `JWT_HEADER`), `verify_peer_off=true` (dev/self-signed). Verify: `occ eurooffice:documentserver --check`.

### Known challenge — the WOPISrc / callback round-trip (the crux; why Epic 4 is early)

Both office servers must fetch/write the file **back** from Nextcloud, and Nextcloud embeds its own address (WOPISrc for Collabora; the storage callback for Euro-Office) based on the request. The browser reaches NC at `localhost:${HTTP_PORT}`, but **inside the office container `localhost` is the office server itself** — so a naïve `localhost` WOPISrc fails. Resolution: the office server reaches NC by **compose service name** (`http://nextcloud/`), so (a) add `nextcloud` to `NEXTCLOUD_TRUSTED_DOMAINS`; (b) for Euro-Office, `StorageUrl=http://nextcloud/` + `ALLOW_PRIVATE_IP_ADDRESS=true` covers it; (c) for Collabora, if the editor loads but the document won't open, set `overwrite.cli.url`/`overwritehost` so the generated WOPISrc host is `nextcloud`. **Verify an actual round-trip** (a document opens and saves), not just that config was set — this is the single most likely failure point.

### Project Structure Notes

- **Files touched (all UPDATE, at repo root):** `compose.yaml` (+2 profiled services), `.env.example` (+office vars), `Makefile` (+`office-collabora`, +`office-eurooffice`, +optional `office-smoke`). Optionally a `scripts/office-smoke.sh`. No new top-level dirs; matches ARCHITECTURE-SPINE.md#Structural Seed.
- **Port model:** single `OFFICE_PORT` (default 9980), loopback-bound, shared by both backends (only one runs — AD-11). Collabora maps `:9980`→9980, Euro-Office `:9980`→80.
- **Scope guards (do NOT do here):** Xdebug/`compose.dev.yaml` = Story 0.3; `smoke`/`test`/`seed` general gate = Stories 0.4/0.5; `apps/`+`themes/` bind mounts = Story 0.8 (only touch `custom_apps` if the `eurooffice` app-store install genuinely fails, and flag it). Picking the winning suite is deferred (post-comparison).

### References

- [Source: docs/planning/epics.md#Story 0.2] — user story + ACs + governing ARs (AR-5, AR-8, AR-13)
- [Source: docs/planning/architecture/architecture-apsconecta-gestion-2026-07-18/ARCHITECTURE-SPINE.md#AD-5, #AD-8, #AD-11, #Stack]
- [Source: docs/ARCHITECTURE.md#Runtime topology, #Data ownership & flows (editing flow)]
- [Source: docs/planning/implementation/0-1-portable-core-compose-stack.md] — compose/Makefile/.env pattern this story extends
- [Source: docs/planning/prds/prd-apsconecta-gestion-2026-07-18/prd.md#FR-15, #FR-16, #FR-17] in-browser editing / concurrent co-edit / OSS formats
- Collabora: nextcloud/richdocuments `docs/install.md`; collaboraonline.com CODE Docker quick-tryout; CollaboraOnline/online #4594 (`domain`→`aliasgroup1`); apps.nextcloud.com/apps/richdocuments (11.0.1→NC34)
- Euro-Office: euro-office.github.io/documentation (installation/docker, integration/nextcloud, configuration/server); github.com/euro-office/eurooffice-nextcloud (`info.xml`, `README.md`, `lib/AppConfig.php`); ONLYOFFICE connector docs (de-facto reference)

## Dev Agent Record

### Agent Model Used

claude-opus-4-8[1m] (Claude Opus 4.8, 1M context)

### Debug Log References

Verified live against the NC34.0.1 + PG18.4 stack (`make up`), switching each way:

- `make office-collabora` → pulled `collabora/code:latest` (Collabora Online Development Edition 26.04.2.2); `richdocuments 11.0.1` installed+enabled; `richdocuments:activate-config` → ✓ discovery fetched, ✓ valid mimetypes, ✓ valid capabilities, ✓ WOPI server detected. Smoke **PASS**.
- `make office-eurooffice` → pulled `ghcr.io/euro-office/documentserver:latest` (doc server 9.3.1.37); `eurooffice 11.0.1` installed+enabled; `occ eurooffice:documentserver --check` → "Document server … successfully connected". Smoke **PASS**.
- Switch integrity (both directions): exactly one connector enabled and one office container running each time — `richdocuments`/`eurooffice` mutually exclusive (AD-11). `richdocumentscode` NOT installed. Default `docker compose up -d` starts core only (db/redis/nextcloud) — Story 0.1 unchanged.

**Issues found & fixed during verification** (this is why the editing story runs early):
1. **postgres-style crash — Collabora `ca-chain.cert.pem`:** `DONT_GEN_SSL_CERT=true` skipped cert generation, but coolwsd still references the ca-chain path on init and crashed. Fix: drop `DONT_GEN_SSL_CERT` (let the entrypoint generate certs).
2. **`--o:ssl.enable=false` ignored:** this CODE image always serves **HTTPS** (self-signed) on 9980 (HTTP 000, HTTPS 200). Fix: embrace it — wire `richdocuments` over `https://` with `disable_certificate_verification=yes`; smoke uses `curl -k`.
3. **`public_wopi_url` reset by `activate-config`:** it rewrote the browser URL to `https://collabora:9980` (not host-resolvable). Fix: set `public_wopi_url=https://localhost:${OFFICE_PORT}` **after** `activate-config`.
4. **Collabora image has no `curl`/`sh`:** the compose curl healthcheck couldn't run. Fix: drop it — the image ships its own `coolwsd --probe` healthcheck; reachability asserted host-side + in the smoke.
5. **Euro-Office image tag:** `ghcr.io/euro-office/documentserver:9.3.2`/`:9.3.1` are NOT published (only CI build tags + `latest`). Fix: pin `:latest`.
6. **Euro-Office docserver → NC returned HTTP 400:** the running instance's `trusted_domains` (set at install to `localhost`) lacked `nextcloud` (the `StorageUrl` host), so the doc server couldn't download the test doc. Fix: `.env.example` now ships `NEXTCLOUD_TRUSTED_DOMAINS=localhost nextcloud`, and `office-eurooffice` idempotently adds `nextcloud` to `trusted_domains` (install-time env doesn't retro-apply).

### Completion Notes List

- **Wiring verified end-to-end for both backends; switching is bidirectional and AD-11-clean.** The smoke asserts server health (host + server-side) + connector configured + connector reachability check, and fails loudly (observed failing correctly before each fix).
- **In-browser co-editing is the documented manual step** (AC5): I cannot drive a browser here. Two dev prerequisites are documented for the human check: (a) accept Collabora's self-signed cert once at `https://localhost:${OFFICE_PORT}`; (b) the office server reaches Nextcloud for the callback via the compose service name / `host.docker.internal` (added to both office services). The pipe is proven at the WOPI/JWT level.
- **Resource note:** Euro-Office is heavy (~4 GB); only one backend runs at a time (AD-11), so the footprint stays modest. Stack stopped after verification.
- No unit-test framework exists yet (the `test`/`smoke` gate is Story 0.4); verification is the live switch + `office-smoke.sh`, matching Story 0.1's approach.

### File List

- `compose.yaml` (modified — +`collabora` and +`eurooffice` profiled services)
- `.env.example` (modified — +office vars: `OFFICE_PORT`, `OFFICE_JWT_SECRET`, Collabora admin creds; `NEXTCLOUD_TRUSTED_DOMAINS` += `nextcloud`)
- `Makefile` (modified — +`office-collabora`, +`office-eurooffice`, +`office-smoke`, +`office-down`)
- `scripts/office-smoke.sh` (new — active-backend editing smoke)

## Change Log

- 2026-07-19 — Story drafted (create-story): dual switchable office suite (Collabora + Euro-Office) via compose profiles + Makefile switch targets, with per-backend editing smoke. Deployment specifics web-verified (Collabora `richdocuments`/WOPI; Euro-Office `eurooffice`/JWT). Status → ready-for-dev.
- 2026-07-19 — Implemented (dev-story): compose profiles + `.env.example` office vars + Makefile switch targets + `scripts/office-smoke.sh`. Verified both backends live on NC34/PG18 with bidirectional switching (AD-11). Six integration issues found & fixed (see Debug Log). Collabora runs over self-signed HTTPS; Euro-Office image pinned `:latest` (no semver tag published); `nextcloud` added to trusted_domains for the Euro-Office callback. Status → review.
