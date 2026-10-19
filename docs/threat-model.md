# Threat model

*What an attacker would want from this repository, and where they would try. Read before any security
work; the 🗡️ Breaker agent starts here.*

## Data this repository holds

- **The repository holds configuration, not data.** It is the configuration-as-code that stands up and
  describes a CESFAM's Nextcloud 34 suite on Nextcloud AIO: `provisioning/apps` and `provisioning/data` (the
  vendored apps and the data packages), `sites/` (the register), the server theme and the compose files.
  The code that applies it (the provisioning phases and app policy, the `aps-conecta` operator CLI and its
  systemd units) is in [instalador](https://github.com/APS-Conecta/instalador); the paths below that name
  it are instalador paths.
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
| Nextcloud web, WebDAV and mobile logins | anyone who can reach the domain | Nextcloud's built-in brute-force throttling (not configured here); `remember_login_cookie_lifetime 0` — no persistent "remember me" (instalador `provisioning/phases/05-security.sh:15`) |
| App availability for staff (instalador `provisioning/app-policy.sh`) | staff accounts | "admin keeps every app; every non-admin account gets the reduced set" (instalador `app-policy.sh:8`); `weather_status` restricted to keep outbound traffic (egress) off staff accounts |
| Public directory lookups | the server | `lookup_server ""` — no contact with Nextcloud's public lookup server (instalador `provisioning/phases/05-security.sh:20`) |
| Backups | the AIO borg container | daily borg backup at 04:00 Santiago time (posted as its UTC hour) to the configured location (instalador `host/aps-conecta`, `cmd_aio_wizard --respaldo`) |
| Secrets | operators | `.env` is generated with mode 600 (`make setup`) and never committed (`AGENTS.md`); `.gitleaksignore` exists |
| TLS and headers | the public internet | AIO's reverse proxy; nothing in this repository pins TLS versions or security headers |

## Declared HIPAA & System Safeguards (Hardened in Provisioning)

- **Audit logging:** `admin_audit` is enabled (instalador `provisioning/phases/05-security.sh`), ensuring all file reads, mutations, and shares are immutably logged for clinical oversight.
- **Session management:** `session_lifetime 900` (15-minute inactivity timeout) and `session_keepalive false` are enforced (instalador `provisioning/phases/05-security.sh`), preventing session takeover on shared clinical workstations.
- **Encryption at rest:** Server-side encryption (`encryption.enabled true`) is enforced (instalador `provisioning/phases/05-security.sh`). Host backup targets must reside on encrypted storage volumes.
- **Emergency access ("Break-Glass"):** `role-emergencia-breakglass` is provisioned (instalador `provisioning/phases/20-groups.sh`) to support auditable emergency overrides during clinical emergencies.

## Not declared in this repository — check each against the pinned image's defaults

- **Two-factor authentication:** no 2FA provider is enabled, and 2FA is not enforced for staff or admins.
- **Password policy:** only the breach check is set, and it is off (instalador `provisioning/app-policy.sh`):
  no password hash prefix reaches api.pwnedpasswords.com, and a known-breached password is no longer
  refused. Length, the common-password check and expiry are the image's defaults.
- **Sharing defaults:** nothing sets public-link passwords, expiry, or share-by-mail limits
  (`shareapi_*`).
- **Brute-force settings:** nothing beyond Nextcloud's defaults.

## Trust boundaries

- **The operator's host** — root, Docker and AIO's mastercontainer — is trusted.
- **Staff accounts are trusted, but each is a target:** one stolen password reaches every file that
  account can see.
- **External parties are untrusted:** link recipients, mail recipients, and anyone reaching the domain.
- **Sibling projects on the same host are out of scope and must not be touched** (`AGENTS.md`).

## Accepted risks

None recorded.
