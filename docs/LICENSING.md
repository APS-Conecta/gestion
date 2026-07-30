# Licensing — APS Conecta Gestión

This is the committed **license-outline SSOT artifact** the architecture spine defers under NFR-3.
It records the license of APS Conecta's own code and of every third-party component the stack runs,
and reasons about whether running them triggers any obligation on our own code.

> **Not legal advice.** This is an engineering audit. The third-party license facts are verified
> against each project's authoritative source (below); the *reasoning* about obligations is ours and
> the points marked **[needs legal sign-off]** should be confirmed by a lawyer before being relied on.
> Third-party licenses verified **2026-07-19** against the versions this repo runs — the services pinned in
> `compose.yaml` plus the two Nextcloud apps installed by provisioning (`occ`).

## 1. APS Conecta's own code — Proprietary / all rights reserved

1. The project's **own original work** (code under `apps/`, `themes/`, `provisioning/`, `scripts/`,
   plus this repo's configuration and documentation) is **proprietary, all rights reserved** — see
   [`LICENSE`](../LICENSE).
2. **Why proprietary (reasoning, not assertion).** It is a private internal tool for a single CESFAM,
   with **no redistribution intent**. A permissive or copyleft license would give the work away for no
   benefit the project needs; proprietary keeps every option open (including open-sourcing later, which
   a proprietary start does not foreclose).
3. **Copyright holder** = **Daniel Espinoza Charrier** (individually). No legal entity ("razón social")
   for "APS Conecta" exists yet, so copyright vests in the individual. If a legal entity is later formed,
   or if this work is deemed commissioned by / funded for a third party (e.g. the health center), the
   holder must be revisited — **[needs legal sign-off]**.

## 2. "OSS-first" and "proprietary" are not in conflict

The project's OSS-first mandate (brief / PRD NFR-3) and the proprietary license above govern **different
things**, so both hold at once:

- **OSS-first governs the *dependencies* we consume** — every component the stack runs is open-source,
  self-hosted, and free, with **no paid licenses** (verified in §3). That mandate is satisfied.
- **Proprietary governs only our *own original code*** — which we author and do not redistribute. Nothing
  in the OSS-first mandate requires us to license our *own* work openly; it requires our *inputs* to be
  open. No contradiction.

## 3. Third-party component inventory (verified)

Every runtime component. The **services** are pinned as images in [`compose.yaml`](../compose.yaml);
the two **Nextcloud apps** (`groupfolders`, `eurooffice`) are installed into Nextcloud via `occ`, not as
compose services. All are open-source, self-hosted, and free — **no paid license, no license key** anywhere
in the stack.

| Component | Pinned / installed as | License | SPDX | Source |
|-----------|------------------------|---------|------|--------|
| Nextcloud Server | image `nextcloud:34-apache` | GNU AGPL v3 or later | `AGPL-3.0-or-later` | nextcloud/server `COPYING` + README |
| PostgreSQL | image `postgres:18-alpine` | PostgreSQL License (permissive) | `PostgreSQL` | postgresql.org/about/licence |
| Redis | image `redis:8-alpine` | Tri-license — **we elect AGPL v3** | `AGPL-3.0-or-later` | redis `LICENSE.txt` (8.x) |
| Euro-Office (office) | image `ghcr.io/euro-office/documentserver:latest` | GNU AGPL v3 | `AGPL-3.0-only` | Euro-Office/DocumentServer `LICENSE` |
| Group Folders | NC app `groupfolders` (occ-installed) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | nextcloud/groupfolders `info.xml` |
| Euro-Office connector | NC app `eurooffice` (occ-installed) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | eurooffice `info.xml` |
| Side menu | NC app `side_menu` (occ-installed) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `side_menu` `info.xml` |
| Fraunces | `themes/apsconecta/core/fonts/*.woff2` (served by the theme) | SIL Open Font License 1.1 | `OFL-1.1` | Fraunces `OFL.txt` |
| Nunito Sans | `themes/apsconecta/core/fonts/*.woff2` (served by the theme) | SIL Open Font License 1.1 | `OFL-1.1` | Nunito Sans `OFL.txt` |

