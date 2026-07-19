# PR 7 — Code Review Handoff (Story 0.1: Portable Core Compose Stack)

> **Purpose:** Work order for a follow-up Claude session. Self-contained — you do not need
> the originating conversation to act on this. Review method: xhigh multi-agent
> (`/code-review ultra`), 6 finder angles + 11 independent adversarial verifiers.
> **13 candidates verified, 1 refuted, 8 reported.** Reviewed against
> `git diff 5e137f7d^ 5e137f7d` in `/opt/apsconecta-gestion`.
>
> Files in scope: `compose.yaml`, `Makefile`, `.env.example`,
> `docs/planning/implementation/0-1-portable-core-compose-stack.md`, `sprint-status.yaml`.

## TL;DR — what to fix first

**#1 and #2 are blockers.** Both defeat AC-1's "clone → `make up` → done" promise; #1 also
violates global rule 16 (bind loopback, never `0.0.0.0`). They share one fix direction:
**enforce `.env` + add `${VAR:?}` guards + bind loopback.** Everything else is a quick
follow-up in the same three files.

---

## 🔴 Blockers / correctness (CONFIRMED)

### #1 — Nextcloud port binds `0.0.0.0`, exposing admin panel to the LAN
- **Where:** `compose.yaml:36`
- **What:** `ports: "${HTTP_PORT}:80"` publishes on all interfaces, not localhost. On shared
  Wi-Fi any host can reach `http://<dev-ip>:8080`; with `.env.example` placeholders,
  `admin / change-me-in-your-env` logs in. Contradicts AC-1's documented `http://localhost`
  **and violates global rule 16** (internal services bind `127.0.0.1`).
- **Fix:** `- "127.0.0.1:${HTTP_PORT}:80"`

### #2 — No env-var guards → clean clone silently mis-boots
- **Where:** `compose.yaml:16` & `:36`, `Makefile:11`
- **What:** Every `${VAR}` lacks a default / `:?` guard, and `make up` runs
  `docker compose up -d` without copying or checking `.env` (the `cp .env.example .env` step
  is a manual, unenforced doc instruction; Compose auto-loads `.env`, never `.env.example`).
  On a fresh clone that runs `make up` first:
  - `POSTGRES_PASSWORD` → empty → postgres aborts (*"You must specify POSTGRES_PASSWORD to a
    non-empty value"*) → db never healthy → `depends_on: service_healthy` aborts nextcloud.
  - `HTTP_PORT` → empty → publish spec becomes `:80` → random host port.
  - User sees a postgres crash-loop instead of "copy your .env first". **Breaks AC-1.**
- **Fix:** add `${VAR:?message}` guards to required vars, **and/or** make the `up` target copy
  `.env` from `.env.example` when missing (e.g. `[ -f .env ] || cp .env.example .env`).

### #3 — `$` in a password gets re-interpolated (reproduced with `docker compose config`)
- **Where:** `.env.example:10`
- **What:** A strong password like `p@ss$word2026` → Compose reads `$word2026` as an undefined
  var → effective value becomes `p@ss` (+ warning). Dev can't log in with the string they
  typed; `POSTGRES_PASSWORD` mangled the same way. No escaping guidance in `.env.example`.
- **Fix:** add a comment documenting `$$` escaping; prefer placeholders without `$`.

### #4 — Default `HTTP_PORT=8080` is collision-prone
- **Where:** `.env.example:6`
- **What:** 8080 is commonly occupied → `make up` fails with *"Bind for 0.0.0.0:8080 failed:
  port is already allocated"*. The team's own verification hit this (fell back to 8091).
- **Fix:** pick a less-common default port.

### #5 — AC-2 doc overclaims Redis as `memcache.local`
- **Where:** `docs/planning/implementation/0-1-portable-core-compose-stack.md:18`
- **What:** AC-2 checked off as *"Redis is active as memcache (local + locking)"*, but the
  official image wires Redis only to `memcache.distributed` + `memcache.locking`;
  `memcache.local` stays APCu. Task 4 / debug log verify only distributed+locking.
  Implementation is functionally fine — the **AC text overclaims**.
- **Fix:** reword AC-2 to "distributed + locking".

---

## 🟡 Hygiene (PLAUSIBLE / cleanup)

### #6 — db healthcheck has no `start_period`
- **Where:** `compose.yaml:17`
- **What:** `retries(5) × interval(10s)` ≈ 50s first-boot grace. Slow-disk first `initdb` can
  exceed it → db flips unhealthy → `make up` aborts on the clean-clone scenario AC-1 targets.
- **Fix:** add `start_period: 30s`–`60s`.

### #7 — `nextcloud` service has no healthcheck
- **Where:** `compose.yaml:34`
- **What:** db and redis have healthchecks; nextcloud doesn't. Story 0.2 (Collabora) and 0.4
  (smoke gate) can't `depend_on: nextcloud: condition: service_healthy` and will bolt on
  sleep/poll bandaids.
- **Fix:** add a `curl -f localhost/status.php` healthcheck once, here at the foundation.

### #8 — `restart: unless-stopped` on a per-dev local dev stack
- **Where:** `compose.yaml:10` (also `:25`, `:34`)
- **What:** On host/daemon reboot the stack silently auto-starts, consuming RAM and holding the
  port — contrary to the story's own "stopped to free shared-host resources" note.
- **Fix:** `restart: no` for a `make up`/`make down` local stack.

---

## ✅ Refuted (do NOT action)
- `pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}` with unset vars — claimed to break on
  empty args. **Refuted:** `sh -c` word-splitting collapses empty regions; no empty-string
  args are passed. The command itself is fine. (The real empty-password db failure is #2, via
  a different mechanism.)

---

## Suggested implementation order
1. **#1 + #2 together** in `compose.yaml` + `Makefile` (blocker cluster, one PR).
2. **#4 + #3** in `.env.example` (port default + `$$` escaping comment).
3. **#6 + #7 + #8** in `compose.yaml` (healthcheck/restart hygiene).
4. **#5** doc wording fix in the story file.

## Verify after fixing (must actually run, not assume)
- Clean-clone dry run: fresh checkout, `make up` **without** creating `.env` → expect a clear
  guard message, **not** a postgres crash-loop.
- `docker compose config` → confirm `127.0.0.1:` prefix on the nextcloud port publish.
- With a `$`-containing password in `.env`, `docker compose config` → password renders intact.
- Live: `occ config:system:get memcache.local` → confirm reality matches the reworded AC-2.
