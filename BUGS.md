# Bugs — APS Conecta Gestión

Known bugs, repro steps, and fix log. Repo-first SSOT; GitHub issues are the mirror.

All of B-001…B-007 came out of the **first end-to-end bring-up on a clean machine (2026-07-24)** — the
repo was v1 feature-complete on paper but had never actually been run start to finish.

## B-001 — `make seed` reports success when a phase fails
- **Status:** fixed
- **Repro:** make a phase fail (e.g. `ensure_app definitely-not-a-real-app`) and run `make seed`. Before
  the fix the runner printed `✓ phase …` and `provisioning complete` and exited **0**. Seen for real when
  an app-store timeout broke `ensure_app groupfolders`: all 12 group folders and the whole ACL matrix were
  skipped, and the run still looked green.
- **Cause:** `if ! ( set -e; . "$phase" ); then` — bash suppresses `errexit` inside a command used as an
  `if` condition, and the suppression reaches into the subshell, so `set -e` was a no-op.
- **Fix:** [#39](https://github.com/APS-Conecta/gestion/issues/39) — run the subshell as its own command
  and test `$?`; static guard added to `make test`.

## B-002 — `fix-mount-perms` leaves `apps/` and `themes/` read-only for the host developer
- **Status:** fixed
- **Repro:** host, repo root, as the normal dev user: `make up && touch themes/.probe` →
  `Permission denied`. `ls -ld themes` showed `775 www-data:www-data`.
- **Cause:** `chown www-data:www-data` gave the container write access but left the host side `r-x`,
  defeating the live-edit bind mount (AD-9). Container-side writes still worked, which hid it.
- **Fix:** [#40](https://github.com/APS-Conecta/gestion/issues/40) — chown to `www-data:$(HOST_GID)`
  with `g+w`, recursive.

## B-003 — `ensure_app` blames file permissions for every failure
- **Status:** fixed
- **Repro:** break app installation any way at all (e.g. unreachable app store) and run `make seed`.
  Message: `FAILED to install/enable app … (is custom_apps writable? see make up chown)` — even though the
  real cause was `cURL error 28: Operation timed out … 10256066 out of 12433483 bytes received` and
  `custom_apps` was writable.
- **Cause:** both `occ` calls discarded stderr, then the helper asserted a cause it never checked.
- **Fix:** [#41](https://github.com/APS-Conecta/gestion/issues/41) — surface `occ`'s own error.

## B-004 — unquoted `NEXTCLOUD_TRUSTED_DOMAINS` breaks sourcing `.env`
- **Status:** fixed
- **Repro:** `cp .env.example .env && make seed` → `.env: line 18: nextcloud: command not found`, on every
  run. Compose parsed the value fine; `provisioning/seed.sh:13` sources the same file with `.`, so the
  shell read `…=localhost` and tried to run `nextcloud` as a command.
- **Fix:** [#42](https://github.com/APS-Conecta/gestion/issues/42) — quote the value (Compose strips the
  quotes; verified with `docker compose config`).

## B-005 — `make office-eurooffice` prints `OFFICE_JWT_SECRET` to the terminal
- **Status:** fixed
- **Repro:** `make office-eurooffice` → the secret appears twice, once in make's echoed command line and
  once in `occ`'s `is now set to '…'` confirmation. It then lives in scrollback and in any captured log.
- **Fix:** [#43](https://github.com/APS-Conecta/gestion/issues/43) — `@` the recipe line, silence `occ`,
  print a neutral confirmation. Gate: `make office-eurooffice 2>&1 | grep -c "$OFFICE_JWT_SECRET"` = 0.

## B-006 — Xdebug log never writable, warning on every request
- **Status:** fixed
- **Repro:** `make up-dev`, then any `occ` call → `Xdebug: [Log Files] File '/tmp/xdebug.log' could not be
  opened.` Noise on every `make seed` line, and no Xdebug log when you need one.
- **Cause:** two stacked, both worth remembering. `/tmp` is world-writable, and Xdebug refuses to open a
  log it does not own in such a directory — so chowning the file fixed `www-data` but not root. And the
  entrypoint runs PHP as root at boot, so whoever ran first owned the file and locked the other out.
- **Fix:** [#44](https://github.com/APS-Conecta/gestion/issues/44) — log to `/var/log/xdebug/`, with the
  file pre-created for `www-data` in `Dockerfile.dev` so there is no race.

## B-007 — ODF (`odt`/`ods`/`odp`) opens read-only
- **Status:** open — needs an owner decision
- **Repro:** `make office-eurooffice`, then click an `.odt` in Files → nothing happens. Opened explicitly
  at `/apps/eurooffice/<fileid>` it renders correctly but with only `Archivo | Vista`, no ribbon and no
  "Edit". OOXML (`docx`/`xlsx`/`pptx`) edits normally.
- **Cause:** the connector declares ODF `lossy-edit`/`auto-convert` rather than `edit`
  (`apps/eurooffice/assets/document-formats/onlyoffice-docs-formats.json`), so it ships them unticked in
  the default-open matrix, and `make office-eurooffice` never sets `defFormats`.
- **Decision needed:** accept view-only ODF, or enable lossy editing. If the latter it must go through
  `make office-eurooffice` via `occ config:app:set eurooffice defFormats …` — never hand-ticked in the
  admin UI (AD-2). Tracked in [#45](https://github.com/APS-Conecta/gestion/issues/45).

<!-- Template:
## B-00N — <short title>
- **Status:** open | fixed
- **Repro:** <steps>
- **Fix:** <commit / PR when resolved>
-->
