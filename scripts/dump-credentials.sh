#!/usr/bin/env bash
# Generate CREDENTIALS.local.md — a single, human-readable sheet of EVERY password/secret this stack
# uses, read straight from .env (the source of truth) so it can never silently drift.
#
# SECURITY: the OUTPUT holds real secrets → it is gitignored and written mode 600. This SCRIPT holds
# no secrets (only key names), so it is safe to commit. Values are written to the file only, never to
# stdout — nothing here echoes a secret. Regenerate any time with `make credentials` (e.g. after a
# rotation). The canonical vault stays Proton Pass; this file is a repo-local convenience mirror.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="$ROOT/.env"
OUT="$ROOT/CREDENTIALS.local.md"

[ -f "$ENV" ] || { echo "No .env at $ENV — run: cp .env.example .env  (then fill in real values)"; exit 1; }

# Read a raw KEY=VALUE from .env WITHOUT sourcing it (values may contain spaces, e.g. trusted domains).
getenv() { grep -E "^$1=" "$ENV" | head -1 | cut -d= -f2-; }

HTTP_PORT="$(getenv HTTP_PORT)"
OFFICE_PORT="$(getenv OFFICE_PORT)"
NC_USER="$(getenv NEXTCLOUD_ADMIN_USER)"
NC_PASS="$(getenv NEXTCLOUD_ADMIN_PASSWORD)"
PG_DB="$(getenv POSTGRES_DB)"
PG_USER="$(getenv POSTGRES_USER)"
PG_PASS="$(getenv POSTGRES_PASSWORD)"
CO_USER="$(getenv COLLABORA_ADMIN_USER)"
CO_PASS="$(getenv COLLABORA_ADMIN_PASSWORD)"
JWT="$(getenv OFFICE_JWT_SECRET)"
FIX_PASS="$(getenv FIXTURE_USER_PASSWORD)"

# Create with locked-down perms from the very first byte (umask, then write).
umask 177
cat > "$OUT" <<EOF
# APS Conecta Gestión — Credentials (LOCAL, do not commit)

> ⚠️ **This file contains real secrets.** It is **gitignored** and **mode 600**. Never commit it, never
> paste its contents anywhere shared. Source of truth = \`.env\`; this sheet is **generated** from it by
> \`make credentials\` — regenerate after any rotation, don't hand-edit. Canonical vault = **Proton Pass**.
>
> Generated from \`.env\`. Ports: app \`:$HTTP_PORT\` · office \`:$OFFICE_PORT\` (both bind \`127.0.0.1\` only).

## Access URLs (loopback — forward the port to your browser)

| What | URL |
|------|-----|
| Nextcloud (the app) | http://localhost:$HTTP_PORT |
| Collabora admin console | http://localhost:$OFFICE_PORT/browser/dist/admin/admin.html |

## 1. Nextcloud — admin account
| Item | Value |
|------|-------|
| Username | \`$NC_USER\` |
| Password | \`$NC_PASS\` |
| Where | \`.env\` → \`NEXTCLOUD_ADMIN_PASSWORD\`; created on first boot by the \`nextcloud\` service |
| Use | Full admin of the Nextcloud instance (theming, apps, users) |

## 2. PostgreSQL — database
| Item | Value |
|------|-------|
| Database | \`$PG_DB\` |
| Username | \`$PG_USER\` |
| Password | \`$PG_PASS\` |
| Where | \`.env\` → \`POSTGRES_PASSWORD\`; used by \`db\` + \`nextcloud\` services |
| Host | Not published to the host — reachable only inside the compose network as \`db:5432\` |

## 3. Collabora CODE — admin console
| Item | Value |
|------|-------|
| Username | \`$CO_USER\` |
| Password | \`$CO_PASS\` |
| Where | \`.env\` → \`COLLABORA_ADMIN_PASSWORD\`; passed to the \`collabora\` service |
| Use | coolwsd admin console (active sessions/metrics) — only when the Collabora backend is up |

## 4. Euro-Office — document-server JWT
| Item | Value |
|------|-------|
| Shared secret | \`$JWT\` |
| Where | \`.env\` → \`OFFICE_JWT_SECRET\`; documentserver \`JWT_SECRET\` ↔ \`eurooffice\` connector \`jwt_secret\` |
| Use | Signs traffic between Nextcloud and Euro-Office — only when the Euro-Office backend is up. Not a login. |

## 5. Fixture dev users (synthetic — \`make seed\`, phase 50)
Throwaway accounts on the local instance (Story 0.6). **All share one password.**

| Username | Display | Password |
|----------|---------|----------|
| \`dev.direccion\` | DEV Dirección (fixture) | \`$FIX_PASS\` |
| \`dev.some\` | DEV SOME (fixture) | \`$FIX_PASS\` |
| \`dev.medico\` | DEV Médico (fixture, multi-role) | \`$FIX_PASS\` |
| \`dev.matrona\` | DEV Matrona (fixture) | \`$FIX_PASS\` |
| Where | | \`.env\` → \`FIXTURE_USER_PASSWORD\` |

---

**Not password-protected (for completeness):** Redis (\`redis\` service, no auth — internal to the compose
network only).

**\`\$\` caveat:** if any value above contains \`\$\$\`, the real secret is a single \`\$\` (Compose doubles \`\$\`
in \`.env\`; see the note in \`.env.example\`). Hex secrets (\`openssl rand\`) never contain \`\$\`.
EOF

chmod 600 "$OUT"
echo "Wrote $OUT (mode 600, gitignored). Secrets were NOT printed to this terminal."