Notes:
- The `-alpine` base-image OS layers carry their own separate licenses; the component license above is
  the one that matters for our audit.

### 3.1 Redis 8 is tri-licensed — we elect AGPLv3

Redis **8.x** ships under a **choice of one of three** licenses: RSALv2, SSPLv1, or **AGPLv3** (AGPLv3
was added in Redis 8.0, May 2025). Only AGPLv3 is OSI-approved / free-software. Consistent with the
OSS-first mandate, **APS Conecta elects the AGPLv3 option.** If a fully permissive drop-in is ever
wanted, **Valkey** (`valkey/valkey`, BSD-3-Clause) is the documented alternative (spine, deferred).

### 3.2 The brand fonts are OFL-1.1, and we ship them two ways

Both faces are redistributed, so OFL-1.1's terms apply to this repo directly.

- **Served as `.woff2`** by the theme: format conversion from the upstream `.ttf`. Not subsetting, not
  renaming — the Original Version, in another container. Nothing further is required.
- **Embedded as a subset inside the lockup SVGs** (`core/img/logo/*.svg`, produced by
  `tools/embed-fonts.py`): a subset **is** a Modified Version under OFL-1.1. That is expressly
  permitted — §1 allows modification, and §2's conditions are met because the fonts are not sold on
  their own and travel with the licence. The Reserved Font Names are **not** used for the modified
  copies: the subsets are embedded, never distributed as installable font files under the original
  names.

Stated because three documents used to say flatly that "fonts are not subset", which was true of the
`.woff2` and false of the SVGs.

### 3.3 Euro-Office — clean license, contested §7 terms **[awareness note]**

Euro-Office's `LICENSE` is the verbatim GNU AGPL v3 (`AGPL-3.0-only`) — the identifier is clean. But
there is an **active, public dispute**: ONLYOFFICE (which Euro-Office forks) has alleged the fork
violates ONLYOFFICE's asserted AGPL §7 additional terms (e.g. logo-retention); the FSF/SFC position is
that a logo-retention obligation is not a valid §7 term. This does **not** change the SPDX identifier,
but it is worth awareness. **[needs legal sign-off if Euro-Office is adopted for production.]**

## 4. Do the copyleft components reach our own code? (Aggregation analysis)

Most of the stack is copyleft (AGPL-3.0). The question is whether that copyleft reaches **our own code**
and forces us to open it. Our reasoning — **[needs legal sign-off]**:

1. We run the official, **unmodified** Docker images as **separate network services** (AGENTS.md
   invariant: "never a Nextcloud source fork"). We do not modify, statically link, or embed their source.
2. Our own code interacts with them only across process/network boundaries (occ CLI, HTTP/WOPI) — the
   classic **"mere aggregation"** situation, not the creation of a **derivative work**.
3. Under that reading, the AGPL of Nextcloud/Redis/Euro-Office imposes **no copyleft obligation on APS
   Conecta's own original code**, which may therefore remain proprietary (§1).
4. **Caveat that would change this:** the moment we *modify* an AGPL component's source, or bundle/fork it
   rather than pull the official image, the AGPL's network-copyleft (§13) can attach. v1 does neither
   (zero custom PHP, no fork). If that ever changes, this analysis must be redone.

## 5. Summary

- **Our code:** proprietary, holder Daniel Espinoza Charrier.
- **Every dependency:** OSS, self-hosted, free — no paid license.
- **No copyleft reach** onto our code under the unmodified-official-images / mere-aggregation reading.
- **Our own §13 duty (as operator):** because we *run* AGPL components, we must offer their unmodified
  source to people who interact with them — a separate, trivially-met obligation (point to each project's
  public upstream). It does not affect our own code's license.
- **Open items:** entity/commissioning question (holder revisited if a legal entity forms or the work is
  deemed commissioned); Euro-Office §7 dispute if it's chosen for production; re-run §4 if we ever modify or
  fork a component.
