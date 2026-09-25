<link rel="stylesheet" href="style.css">
<style>
@import url('https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400..800;1,9..144,400..800&family=Nunito+Sans:ital,opsz,wght@0,6..12,400..800;1,6..12,400..800&display=swap');
:root {
  --aps-primary: #7f21fe;
  --aps-dark-violet: #5315a8;
  --aps-ink: #101828;
  --aps-muted: #485363;
  --aps-border: #e4e7ec;
  --aps-gold: #e06f00;
  --aps-dark-gold: #9a4c00;
  --aps-error: #ea003e;
  --aps-error-bg: #FFE7E7;
  --aps-card-bg: #ffffff;
  --aps-canvas-bg: #fcfaff;
  --aps-badge-bg: #f4ebff;
  --aps-badge-text: #5315a8;
}
body, .markdown-body {
  font-family: "Nunito Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif !important;
  color: var(--aps-ink) !important;
  background-color: var(--aps-canvas-bg);
  line-height: 1.65;
}
h1, h2, h3, h4 { font-family: "Fraunces", Georgia, serif !important; letter-spacing: -0.015em; font-weight: 700; }
h1 { color: var(--aps-dark-violet) !important; border-bottom: 3px solid var(--aps-primary); padding-bottom: 0.35em; }
h2 { color: var(--aps-dark-violet) !important; border-bottom: 1px solid var(--aps-border); padding-bottom: 0.25em; margin-top: 1.6em; }
h3 { color: var(--aps-primary) !important; }
h4 { color: var(--aps-dark-gold) !important; }
a { color: var(--aps-primary) !important; font-weight: 600; text-decoration: none; }
a:hover { color: var(--aps-dark-violet) !important; text-decoration: underline; }
table { border-collapse: collapse; width: 100%; border: 1px solid var(--aps-border); margin: 1.4em 0; border-radius: 8px; overflow: hidden; background: #ffffff; }
th { background-color: var(--aps-dark-violet) !important; color: #ffffff !important; font-family: "Fraunces", serif !important; font-weight: 600; padding: 10px 14px; text-align: left; }
td { padding: 9px 14px; border-bottom: 1px solid var(--aps-border); color: var(--aps-ink); }
tr:nth-child(even) { background-color: #fbf9ff; }
blockquote { border-left: 4px solid var(--aps-primary) !important; background-color: #f8f4ff !important; color: var(--aps-muted) !important; padding: 0.8em 1.4em; border-radius: 0 8px 8px 0; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace !important; background-color: var(--aps-badge-bg); color: var(--aps-dark-violet); padding: 0.2em 0.45em; border-radius: 4px; border: 1px solid #d6bbfb; }
pre { background-color: var(--aps-ink) !important; color: #f9fafb !important; border-radius: 8px; padding: 1.1em 1.3em; border: 1px solid #344054; }
pre code { background: transparent !important; color: inherit !important; border: none !important; }
.aps-hero { background: linear-gradient(135deg, #5315a8 0%, #7f21fe 100%); color: #ffffff; border-radius: 12px; padding: 26px 32px; margin-bottom: 24px; box-shadow: 0 4px 14px rgba(83,21,168,0.22); }
.aps-hero h1 { color: #ffffff !important; border-bottom: 2px solid rgba(255,255,255,0.3); margin: 0 0 10px 0; padding: 0 0 8px 0; }
.aps-tag { display: inline-block; background: #ea003e; color: #ffffff; font-size: 0.78em; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; padding: 3px 10px; border-radius: 20px; margin-bottom: 12px; }
.aps-meta { color: rgba(255,255,255,0.9); font-size: 0.95em; margin: 4px 0; }
</style>

<div class="aps-hero">
  <span class="aps-tag">Architectural Audit & Debt Register</span>
  <h1>APS Conecta Gestión — Register of Inconsistencies, Debt & Stubs</h1>
  <p class="aps-meta"><strong>Comprehensive Catalog of Contradictions, Drift, Stubs & Bugs</strong></p>
  <p class="aps-meta">Documentation Manual IV | Read-Only Audit Ledger</p>
</div>

# APS Conecta Gestión — Register of Inconsistencies, Architectural Debt, and Stubs

> **Notice:** This document serves as the fourth manual in the APS Conecta Gestión documentation suite.  
> Per engineering directives, this document **exclusively inventories, classifies, and cites** discrepancies, drifted documentation, design flaws, architectural stubs, broken routes, and latent bugs found across the repository, design artifacts, and deployment environments.  
> **No fixes or code modifications are executed in this register.**

---

## Master Table of Contents

1. [Documentation & Governance Inconsistencies](#1-documentation--governance-inconsistencies)
   - 1.1 [Reversed Architecture Decisions (ADRs) and Stale Summaries](#11-reversed-architecture-decisions-adrs-and-stale-summaries)
   - 1.2 [Permanent ADR Numbering Gaps](#12-permanent-adr-numbering-gaps)
   - 1.3 [Cross-Repository Authority Drift (`ORG-MAP.md`)](#13-cross-repository-authority-drift-org-mapmd)
   - 1.4 [Retired Libraries Surviving in Machine Registries](#14-retired-libraries-surviving-in-machine-registries)
2. [Codebase & Runtime Configuration Inconsistencies](#2-codebase--runtime-configuration-inconsistencies)
   - 2.1 [Packaging Divergence: `apps/farmacia` on Trunk vs `OWN_APPS` in `12-apps.sh`](#21-packaging-divergence-appsfarmacia-on-trunk-vs-own_apps-in-12-appssh)
   - 2.2 [Unauthenticated Redis on Shared Docker Network](#22-unauthenticated-redis-on-shared-docker-network)
   - 2.3 [Decorative Two-Factor Authentication (2FA)](#23-decorative-two-factor-authentication-2fa)
   - 2.4 [Suppressed Audit Logging and Missing `admin_audit`](#24-suppressed-audit-logging-and-missing-admin_audit)
   - 2.5 [Missing `trusted_proxies` and Client IP Flattening](#25-missing-trusted_proxies-and-client-ip-flattening)
   - 2.6 [Conflicting Backup Policy vs Box Integrity Gates](#26-conflicting-backup-policy-vs-box-integrity-gates)
   - 2.7 [Untested Image Digest & App Version Checkers](#27-untested-image-digest--app-version-checkers)
3. [Design Artifact Inconsistencies (`.rpiv/artifacts/`)](#3-design-artifact-inconsistencies-rpivartifacts)
   - 3.1 [Agnostic Dehardcode Design (`2026-09-19_02-23-04`)](#31-agnostic-dehardcode-design-2026-09-19_02-23-04)
   - 3.2 [Territorio Architecture & Layout Review (`2026-09-19_15-02-40`)](#32-territorio-architecture--layout-review-2026-09-19_15-02-40)
   - 3.3 [AIO Installer Full-Suite Design (`2026-09-19_20-45-04`)](#33-aio-installer-full-suite-design-2026-09-19_20-45-04)
4. [Custom Apps Inconsistencies & Stubs](#4-custom-apps-inconsistencies--stubs)
   - 4.1 [Territorio (`apps/territorio`)](#41-territorio-appsterritorio)
   - 4.2 [Farmacia (`apps/farmacia`)](#42-farmacia-appsfarmacia)
   - 4.3 [Epidemiología (`apps/epidemiologia`)](#43-epidemiología-appsepidemiologia)
   - 4.4 [Side Menu (`apps/side_menu`)](#44-side-menu-appsside_menu)
   - 4.5 [Euro-Office Connector (`apps/eurooffice`)](#45-euro-office-connector-appseurooffice)
5. [External Integration, Upstream API & Network Inconsistencies](#5-external-integration-upstream-api--network-inconsistencies)
   - 5.1 [MINSAL & ISP Upstream Scraping Outages](#51-minsal--isp-upstream-scraping-outages)
   - 5.2 [Euro-Office Public URL / Mixed Content Misdirection](#52-euro-office-public-url--mixed-content-misdirection)
   - 5.3 [Upstream Offline Forges for Vendored Apps](#53-upstream-offline-forges-for-vendored-apps)
6. [Historical & Latent Bug Inventory](#6-historical--latent-bug-inventory)
   - 6.1 [Gestion Bug Ledger (B-001 through B-019)](#61-gestion-bug-ledger-b-001-through-b-019)
   - 6.2 [Findings Ledger (#1 through #10)](#62-findings-ledger-1-through-10)
7. [Regulatory, Legal & Interoperability Compliance Gaps](#7-regulatory-legal--interoperability-compliance-gaps)
   - 7.1 [Chilean Ley 21.719 Enforceability Cliff (2026-12-01)](#71-chilean-ley-21719-enforceability-cliff-2026-12-01)
   - 7.2 [Clinical Document 15-Year Retention (Ley 20.584 / DTO 41/2012)](#72-clinical-document-15-year-retention-ley-20584--dto-412012)
   - 7.3 [MINSAL EIS FHIR Draft Integration Gaps](#73-minsal-eis-fhir-draft-integration-gaps)
   - 7.4 [Downstream Fork Governance, AGPL §13 Source Duty & Trademark Audit](#74-downstream-fork-governance-agpl-13-source-duty--trademark-audit)

---

## 1. Documentation & Governance Inconsistencies

### 1.1 Reversed Architecture Decisions (ADRs) and Stale Summaries
- **AD-1 Reversed by ADR-0003**: Initial invariant AD-1 ("Vanilla Nextcloud only, no custom apps in the core repo") was explicitly reversed by [ADR-0003](../adr/0003-this-stack-ships-a-custom-app.md), which admitted `epidemiologia` as an in-tree app. However, comments across `compose.yaml` (e.g., line 39) still cite "No fork (AD-1)" without acknowledging the reversal.
- **AD-5 Reversed by ADR-0002**: Initial invariant AD-5 ("No app patches") was partially reversed by [ADR-0002](../adr/0002-app-patches.md), establishing the sequential application of `*.patch` files against `eurooffice` and `groupfolders`.
- **AD-6 Reversed by ADR-0004**: AD-6 originally concluded that `themes/apsconecta/defaults.php` was obsolete and rightly deleted because iOS app-opening banners could be suppressed via `occ config:system:set customclient_ios_appid ""`. [ADR-0004](../adr/0004-branding-the-legacy-render-path.md) reversed this by re-introducing `defaults.php` to theme the legacy render path (setup, untrusted domain, 429, fatal exceptions) where `ThemingDefaults` is bypassed.
- **Stale Summaries Surviving in `ROADMAP.md` and `ADR-0000`**:
  - `ADR-0000`'s entry for AD-6 still asserts that `defaults.php` was rightly deleted and carries no annotation referencing ADR-0004.
  - `ROADMAP.md` still lists `defaults.php` as unnecessary.
  - The file `defaults.php` is tracked, active, and load-bearing; the `make smoke` gate fails if it is removed.

### 1.2 Permanent ADR Numbering Gaps
- **Gaps at 0006, 0008, 0009**: In `../adr/`, files jump from 0005 directly to 0007, and from 0007 to 0010.
  - *Origin:* ADR-0007 and ADR-0010 originated from `aps-conecta-web` and were migrated into `gestion` keeping their original numbers pursuant to ADR-0011.
  - *Impact:* Readers and automated linters encountering missing numbers 0006, 0008, and 0009 perceive them as accidental deletions unless cross-checked against ADR-0011 § Decision 4.

### 1.3 Cross-Repository Authority Drift (`ORG-MAP.md`)
- **False Premise: "gestion is the home of every org-wide fact"**: Disproved by ADR-0011 and ADR-0012. Generic contributing, security, and licensing files live in `.github`, documentation conventions live in `repo-docs`, and brand tokens live in `aps-conecta-web`.
- **False Premise: "aps-conecta-web is the home of the brand shared by every product"**: Disproved by ADR-0006 (2026-08-05). There is no single shared brand package. Identity exists as per-product variants. `gestion` maintains its own server theme for Nextcloud chrome. However, `aps-conecta-web/CONTEXT.md` still asserts the superseded premise.
- **`Databases` Repository Ageing Probe Failure**: The health gate for the `Databases` catalog (which tracks Chilean health sector APIs and laws) requires probes to be refreshed periodically. The last probe is older than the maximum threshold; the CI gate is permanently red as of 2026-09-10.

### 1.4 Retired Libraries Surviving in Machine Registries — RESOLVED 2026-09-25
- **Retired `common` Library**: A shared PHP library named `common` was retired and deleted from the GitHub organization before acquiring a consumer.
- *Stale Survivals (both swept against trunk and cleared):*
  - The organization profile no longer declares an archetype for `common` — `repo-docs/profiles/aps-conecta.json` `repo_archetypes` holds only `repo-docs` and `aps-conecta-web`.
  - The architecture plans in `.rpiv/` that listed `common` as in-scope custom code were superseded by the 2026-09 org-wide hardening plan, whose shared-package finding names `aps-common` (not `common`) as the one home.

---

## 2. Codebase & Runtime Configuration Inconsistencies

### 2.1 Packaging Divergence: `apps/farmacia` on Trunk vs `OWN_APPS` in `12-apps.sh` — RESOLVED 2026-09-25
- **Evidence (historical):** `apps/farmacia/` existed on disk (ADR-0005) while `provisioning/phases/12-apps.sh` declared only `epidemiologia` under `OWN_APPS`, so `make divergence` reported `apps/farmacia` as present on disk but undeclared in release tarballs.
- **Resolution:** `OWN_APPS` now declares all three own apps — `epidemiologia`, `farmacia`, `territorio` — and each ships a tarball under `provisioning/apps/<id>/`; production clean installs deploy all three. farmacia joined the release in v0.11.1.
- **Historical Licensing Discrepancy (Resolved):** An earlier audit noted that `gestion/docs/LICENSING.md` listed `eurooffice` as `AGPL-3.0-or-later` while `info.xml` declared `AGPL-3.0-only`. This was resolved in issue #171, and `scripts/test.sh` now asserts that `docs/LICENSING.md` exactly matches `info.xml` inside all vendored tarballs.

### 2.2 Unauthenticated Redis on Shared Docker Network
- **Evidence:** `compose.yaml:62-69` and live container runtime.
- **Inconsistency:** Redis 8 runs with no password authentication (`requirepass` unset). Running `redis-cli ping` inside the container or across the compose network answers `PONG` unprompted.
- **Risk:** Any compromised container sharing the compose network can read session keys, corrupt transactional file locks, or inject serialized cache objects.

### 2.3 Decorative Two-Factor Authentication (2FA)
- **Evidence:** `occ app:list` shows `twofactor_totp: 16.0.0` enabled; `docker compose exec nextcloud php occ twofactorauth:state <user>` on all standing accounts.
- **Inconsistency:** TOTP is installed in the stack, but **zero user accounts** are enrolled. No system configuration or group policy enforces 2FA enrollment upon login. Authentication for clinic leads remains single-factor password-only.

### 2.4 Suppressed Audit Logging and Missing `admin_audit`
- **Evidence:** `occ app:list` shows `admin_audit` listed under `Disabled:`; `config.php` specifies `loglevel=2` (WARN).
- **Inconsistency:** There is no persistent administrative audit log for authentication attempts, file access, permission changes, or user administration. All audit events below WARN are dropped by the logger.

### 2.5 Missing `trusted_proxies` and Client IP Flattening
- **Evidence:** `config.php` lacks `trusted_proxies` and `forwarded_for_headers`.
- **Inconsistency:** When traffic passes through Caddy or Tailscale proxy layers to port 8180, Nextcloud logs every incoming request as originating from `127.0.0.1`.
- **Impact:** Brute-force protection throttling is applied globally to the loopback IP rather than per individual remote client IP.

### 2.6 Conflicting Backup Policy vs Box Integrity Gates
- **Evidence:** Global Rule 11 vs `check-box.sh` check 6.
- **Inconsistency:**
  - Global Rule 11 dictates: "Back up any configuration file before modifying it to `/root/backups/<name>.bak.<date>`".
  - Host gate `check-box.sh` (check 6) fails if any compose definition exists outside the official repo source and Coolify's rendered copy, searching with glob `*.yml*` specifically to detect stray backups.
  - Backing up a compose file per Rule 11 turns the host gate red immediately (filed as `aps-conecta-web#43`).

### 2.7 Untested Image Digest & App Version Checkers
- **Evidence:** `scripts/image-digests.sh` and `scripts/app-versions.sh`.
- **Inconsistency:** Searching `scripts/test.sh` and `tests/` yields zero references or test assertions covering either script. If upstream HTML structures or Docker Hub APIs change, the scripts can fail silently or return false-green status during automated runs.

---

## 3. Design Artifact Inconsistencies (`.rpiv/artifacts/`)

### 3.1 Agnostic Dehardcode Design (`2026-09-19_02-23-04`)
- **L1-01 — Stale deSEC Anchor in Key Discoveries:** Discovery section cites `run.sh:60-64` for deSEC invocations; Slice 13 measured the invocations at `run.sh:74-79`.
- **L2-01 — Duplicated Clean-Slate Code Block in `uninstall.sh`:** In the design's code fence (lines 1339–1346), the block:
  ```bash
  if [ "$fail" -eq 0 ]; then
    echo "CLEAN SLATE: nothing this repo installed is left."
  else
    echo "CLEAN SLATE INCOMPLETE — the LEFT lines above remain."
  fi
  ```
  is duplicated consecutively due to a copy-paste artifact.
- **L2-02 — Parameter Ordering Trap in `db-dump.sh`:** `DEST` is assigned from `$1` (`DEST="${1:-database-dump.sql}"`) before testing whether `$1` is `--self-test`. When invoked with `--self-test`, `DEST` is assigned the flag string.

### 3.2 Territorio Architecture & Layout Review (`2026-09-19_15-02-40`)
- **L0-01 — Duplicated Label Normalization:** CLI import (`lib/Command/Import.php:71-78`) and `ImportController` implement separate, non-shared string sanitization and normalization routines.
- **L0-02 — Fragile Major Version Nextcloud Pin:** `appinfo/info.xml` pins dependencies strictly to `<nextcloud min-version="34" max-version="34"/>`, breaking automatically on minor Nextcloud version bumps (e.g., 34.1 or 35).
- **L0-03 — Non-Numeric Route Parameter Crash:** Routes such as `/features/{id}` declare `{id}` without regex guards; passing non-numeric input triggers an unhandled `TypeError` (HTTP 500) rather than HTTP 404.
- **L0-04 — Bare SPA Mount:** `templates/index.php` mounts `<div id="territorio-app"></div>` with no initial loading skeleton and no `<noscript>` element for non-JS environments.
- **L1-01 — Six Conflicting Refusal Strings:** Validation errors return HTTP 422 with six different, inconsistent JSON payload structures across controllers (`{"error": "..."}`, `{"message": "..."}`, `{"detail": "..."}`).
- **L1-02 — Initial State Bloat:** The entire municipal spatial registry is dumped into the HTML document via `initial-state` on first load, delaying First Contentful Paint.
- **L2-01 — God Component Monolith (`App.vue`):** `App.vue` contains 1,544 lines of code combining routing, spatial layers, UI panels, coordinate transforms, search, and websocket polling in a single file.
- **L2-02 — Silent Polling Failures:** Background sync failures in `App.vue` log to the browser console but display no visual alert or degraded banner to clinic staff.
- **L2-03 — Accessibility Violation in Tab Switching:** The main navigation switches views using regular `<div>` buttons with click handlers rather than WAI-ARIA compliant `role="tablist"` / `role="tab"` / `role="tabpanel"` semantics.
- **L3.1-01 & L3.1-02 — Monolithic Subcomponents:** `TerritorioMap.vue` (1,328 LOC) and `CapasPanel.vue` (951 LOC) contain hardcoded duplicate row-editing forms.
- **L4-01 — Duplicated Accent-Stripping `fold()`:** JavaScript string normalization `fold()` is copy-pasted across two distinct frontend utility modules.
- **L8-01 — Duplicate Status Represented as Raw Strings:** Duplicate resolution statuses are defined as string literals (`"pending"`, `"resolved"`) instead of utilizing PHP 8.1 Backed Enums as used elsewhere in the entity layer.

### 3.3 AIO Installer Full-Suite Design (`2026-09-19_20-45-04`)
- **Transport Coupling in Smoke Tests:** `scripts/smoke.sh` accesses `db`, `redis`, and `cron` by Docker Compose service name. Under AIO architecture, container names change to `nextcloud-aio-database`, `nextcloud-aio-redis`, and cron runs as an internal sub-process of `nextcloud-aio-nextcloud`.
- **Empty Host Glob under AIO:** `divergence.sh` checks for installed apps using the host path `apps/*/`. In an AIO deployment, `apps/` is empty on the host (baked inside container volumes), causing divergence checking to report false-green results.
- **Phase 0 Prerequisite Drift:** Slices in the AIO installer design depend on `gestion v0.2.0` being tagged and merged, but `gestion` remains at `feat/self-hosted-basemap` (`923b426`), leaving AIO design execution blocked.

---

## 4. Custom Apps Inconsistencies & Stubs

### 4.1 Territorio (`apps/territorio`)
- **Unrestricted Write Permissions:** Any authenticated Nextcloud user can create, update, or delete territorial boundary features and points of interest. No authorization check restricts write operations to specific roles or `cat-jefaturas`.
- **Geometry Loss Bug (#63):** Updating a feature without providing the `geometry` parameter deletes existing geometry because `?? null` coalesce cannot differentiate between an omitted field and an intentional nullification.

### 4.2 Farmacia (`apps/farmacia`)
- **Undocumented Open Writes:** Similar to Territorio, any authenticated user can upload CSV vademécum data, create active principles, or modify clinical risk categories. There is no role check restricting modifications to `role-quimico-farmaceutico`.
- **Schema Migration vs Seed Hook Race:** `EnsureSeedData` is placed in `repair-steps` rather than `postSchemaChange` because `postSchemaChange` is skipped during schema-only first installs. Upgrades re-run the seed step on every execution.
- **Incomplete Vademécum Fields:** Several MINSAL essential drug entries lack mapped FDA pregnancy risk categories or renal clearance parameters, leaving clinical alerts incomplete for certain active principles.

### 4.3 Epidemiología (`apps/epidemiologia`)
- **Stale MINSAL Endpoint Scraping:** `epi.minsal.cl` returns Cloudflare 403 Forbidden to automated background jobs. The app falls back to cached data without alerting staff of upstream staleness.
- **Unreachable ISP Chile Host:** `www.ispch.gob.cl` presents a TCP SYN blackhole, failing connection handshakes. Background tasks wait for timeouts.
- **Missing EPIVIGILA Deep-Linking:** The EPIVIGILA integration is currently an outbound external hyperlink rather than an authenticated single-sign-on or token-passing bridge.

### 4.4 Side Menu (`apps/side_menu`)
- **Unescaped Stored CSS Injection:** Custom icon colors and menu layout CSS are injected directly into page HTML without context-aware sanitization, creating an intra-tenant styling injection vector.
- **Offline Upstream Source:** Version 6.1.0 cannot be updated or verified because its upstream source forge (`gitnet.fr`) is offline.

### 4.5 Euro-Office Connector (`apps/eurooffice`)
- **Hardcoded JWT Secret Fallback:** In the connector PHP code, if `OFFICE_JWT_SECRET` is unset, certain execution paths fall back to a hardcoded default string rather than throwing a fatal configuration exception.
- **SSRF in Document Tracking:** The `track()` callback accepts remote IP addresses for status updates without strictly enforcing that the request originates from the private Docker bridge network.

---

## 5. External Integration, Upstream API & Network Inconsistencies

### 5.1 MINSAL & ISP Upstream Scraping Outages
- **MINSAL (`epi.minsal.cl`):** Cloudflare bot protection rejects server-side requests with HTTP 403.
- **ISP Chile (`www.ispch.gob.cl`):** Both A-records fail TCP handshakes from foreign or cloud IP blocks.
- **Handling in `smoke.sh`:** Historical versions of `smoke.sh` lacked `--max-time` on curl calls, causing CI and test runs to hang indefinitely when ISP was down (addressed in `epidemiologia#130`).

### 5.2 Euro-Office Public URL / Mixed Content Misdirection
- **Misleading Error Reporting (B-019):** When Nextcloud is accessed over HTTPS or from an external IP, but `DocumentServerUrl` points to `http://localhost:9980`, the browser blocks the connection as mixed content or network failure. Euro-Office erroneously reports this as a **JWT token invalid** error, misdirecting troubleshooting toward credentials.

### 5.3 Upstream Offline Forges for Vendored Apps
- The upstream repository for `side_menu` (hosted on a private Git server at `gitnet.fr` by maintainer deblan) has been unreachable since September 2026. The local tarball `side_menu-6.0.1.tar.gz` cannot be upgraded to 6.1.0.

---

## 6. Historical & Latent Bug Inventory

### 6.1 Gestion Bug Ledger (B-001 through B-019)

| ID | Symptom | Root Cause | Status |
|---|---|---|---|
| **B-001** | `make seed` reported success when a phase failed | Bash suppresses `errexit` inside subshells evaluated as `if` conditions | Fixed (issue #39) |
| **B-002** | `apps/` and `themes/` read-only for host developer | Container set permissions to `www-data:www-data` (uid 33) without host group write | Fixed (issue #40) |
| **B-003** | `ensure_app` blamed file permissions for every failure | Helper swallowed `occ` stderr and outputted an unverified hardcoded assumption | Fixed (issue #41) |
| **B-004** | Unquoted `NEXTCLOUD_TRUSTED_DOMAINS` broke `.env` | Spaces in domain list caused shell sourcing to execute subsequent tokens as commands | Fixed (issue #42) |
| **B-005** | `make office-eurooffice` echoed `OFFICE_JWT_SECRET` | Secret printed to stdout during `occ` execution | Fixed (issue #43) |
| **B-006** | Xdebug log permission warning on every request | `/tmp` is world-writable; Xdebug refuses to write to shared directories | Fixed (issue #44) |
| **B-007** | ODF files (`.odt`, `.ods`) opened read-only | Connector defaults to `lossy-edit` / auto-convert rather than direct edit | Fixed (issue #45) |
| **B-008** | "Nextcloud" leaked into UI after white-labeling | Strings hardcoded in upstream templates; `.section.development-notice` unbranded | Fixed (`b66c5ac`) |
| **B-009** | `default_language=es_419` was inert | `es_419` is an ICU locale, not a valid Nextcloud language code | Fixed (`10-locale.sh`) |
| **B-010** | Patching `eurooffice` turned Admin Overview red | Code integrity checks failed due to invalid `appinfo/signature.json` | Fixed (issue #71) |
| **B-011** | Brand SVG lockups rendered Georgia font instead of Fraunces | SVGs rendered via `<img>` tags cannot access `@font-face` styles from `server.css` | Fixed (embedded data URIs) |
| **B-012** | Header CSS leaked onto public share pages; Phase 30 swallowed logs | CSS selectors matched `layout.public.php`; `ensure_groupfolder` redirected to `/dev/null` | Fixed (`a36b458`) |
| **B-013** | 8 system error screens rendered stock Nextcloud blue branding | Error pages render via legacy `Template::printPage()`, bypassing modern theming | Fixed (ADR-0004) |
| **B-014** | Certificate re-import broke seed idempotency gate | Verb `certs: imported` was unanchored in `seed-idempotent.sh` grep patterns | Fixed (`scripts/test.sh`) |
| **B-015** | `make install` hung for minutes in Phase 07-certs | `openssl s_client` lacked a handshake timeout against unresponsive hosts | Fixed (`timeout 20`) |
| **B-016** | DEIS establishment names with quotes/backticks broke provisioning | `deis.py` injected unescaped values into shell files | Fixed (`shlex.quote`) |
| **B-017** | Gate refusing published secrets bypassed by quotes | Dotenv parser differences evaluated quoted placeholders as non-matching | Fixed (`scripts/test.sh`) |
| **B-018** | `occ upgrade` re-downloaded store apps, overwriting patches | Upstream upgrade logic contacts App Store by default | Fixed (`NC_appstoreenabled: "0"`) |
| **B-019** | Remote document editing failed with misleading JWT token error | `DocumentServerUrl` pointed to loopback IP; mixed-content HTTPS->HTTP block | Fixed (`OFFICE_PUBLIC_URL`) |

### 6.2 Findings Ledger (#1 through #10)

| # | What Broke | Root Cause | Status |
|---|---|---|---|
| **1** | Migration blocked by active background session | Stale lock file in `/srv/sync/agent-locks/` | Resolved |
| **2** | `COOLIFY_TOKEN` returned 401 Unauthenticated | Personal access token expired / revoked | Resolved |
| **3** | Runtime mounted old path after directory reorganization | Bind mounts pointed to `/opt/aps-conecta/*` instead of `/opt/aps-conecta-org/*` | Resolved |
| **4** | `side_menu` 6.1.0 cannot be vendored | Upstream forge `gitnet.fr` offline | Open (gestion#169) |
| **5** | Drift report test coverage missing | `scripts/image-digests.sh` has zero assertions in `test.sh` | Open (gestion#170) |
| **6** | `LICENSING.md` license mismatch for Euro-Office | Docs claim `AGPL-3.0-or-later`; code declares `AGPL-3.0-only` | Resolved (issue #171, asserted in test.sh) |
| **7** | `calendar/VENDOR` cites dropped `maps` app | Comment left behind after `maps` was removed in ADR-0005 | Open (gestion#172) |
| **8** | Backup rule contradicts compose file gate | Rule 11 `.bak` files trigger failure in `check-box.sh` | Open (aps-conecta-web#43) |
| **9** | Stale branches fail pre-push box checks | Older branches retain outdated directory paths | Resolved |
| **10** | `epidemiologia/scripts/smoke.sh` hung on network stall | Missing `--max-time` on upstream curl requests | Fixed (epidemiologia#130) |

---

## 7. Regulatory, Legal & Interoperability Compliance Gaps

### 7.1 Chilean Ley 21.719 Enforceability Cliff (2026-12-01)
- **Status:** Binding legislation in Chile.
- **Gap:** Ley 21.719 grants individuals strict data sovereignty rights (access, rectification, erasure). APS Conecta Gestión lacks automated data-subject export and erasure workflows for staff personal data.
- **Processor Agreements:** No standard "Encargado de Tratamiento" agreement template is integrated for hosting providers or maintenance contractors.

### 7.2 Clinical Document 15-Year Retention (Ley 20.584 / DTO 41/2012)
- **Status:** Binding Chilean healthcare standard.
- **Requirement:** Clinical documentation (*ficha clínica*) must be preserved for a minimum of 15 years, with authorized, documented destruction protocols upon expiration.
- **Gap:** Nextcloud's core file retention and trash bin routines operate on short aging intervals (e.g., 30 days) and automated pruning based on quota. There is no WORM (Write Once, Read Many) or legal hold policy preventing accidental deletion of clinical records.

### 7.3 MINSAL EIS FHIR Draft Integration Gaps
- **Status:** Non-mandatory draft / STU.
- **Architecture Spec:** MINSAL Estrategia de Interoperabilidad en Salud (EIS) specifies FHIR R4 for MPI (Master Patient Index), TEI (Triage and Referrals), and SNRE (Electronic Prescriptions).
- **Current State:**
  - Zero FHIR endpoints exist in the APS Conecta Gestión codebase.
  - Published MINSAL Implementation Guides (MPI 0.2.0, TEI 0.2.3, SNRE 0.9.6) lack final normative status and publish no formal FHIR CapabilityStatement.
  - Integration is a planned future capability; no code currently targets these drafts.

### 7.4 Downstream Fork Governance, AGPL §13 Source Duty & Trademark Audit
- **Status:** Binding Open Source License Obligation (GNU AGPLv3).
- **Architecture Contradiction:** Internal engineering documentation frequently asserts "No Core Fork (AD-1)", yet the platform deploys patched vendored applications (ADR-0002), custom in-tree applications (`epidemiologia`, `farmacia`, `territorio`), and an institutional server theme. Legally, packaging a customized downstream distribution of Nextcloud constitutes a downstream fork and derivative software distribution.
- **AGPL Section 13 Source Distribution Mechanism Gap:**
  - *Legal Requirement:* GNU AGPLv3 §13 requires providing remote network users with the Corresponding Source code of the exact version running on the server.
  - *Current State:* The web interface provides no prominent link, modal, or automated endpoint providing clinic staff with direct access to the Corresponding Source code or applied patches (`provisioning/apps/<app>/*.patch`).
  - *Risk:* Municipal health operators hosting the platform face copyright compliance exposure and statutory penalties if a network user requests source code that is not readily furnished.
- **License Incompatibility Between Components (`-only` vs `-or-later`):**
  - Euro-Office DocumentServer is licensed strictly under `AGPL-3.0-only`.
  - Nextcloud Server and APS Conecta own code are licensed under `AGPL-3.0-or-later`.
  - *Risk:* If Nextcloud or APS Conecta ever migrates to a future AGPL version (e.g., AGPLv4), the Euro-Office DocumentServer cannot be unified under that license without upstream author relicensing.
- **Trademark Notice & Disclaimer Absence in In-App Views:**
  - While Nextcloud trademarks are acknowledged in developer documentation, standard end-user login and dashboard views contain white-labeled references without displaying the formal trademark attribution and disclaimer required to avoid brand confusion under trademark law and AGPL Section 7(e).
