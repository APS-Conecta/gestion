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
.aps-tag { display: inline-block; background: #e06f00; color: #ffffff; font-size: 0.78em; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; padding: 3px 10px; border-radius: 20px; margin-bottom: 12px; }
.aps-meta { color: rgba(255,255,255,0.9); font-size: 0.95em; margin: 4px 0; }
</style>

<div class="aps-hero">
  <span class="aps-tag">Master Documentation Suite</span>
  <h1>APS Conecta Gestión — Documentation Suite</h1>
  <p class="aps-meta"><strong>Primary Healthcare Intranet & Operational Platform for Chilean Health Centers</strong></p>
  <p class="aps-meta">Official Technical Manuals, Architecture Reference & Administration Runbooks</p>
</div>

# APS Conecta Gestión — Documentation Suite

Welcome to the official manual suite for **APS Conecta Gestión**, the intranet and operational collaboration platform designed for Chilean Primary Healthcare (*Atención Primaria de Salud* — APS), including CESFAM, CECOSF, PSR, COSAM, SAPU, and SAR facilities.

This suite is engineered as a specialized downstream distribution and customized fork of the **Nextcloud 34** collaboration ecosystem (PostgreSQL 18, Redis 8, Euro-Office documentserver), tailored for Chilean primary healthcare and managed via declarative configuration-as-code.

---

## 📚 Manuals in this Suite

The documentation is organized into three comprehensive, self-contained manuals mirroring the structure and standards of official Nextcloud documentation, augmented with APS Conecta's healthcare workflows, custom applications, and operational patterns:

### 1. [📖 User Manual](USER_MANUAL.md)
**Audience:** Clinic staff, healthcare professionals, technical staff, administrative personnel, and team leaders (*jefaturas*).  
**Key Topics:**
- Web interface navigation, Side Menu sidebar, and Desktop Workspace.
- Staff Dashboard and Chilean locale (`es-CL`) settings.
- The **4-Area CESFAM Document Tree** (`Transversal`, `Programas`, `Unidades`, `Sectores`).
- The operational principle of *"Una sola copia viva"* (Single living document copy).
- In-browser document editing and co-authoring with **Euro-Office** (OOXML & ODF).
- Secure internal communications via **Talk** (`spreed`).
- Schedules and clinical shift directory via **Calendar** and **Contacts**.
- **Specialized APS Apps:**
  - **Epidemiología**: MINSAL and ISP real-time health alerts, respiratory virus surveillance, EPIVIGILA access.
  - **Farmacia**: CESFAM pharmacological vademécum with clinical risk indicators (FDA pregnancy categories, renal adjustment, anticholinergic risk in older adults).
  - **Territorio**: Jurisdiction mapping, official *Unidades Vecinales*, clinic health sectors, and local health facilities.

### 2. [💻 Developer Manual](DEVELOPER_MANUAL.md)
**Audience:** Software engineers, app developers, and system architects.  
**Key Topics:**
- Core Architectural Invariants: Vanilla platform, declarative config, no core fork (AD-1).
- The `OCP\...` public API boundary (AD-9) and app taxonomy (Vendored, Own, Lab).
- Development environment setup (`compose.dev.yaml`, Xdebug port 9003, `Makefile`).
- Custom Nextcloud app lifecycle, schema migrations, and idempotent repair steps (`EnsureSeedData`).
- Deep-dive into APS Conecta custom apps (`epidemiologia`, `farmacia`, `territorio`).
- Server theming engine (`themes/apsconecta`) and the legacy render path (`defaults.php` / ADR-0004).
- Static gates (`scripts/test.sh`), smoke assertions (`scripts/smoke.sh`), and Playwright acceptance testing.
- Licensing (AGPL-3.0-or-later) and coding standards.

### 3. [⚙️ Server Administration Manual](ADMIN_MANUAL.md)
**Audience:** System administrators, DevOps engineers, and IT personnel deploying and maintaining CESFAM nodes.  
**Key Topics:**
- System architecture and multi-container topology (`compose.yaml`).
- Sizing prerequisites: The 8 GB RAM floor (Euro-Office multi-user memory baseline).
- Three-step installation lifecycle (`make setup`, Chilean DEIS registry lookup via `scripts/deis.py`, `make install`).
- The **13-Phase Idempotent Provisioning Engine** (`05-security` through `60-fixtures`).
- One-directional convergence: Add-only policy, divergence auditing (`make divergence`).
- Role-Based Access Control (RBAC): 22 shared CESFAM roles, category groupings (`cat-*`), and `SITE_ROLES`.
- Group Folders administration and allow-refinement ACL design (strictly no DENY rules).
- Office Server (`eurooffice`) and Basemap (`tiles` PMTiles) administration.
- Hardening, reverse proxy routing (Caddy / Tailscale), log management, and diagnostic runbooks.

### 4. [🔍 Register of Inconsistencies, Architectural Debt & Stubs](INCONSISTENCIES_AND_DEBT.md)
**Audience:** Architects, technical leads, security auditors, and product maintainers.  
**Key Topics:**
- Documentation & decision contradictions (reversed ADRs, permanent number gaps, authority drift).
- Runtime configuration discrepancies (unauthenticated Redis, decorative 2FA, log suppression).
- Design artifact flaws & code fence duplications (`.rpiv/artifacts/`).
- Custom app debt & open write permissions (`territorio`, `farmacia`, `side_menu`).
- Upstream network outages and third-party forge unavailability.
- Comprehensive Bug Ledgers: B-001 through B-019 and FINDINGS #1–#10.
- Regulatory cliffs: Chilean Ley 21.719, 15-year retention rules, and MINSAL EIS FHIR draft integration gaps.

---

## ⚖️ Downstream Fork Status & Open Source License Compliance

APS Conecta Gestión is an operational downstream distribution and specialized fork of the **Nextcloud** software suite, tailored for Chilean Primary Healthcare.

### Open Source License Preservation
All software components preserve their respective free and open-source licenses and upstream legal notices:
- **Base Nextcloud Platform**: Licensed under the **GNU Affero General Public License version 3 or later (GNU AGPL-3.0-or-later)**.
- **Euro-Office Collaboration Backend**: Euro-Office DocumentServer and its connector are licensed under the **GNU AGPL version 3 only (GNU AGPL-3.0-only)**.
- **Metadata & Cache Infrastructure**: PostgreSQL is licensed under the PostgreSQL License; Redis 8 is tri-licensed and operated under the **GNU AGPLv3** option.
- **Vendored Nextcloud Applications**: `groupfolders`, `side_menu`, `calendar`, `contacts`, `spreed`, and `desktop_workspace` are distributed under the **GNU AGPLv3 or later**.
- **APS Conecta Original Applications**: `epidemiologia`, `farmacia`, `territorio`, `themes/apsconecta`, and the provisioning engine are licensed under the **GNU AGPLv3 or later (GNU AGPL-3.0-or-later)** pursuant to ADR-0010 (Copyright © Daniel Espinoza Charrier / APS Conecta).

### Network Copyleft Notice (GNU AGPLv3 Section 13)
> [!IMPORTANT]
> Under Section 13 of the GNU AGPLv3, operators of this network-accessible software must provide all remote users interacting with it through a computer network access to the complete **Corresponding Source** code of the software as running on the server, at no charge. Municipal healthcare operators must maintain accessible links to upstream public repositories and organizational releases for compliance.

### Trademark & Attribution Disclaimers
- **Nextcloud Trademark**: "Nextcloud" and the Nextcloud logo are registered trademarks of Nextcloud GmbH. APS Conecta Gestión is an independent downstream software project and is not affiliated with, endorsed by, or sponsored by Nextcloud GmbH.
- **Copyright Notices**: Upstream copyright notices, author attributions, and license headers are maintained across all source files.
- **Brand Asset Carve-Out**: APS Conecta brand marks, graphics, and emblems are reserved under AGPL Section 7(e).

---

## 🎨 Brand, Visual Identity & Theming Architecture

APS Conecta Gestión implements an accessible institutional white-label identity on top of Nextcloud 34:

### Color Palette & Design Tokens
| Color Token | Hex | WCAG AA Ratio (White) | Architectural Role |
|---|---|---|---|
| **Primary Violet** | `#7f21fe` | 5.57:1 | Buttons, checkboxes, active tabs, folder markers (`primary_color`) |
| **Dark Violet** | `#5315a8` | ~8.00:1 | Main headings, whole-UI backdrop, navigation chrome (`background_color`) |
| **Error Pink** | `#ea003e` | 4.33:1 | Warning borders, alert icons, large clinical risk tags (≥19px bold) |
| **Error Background** | `#FFE7E7` | N/A | Soft background tint for safety notifications (`--color-error`) |
| **Brand Gold** | `#e06f00` | 3.07:1 | Fills, badges, and large text (≥24px or ≥19px bold) |
| **Dark Gold** | `#9a4c00` | ≥4.50:1 | Small text warnings and status tags on white backgrounds |
| **Ink** | `#101828` | ~16.00:1 | Primary high-legibility interface body text |
| **Muted** | `#485363` | ~7.00:1 | Secondary metadata, dates, file sizes, and subtle descriptions |

### Typography Stack
- **Display Typeface**: `Fraunces` (variable serif, optical size 9–144, weights 400–800) for titles, headings (`h1`–`h3`), and establishment labels.
- **Interface Typeface**: `Nunito Sans` (variable sans-serif, weights 400–800) for general UI, tables, clinical forms, and navigation menus.
- **Zero External Egress**: Fonts are self-hosted in `themes/apsconecta/core/fonts/` as WOFF2 with zero external CDN dependencies.

### Brand Vectors & Dynamic Layout
- **Authentication Card**: `core/img/logo/logo.svg` (full lockup with embedded font subsets).
- **Navigation Drawer**: `core/img/logo/logo-header.svg` (side menu drawer lockup).
- **Header Geometry**: `core/img/logo/logo-mark.svg` (34×30px), `core/img/home.svg` (19px within 36px slot), and `--aps-clinic` dynamic establishment label.
- **Full Canvas Backdrop**: `core/img/background.svg` with dark violet backing tone (`#5315a8`).
- **Enforced Light Theme**: `enforce_theme=light` and `disable-user-theming=yes` locked for consistent legibility across shared clinical terminals.

---

## 🖼️ Live System Screenshots

Visual references from the live running instance are captured and indexed in [`screenshots/`](screenshots/):

| Ref | Screenshot | Description |
|---|---|---|
| **01** | [`01_login_page.png`](screenshots/01_login_page.png) | Branded login page with Fraunces/Nunito typography and customized healthcare palette |
| **02** | [`02_dashboard.png`](screenshots/02_dashboard.png) | Staff dashboard featuring widgets, announcements, and quick access |
| **03** | [`03_files_tree.png`](screenshots/03_files_tree.png) | Four-area Document Home (`Transversal`, `Programas`, `Unidades`, `Sectores`) |
| **04** | [`04_transversal_folder.png`](screenshots/04_transversal_folder.png) | Shared institutional knowledge tree and clinic conventions |
| **05** | [`05_app_epidemiologia.png`](screenshots/05_app_epidemiologia.png) | Real-time epidemiological alerts (MINSAL / ISP) and surveillance dashboards |
| **06** | [`06_app_farmacia.png`](screenshots/06_app_farmacia.png) | Pharmacological arsenal vademécum with clinical risk evaluations |
| **07** | [`07_app_territorio.png`](screenshots/07_app_territorio.png) | Geospatial jurisdiction map with Chilean PMTiles basemap |
| **08** | [`08_app_talk.png`](screenshots/08_app_talk.png) | Secure staff chat, group discussions, and video conferencing |
| **09** | [`09_app_calendar.png`](screenshots/09_app_calendar.png) | Primary care scheduling, clinic shifts, and program calendars |
| **10** | [`10_admin_overview.png`](screenshots/10_admin_overview.png) | Server administration overview, security status, and system health |

---

## 🏛️ Guiding Documentation Principles

All documentation across this suite adheres to the foundational engineering doctrines of APS Conecta:

1. **DRY (Don't Repeat Yourself):** The code and declarative phase scripts are the single source of truth for exact parameters. Manuals explain *why* and *how to use*, referencing authoritative code locations.
2. **KISS (Keep It Simple, Stupid):** Explanations are direct, clean, and avoid speculative narrative.
3. **YAGNI (You Aren't Gonna Need It):** Only active, implemented capabilities in the v1 spine are documented. Deprecated or deferred features are clearly delineated.
4. **No Code Fork:** Upstream Nextcloud 34 functionality is preserved intact; APS Conecta extensions operate exclusively through official extension mechanisms.
5. **Strict Data Privacy:** Intranet and administrative workflows only. **Zero clinical patient records** are stored or managed within this suite.
