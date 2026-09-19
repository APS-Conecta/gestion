# Licensing — APS Conecta Gestión

This is the committed **license-outline SSOT artifact** the architecture spine defers under NFR-3.
It records the license of APS Conecta's own code and of every third-party component the stack runs,
and reasons about whether running them triggers any obligation on our own code.

> **Not legal advice.** This is an engineering audit. The third-party license facts are verified
> against each project's authoritative source (below); the *reasoning* about obligations is ours and
> the points marked **[needs legal sign-off]** should be confirmed by a lawyer before being relied on.
> Third-party licenses verified **2026-07-19**, extended **2026-07-30** to `side_menu`, Fraunces and
> Nunito Sans; own-code licence changed to AGPL-3.0-or-later **2026-08-07** (ADR-0010) — against the versions this repo runs: the services pinned in `compose.yaml` plus the
> three Nextcloud apps installed by provisioning (`occ`).

## 1. APS Conecta's own code — AGPL-3.0-or-later

1. The project's **own original work** (code under `apps/`, `themes/`, `provisioning/`, `scripts/`,
   plus this repo's configuration and documentation) is licensed **AGPL-3.0-or-later** — see
   [`LICENSE`](../LICENSE) and
   [ADR-0010](adr/0010-agpl-across-the-org.md).
2. **Why AGPL (reasoning, not assertion).** For *this* repository the licence was a free choice —
   §4 below shows the copyleft of the components we run never reaches our code. It was not free
   elsewhere: `territorio` and `epidemiologia` compile `@nextcloud/vue`
   (AGPL-3.0-or-later) into the bundles they ship, so those two were obliged. Given that, one
   licence across the organisation was worth more than keeping this repository proprietary on its
   own. ADR-0010 records the trade in full.
