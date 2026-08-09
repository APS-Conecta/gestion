# Bugs — APS Conecta Gestión

Fix log: what was wrong, and why the fix is right. **What is open right now lives in the issue
tracker** — [`label:bug`](https://github.com/APS-Conecta/gestion/issues?q=is%3Aissue+is%3Aopen+label%3Abug)
is the authority, and this file deliberately does not restate its count. It said "No bug is currently
open" until 2026-08-08, while three were: a sentence that can only ever be right by accident is the
always-green failure B-001 is in this very table for.

B-001…B-007 all came out of the **first end-to-end bring-up on a clean machine (2026-07-24)** — the repo
was v1 feature-complete on paper but had never been run start to finish. B-008…B-012 came out of Epic 5
and the hardening pass that followed. B-013 came out of looking at the screens that only appear when
something is wrong — the one class no routine check ever renders.

Each row names the cause and where the fix lives. The reasoning that made a fix non-obvious is a comment
beside the code it protects, not here — a second copy desyncs the day it is written.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| B-001 | `make seed` reported success when a phase failed | `if ! ( set -e; … )` — bash suppresses `errexit` inside a command used as an `if` condition, and the suppression reaches into the subshell | [#39](https://github.com/APS-Conecta/gestion/issues/39) — run the subshell as its own command and test `$?`. Gated in `scripts/test.sh` |
| B-002 | `apps/`, `themes/` read-only for the host developer | `chown www-data:www-data` gave the container write access but left the host side `r-x` | [#40](https://github.com/APS-Conecta/gestion/issues/40) — chown to `www-data:$(HOST_GID)` plus `g+w` (`fix-mount-perms`) |
| B-003 | `ensure_app` blamed file permissions for every failure | both `occ` calls discarded stderr, then the helper asserted a cause it never checked | [#41](https://github.com/APS-Conecta/gestion/issues/41) — surface `occ`'s own error |
| B-004 | unquoted `NEXTCLOUD_TRUSTED_DOMAINS` broke `.env` | the value was sourced by the shell, so a space ran `nextcloud` as a command | [#42](https://github.com/APS-Conecta/gestion/issues/42) — quote it. `.env` is now parsed rather than sourced (`scripts/env.sh`) |
| B-005 | `make office-eurooffice` printed `OFFICE_JWT_SECRET` | the recipe line was echoed, and `occ` echoed it back | [#43](https://github.com/APS-Conecta/gestion/issues/43) — `@` the line, silence `occ`, print a neutral confirmation |
| B-006 | Xdebug log never writable; a warning on every request | `/tmp` is world-writable and Xdebug refuses to open a log it does not own there | [#44](https://github.com/APS-Conecta/gestion/issues/44) — later simplified away: no log file at all (`dev/xdebug.ini`) |
| B-007 | ODF opened read-only | the connector declares ODF `lossy-edit`/`auto-convert`, not `edit` | [#45](https://github.com/APS-Conecta/gestion/issues/45) — owner decision: lossy ODF editing on, via `editFormats`/`defFormats` in `14-office.sh` |
| B-008 | "Nextcloud" leaked into two UI surfaces after white-labeling | both strings are owned by upstream code, not by the theme, and the vendor block has no config lever without a paid subscription | `b66c5ac` — `server.css` hides `.section.development-notice`; the second surface accepted as admin-only. Both gated in `scripts/test.sh` |
| B-009 | `default_language=es_419` inert; the browser chose the UI language | `es_419` is a valid ICU **locale** but not a **language**, so `languageExists()` rejects it | `default_language=es` plus `force_language=es` (`10-locale.sh`). AD-7 corrected |
| B-010 | the eurooffice patches turned admin › Overview permanently red | patched files invalidate the `appinfo/signature.json` a store app ships | [#71](https://github.com/APS-Conecta/gestion/issues/71) — `12-apps.sh` drops the signature it just invalidated. Gated in `scripts/smoke.sh` |
| B-011 | the brand lockups rendered Georgia, not Fraunces | an SVG served as an image is an isolated document and cannot reach `server.css`'s `@font-face` | `themes/apsconecta/tools/embed-fonts.py` embeds a per-lockup subset as a `data:` URL, and the OS fallbacks are removed so a miss fails visibly. Gated in `scripts/test.sh` |
| B-012 | the header rules leaked onto public share pages; phase 30 discarded its own logs | `#header:not(.header-guest) #nextcloud` also matched `layout.public.php`, where that id is a `<div>` with content; and `ensure_groupfolder … >/dev/null` swallowed the lines `seed-idempotent.sh` greps for, so the gate could not fail on any group folder | `a36b458` — scope on `a#nextcloud`; drop the unused id `printf` and the redirect. Both gated in `scripts/test.sh` |
| B-014 | a certificate re-import would have reported the seed idempotent | `ensure_aia_intermediate` logs `certs: imported …`, and no alternative in `seed-idempotent.sh`'s `WRITES` matched that verb — so the one write in `provisioning/` outside the vocabulary was invisible to the gate. The meta-gate added in #126 only checks the other direction (every alternative still matches some log line) and says so at `test.sh:50-52` | `^ +certs: imported ` added to `WRITES`, **anchored**: the noop line for the same helper reads `certs: <name> already imported`, so an unanchored ` imported` would match it and redden every second seed. Both halves gated in `scripts/test.sh` |
| B-013 | eight screens — maintenance, the two upgrade screens, 429, the fatal exception, untrusted domain, the config error and the three setup screens — rendered in stock Nextcloud blue with Nextcloud's own logo | they render through the legacy `Template::printPage()`, which dispatches no `BeforeTemplateRenderedEvent`, and that event is the only thing that adds `server.css`; on an untrusted host `ThemingDefaults` is bypassed too, so even the identity strings came from a raw `\OC_Defaults` | [ADR-0004](docs/adr/0004-branding-the-legacy-render-path.md) — `themes/apsconecta/core/css/guest.css`, `themes/apsconecta/defaults.php`, a two-key `core/l10n/es.json` and the three icon files. Gated in both `scripts/test.sh` (enumeration of the 7 render sites) and `scripts/smoke.sh` (the screen itself) |

## Reporting a new one

Add a row. Put the reasoning that makes the fix non-obvious in a comment beside the code, and the gate
that stops it recurring in `scripts/test.sh` or `scripts/smoke.sh`.

```
| B-0NN | <symptom> | <cause> | <commit or issue> |
```
