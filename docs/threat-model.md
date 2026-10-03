# Threat model

*What an attacker would want from this repository, and where they would try. Read before any security
work; the 🗡️ Breaker agent starts here.*

## Data this repository holds

- **The repository holds configuration, not data.** It is the configuration-as-code that stands up and
  converges a CESFAM's Nextcloud 34 suite on Nextcloud AIO: `provisioning/` (phases, app policy, seed
  data), `host/` (the `aps-conecta` operator CLI and systemd units), `sites/`, the compose files and
  nginx configs.
- **The repository holds no patient data.** Development uses synthetic fixtures only (`README.md`,
  `AGENTS.md` invariants).
- **The platform is not meant to hold patient data** (`AGENTS.md`), but nothing stops staff from
  uploading clinical files to its Files, Talk or Office. Treat every account, share and backup as if
  they held patient data: every setting this repository applies or leaves at a default is a safeguard.

## What an attacker wants

1. **Staff accounts.** Through password guessing, a weak password policy, no second factor, or
   long-lived sessions — every staff account reaches patient documents.
2. **Shared links.** Public shares without a password or expiry, or shares by mail to outsiders, would
   carry patient files out.
3. **Backups and the server.** An unencrypted backup copy, or a secret committed to the repository
   (`.env`, AIO passwords), would expose everything at once.
4. **Untraceable access.** Without audit logging, nobody can say who opened or shared what.
5. **The transport.** Weak TLS or missing security headers would let traffic or a session be
   intercepted or framed.

## Entry points

| Entry point | Who can use it | What protects it today |
|---|---|---|
| Nextcloud web, WebDAV and mobile logins | anyone who can reach the domain | Nextcloud's built-in brute-force throttling (not configured here); `remember_login_cookie_lifetime 0` — no persistent "remember me" (`provisioning/phases/05-security.sh:15`) |
| App availability for staff (`provisioning/app-policy.sh`) | staff accounts | "admin keeps every app; every non-admin account gets the reduced set" (`app-policy.sh:8`); `weather_status` restricted to keep outbound traffic (egress) off staff accounts |
| Public directory lookups | the server | `lookup_server ""` — no contact with Nextcloud's public lookup server (`provisioning/phases/05-security.sh:20`) |
| Backups | the AIO borg container | daily borg backup at 04:00 Santiago time (posted as its UTC hour) to the configured location (`host/aps-conecta`, `cmd_aio_wizard --respaldo`) |
| Secrets | operators | `.env` is generated with mode 600 (`make setup`) and never committed (`AGENTS.md`); `.gitleaksignore` exists |
| TLS and headers | the public internet | AIO's reverse proxy; nothing in this repository pins TLS versions or security headers |

## Not declared in this repository — check each against the pinned image's defaults

- **Two-factor authentication:** no 2FA provider is enabled, and 2FA is not enforced for staff or admins.
- **Password policy:** only the breach check is set, and it is off (`provisioning/app-policy.sh`):
  no password hash prefix reaches api.pwnedpasswords.com, and a known-breached password is no longer
  refused. Length, the common-password check and expiry are the image's defaults.
- **Audit logging:** `admin_audit` is not enabled, so there is no record of file access or shares.
- **Sharing defaults:** nothing sets public-link passwords, expiry, or share-by-mail limits
  (`shareapi_*`).
- **Encryption at rest:** server-side encryption is not enabled. Check whether the backup target is
  encrypted.
- **Brute-force settings:** nothing beyond Nextcloud's defaults.

Each item above is a Breaker target. The fix is a provisioning phase that sets it, plus an assertion in
`make test` / `scripts/smoke.sh`, matching how `app-policy.sh` is both applied and asserted.

## Trust boundaries

- **The operator's host** — root, Docker and AIO's mastercontainer — is trusted.
- **Staff accounts are trusted, but each is a target:** one stolen password reaches every file that
  account can see.
- **External parties are untrusted:** link recipients, mail recipients, and anyone reaching the domain.
- **Sibling projects on the same host are out of scope and must not be touched** (`AGENTS.md`).

## Accepted risks

None recorded.