3. **Copyright holder** = **Daniel Espinoza Charrier** (individually). No legal entity ("razón
   social") for "APS Conecta" exists yet, so copyright vests in the individual. If a legal entity is
   later formed, or if this work is deemed commissioned by / funded for a third party (e.g. the
   health center), the holder must be revisited — **[needs legal sign-off]**.
4. **The brand is carved out.** The logo, mono logo, lockup and favicon in
   `aps-conecta-web/themes/apsconecta/assets/logo/` are all rights reserved and the marks are
   reserved under AGPL §7(e). Colour tokens ship under the AGPL with the code.

## 2. "OSS-first" now extends to our own work

The project's OSS-first mandate (brief / PRD NFR-3) used to govern only our **inputs**; our own
output was proprietary, and the two were reconciled by noting they addressed different things.

That reconciliation is no longer needed. Since ADR-0010 the mandate and the licence point the same
way: every component the stack runs is open-source, self-hosted and free (verified in §3), **and**
the code we write is open-source too. The organisation may now describe its own work as open
source — the previous instruction not to is withdrawn.

What has not changed: we still do not *redistribute* anything. The AGPL's duties are owed to whoever
receives the code or uses it over a network, which today means clinic staff.

## 3. Third-party component inventory (verified)

Every runtime component. The **services** are pinned as images in [`compose.yaml`](../compose.yaml);
the **six Nextcloud apps** a release installs are installed via `occ`, not as compose services — the
authority for which ones is `APPS` and `OWN_APPS` in
[`provisioning/phases/12-apps.sh`](../provisioning/phases/12-apps.sh), and this table must list every
entry in both. All are open-source, self-hosted, and free — **no paid license, no license key**
anywhere in the stack.

*Corrected 2026-08-08.* This section said "the three Nextcloud apps" and listed three, while
provisioning installed six: `calendar`, `contacts` and our own `epidemiologia` were absent. That last
omission mattered most — `epidemiologia` is the app whose `@nextcloud/vue` bundle is *why* the AGPL is
compelled on this organisation at all (§1.2), so the inventory was missing its own cause. Licences
below were read from each app's `appinfo/info.xml` inside the shipped tarball, not from memory.

| Component | Pinned / installed as | License | SPDX | Source |
|-----------|------------------------|---------|------|--------|
| Nextcloud Server | image `nextcloud:34-apache` | GNU AGPL v3 or later | `AGPL-3.0-or-later` | nextcloud/server `COPYING` + README |
| PostgreSQL | image `postgres:18-alpine` | PostgreSQL License (permissive) | `PostgreSQL` | postgresql.org/about/licence |
| Redis | image `redis:8-alpine` | Tri-license — **we elect AGPL v3** | `AGPL-3.0-or-later` | redis `LICENSE.txt` (8.x) |
| Euro-Office (office) | image `ghcr.io/euro-office/documentserver` | GNU AGPL v3 | `AGPL-3.0-only` | Euro-Office/DocumentServer `LICENSE` |
| Group Folders | NC app `groupfolders` 22.0.6 (vendored tarball, #98) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `groupfolders` `info.xml` |
| Euro-Office connector | NC app `eurooffice` 11.0.4 (vendored tarball, #98) | GNU AGPL v3 **only** | `AGPL-3.0-only` | `eurooffice` `info.xml` (`<licence>AGPL-3.0-only</licence>`) |
| Side menu | NC app `side_menu` 6.0.1 (vendored tarball, #98) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `side_menu` `info.xml` (`<licence>agpl</licence>`) |
| Calendar | NC app `calendar` 6.5.4 (vendored tarball, #98) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `calendar` `info.xml` (`<licence>agpl</licence>`) |
| Contacts | NC app `contacts` 8.8.1 (vendored tarball, #98) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `contacts` `info.xml` |
| Talk | NC app `spreed` 24.0.5 (vendored tarball, #98) | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `spreed` `info.xml` (`<licence>agpl</licence>`) |
| Desktop Workspace | NC app `desktop_workspace` 0.18.2 (vendored tarball, #98) — **third party**, `canisdata`, not the Nextcloud organisation | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `desktop_workspace` `info.xml` |
| Epidemiología | NC app `epidemiologia` 0.9.0 — **ours**, built from a tag of its own repo | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `epidemiologia` `info.xml`; compiles `@nextcloud/vue`, which is why §1 is not a free choice |
| Farmacia | NC app `farmacia` 0.11.1 — **ours**, built from a tag of its own repo | GNU AGPL v3 or later | `AGPL-3.0-or-later` | `farmacia` `info.xml` |
| Fraunces | `themes/apsconecta/core/fonts/*.woff2` (served by the theme) | SIL Open Font License 1.1 | `OFL-1.1` | Fraunces `OFL.txt` |
| Nunito Sans | `themes/apsconecta/core/fonts/*.woff2` (served by the theme) | SIL Open Font License 1.1 | `OFL-1.1` | Nunito Sans `OFL.txt` |

> **`agpl` is not a typo.** Nextcloud's schema has always accepted the bare string, and the app
> store renders it as AGPL v3 or later; `calendar`, `side_menu` and `spreed` still declare it that way while
> `groupfolders`, `contacts` and `eurooffice` have moved to SPDX. The SPDX column above says what
> each app's own `info.xml` declares, normalised — and `scripts/test.sh` now fails if this table and
> an `info.xml` disagree, because reading is what missed `eurooffice` being `-only` through two
> documentation audits (#87, #88) and a version bump (#167) that edited the very same row.

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
   Conecta's own original code**, which is therefore AGPL by *choice* rather than by obligation — see
   §1.2. This paragraph read "may therefore remain proprietary" until 2026-08-08, citing a §1 that
   ADR-0010 had already reversed: the aggregation analysis survived the relicence, its conclusion
   did not.
4. **Caveat that would change this:** the moment we *modify* an AGPL component's source, or bundle/fork it
   rather than pull the official image, the AGPL's network-copyleft (§13) can attach.
5. **Re-examined 2026-07-30, after [ADR-0002](adr/0002-app-patches.md) (2026-07-29) met that trigger.**
   Provisioning now applies committed `.patch` files to two AGPL apps (`eurooffice`, `side_menu`) inside
   the running container. The conclusion is unchanged, for three reasons that all have to hold: the image
   is pulled unmodified and never rebuilt; the patches are applied at run time to a private instance and
   **nothing is redistributed** — §13's duty is to *our users*, and it is discharged by pointing them at
   upstream source, which the patch does not alter; and the patched apps' own AGPL text still reaches
   anyone who asks. What *would* break it: shipping a patched image, or offering the patched apps to
   third parties. **[needs legal sign-off]**

## 5. Summary

- **Our code:** AGPL-3.0-or-later, holder Daniel Espinoza Charrier (brand assets carved out).
- **Every dependency:** OSS, self-hosted, free — no paid license.
- **No copyleft reach** onto *this* repository's code under the unmodified-official-images /
  mere-aggregation reading — §4 stands. The AGPL here is chosen, not compelled. It *is* compelled in
  the three Nextcloud apps, which bundle `@nextcloud/vue`.
- **Our own §13 duty (as operator):** because we *run* AGPL components, we must offer their unmodified
  source to people who interact with them — a separate, trivially-met obligation (point to each project's
  public upstream). Since ADR-0010 our own code carries the same duty, discharged the same way.
- **Open items:** entity/commissioning question (holder revisited if a legal entity forms or the work is
  deemed commissioned); Euro-Office §7 dispute if it's chosen for production; re-run §4 if we ever modify or
  fork a component.
