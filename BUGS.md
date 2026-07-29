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
- **Status:** fixed
- **Repro:** `make office-eurooffice`, then click an `.odt` in Files → nothing happens. Opened explicitly
  at `/apps/eurooffice/<fileid>` it renders correctly but with only `Archivo | Vista`, no ribbon and no
  "Edit". OOXML (`docx`/`xlsx`/`pptx`) edits normally.
- **Cause:** the connector declares ODF `lossy-edit`/`auto-convert` rather than `edit`
  (`apps/eurooffice/assets/document-formats/onlyoffice-docs-formats.json`), so it shipped them unticked
  in the default-open matrix, and `make office-eurooffice` set neither format key.
- **Fix:** [#45](https://github.com/APS-Conecta/gestion/issues/45) — owner decision: enable lossy ODF
  editing, scripted in `make office-eurooffice` (AD-2, never hand-ticked). Two keys, not the one the
  issue named: `editFormats` sets the `edit` flag, `defFormats` makes a click in Files open here at
  all; `AppConfig.php:1209` crosses them. The conversion loss is accepted because the alternative was
  staff converting to `.docx` by hand — same fidelity loss, plus a duplicate file, against
  `docs/CONVENTIONS.md` § *Una sola copia viva*.

## B-008 — "Nextcloud" still leaks into two UI surfaces after white-labeling
- **Status:** fixed — (1) suppressed, (2) accepted as admin-only
- **Found:** 2026-07-28, during the Epic 5 close-out sweep. Not from the first bring-up like B-001…B-007.
- **Repro:**
  1. `/settings/user` (every user, not just admin) shows a link *"Razones para usar Nextcloud en su
     organización"* — a stock Nextcloud PDF promo. This is the more visible of the two: it is on a
     page ordinary staff open.
  2. `/settings/admin/eurooffice` — the sidebar entry and page title now read "Euro-Office", but the
     page **body** keeps ~20 translated strings saying "Nextcloud Office" (`l10n/es.json`).
- **Cause:** both are strings owned by upstream code, not by our theme. Nextcloud's theming app
  rewrites the product name in chrome it controls; it does not rewrite app-supplied copy.
- **Why not fixed:** for (2), a blanket rename would make some strings **false** — *"Conectarse al
  servidor de Nextcloud Office de demostración"* points at Nextcloud's own demo server, which is not
  Euro-Office. Forcing a value that then lies is precisely the failure this epic already paid for
  with `background_color` (see `docs/THEMING-MODEL.md` §4). For (1), the honest fix is disabling the
  promo rather than renaming it, which is a config decision, not a theming one.
- **Fix:** `b66c5ac` — (1) hides `.section.development-notice` from `server.css`. Hiding the one
  link revealed the rest of its container, so the whole vendor block goes: the promo PDF, the
  "developed by the Nextcloud community" credit and five social follow links. No config lever exists
  — `ServerDevNotice::getSection()` returns `null` only with a paid Nextcloud subscription. Gated in
  `scripts/test.sh` against the shipped template, because a selector that stops matching fails
  silently. (2) stays: a blanket rename would make some strings false (the "Nextcloud Office demo
  server" really is Nextcloud's). Tracked in [#48](https://github.com/APS-Conecta/gestion/issues/48).

## B-009 — `default_language=es_419` is inert; the browser decides the UI language
- **Status:** fixed
- **Found:** 2026-07-29, chasing the residual half of #50 (which document language new files get).
- **Repro:** on a seeded instance, `occ config:system:get default_language` returns `es_419`, yet
  `php -r '\OC::$server->get(\OCP\L10N\IFactory::class)->languageExists(null, "es_419")'` is
  **false**, and `findAvailableLanguages()` lists only `es`, `es_EC`, `es_MX` for Spanish. NC34
  core ships no `es_419` translation — there is no `core/l10n/es_419.json`.
- **Cause:** `es_419` is a valid ICU **locale** but not a **language**, and the two are separate
  config slots. `Factory::findLanguage()` step 4 returns `default_language` *only if*
  `languageExists()` accepts it, so this value could never be returned. What actually decided
  each user's language was the `Accept-Language` request header (step 4 reads it *before* the
  default, and persists the result as a per-user setting), falling back to `en` at step 5.
  `phases/10-locale.sh` asserted the opposite in a comment — *"es_419 = the UI translation
  Nextcloud actually ships"* — which is why it survived Epic 1 review.
- **Why nobody saw it:** `admin` carries an explicit `core lang = es` user setting, so the admin
  UI renders in Spanish. None of the four fixture staff users has one.
- **Fix:** `default_language = es`, plus `force_language = es` so a personal browser setting
  cannot change what staff see — the same call already made for `enforce_theme` and the editor's
  `customizationTheme`. `default_locale = es_CL` was correct and is unchanged: only the language
  slot was wrong. Tracked in [#60](https://github.com/APS-Conecta/gestion/issues/60). Subsumes [#50](https://github.com/APS-Conecta/gestion/issues/50), whose
  document-template question resolved through the same `getLanguageCode()`.

<!-- Template:
## B-00N — <short title>
- **Status:** open | fixed
- **Repro:** <steps>
- **Fix:** <commit / PR when resolved>
-->
