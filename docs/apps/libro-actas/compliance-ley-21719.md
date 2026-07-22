---
title: "Compliance map — Ley 21.719 → APS Conecta Gestión (Libro de Actas + suite)"
laws:
  - ../../legal/ley-21719-datos-personales.md   # amending law, in force 2026-12-01
  - ../../legal/ley-19628-vida-privada.md       # base law it rewrites
in_force_from: "2026-12-01"
status: living-checklist
---

# Compliance map — Ley 21.719

**Deadline: 01-DIC-2026.** This maps each relevant obligation of Ley 21.719 (amending Ley 19.628) to a
design decision in APS Conecta Gestión, so compliance is auditable. Article numbers refer to Ley 19.628
*as amended by* 21.719 (see `../../legal/ley-21719-datos-personales.md`). Rows are **APP** (enforced in the Libro de
Actas app), **ORG** (organizational duty of the CESFAM as *responsable de datos* — process/policy, not code),
or **BOTH**.

## Guiding principle (the compliance-driven design stance)

Art. 16 bis: **health data may only be processed for purposes set by special health legislation.** This app
is an **internal-ops / administrative** system, **not** a clinical records system (per AGENTS.md / AD-3). So
the compliant posture is **data minimization by design** (Art. 14 quáter): the app must *discourage and
minimize* patient PII, never invite it. The DLP/quarantine machinery exists to **catch the accidental /
residual** PII that slips into free-text — not to host patient data on purpose.

## Obligation → design mapping

| # | Art. | Obligation | Scope | How we comply |
|---|------|-----------|-------|---------------|
| 1 | 2 g) | **Definition of dato sensible** — includes *datos relativos a la salud*. RUT alone is personal, **not** sensitive. | — | Scanner tiers severity: health/clinical mentions = sensitive (strongest controls); RUT/email/phone = personal (encrypt + audit, lower tier). |
| 2 | 3 | **Principles**: licitud, finalidad, proporcionalidad, calidad, responsabilidad, seguridad, transparencia, confidencialidad. | BOTH | Purpose-bound (actas de reunión only); structured fields minimize collection; encryption + RBAC + audit for seguridad; this file + privacy policy for transparencia. |
| 3 | 14 bis | **Deber de secreto/confidencialidad** — subsists after the relationship ends. | BOTH | Per-team access restriction; disclaimer + access-log gate; staff confidentiality clause (ORG). |
| 4 | 14 ter | **Deber de información y transparencia** — publish a privacy policy: categories, purposes, legal basis, retention period, rights, contact. | ORG | CESFAM publishes a *Política de tratamiento de datos*; app links to it. **Action: draft the policy.** |
| 5 | 14 quáter | **Protección desde el diseño y por defecto** — only strictly necessary data, by default. | APP | Structured-first data model; free-text discouraged; **allowlist publication** (public copy built only from known-safe content); minimal retention/accessibility by default. |
| 6 | 14 quinquies | **Medidas de seguridad** — must include **seudonimización y cifrado**, confidentiality/integrity/availability/resilience, restore capability, regular testing. **Burden of proof on the responsable.** | BOTH | Free-text + sensitive fields **encrypted at rest** (ICrypto, key outside DB); RBAC via groups; backups (stack); access-log = evidence. **Action: document the security measures (this file + runbook).** |
| 7 | 14 sexies | **Breach notification** — report to the Agencia without undue delay; keep a breach register; heightened for sensitive data. | ORG | **Action: breach-response runbook + register.** App's access-log aids forensics. |
| 8 | 15 ter | **Evaluación de impacto (EIPD/DPIA)** — required **always** for sensitive/especially-protected data under consent exceptions. | ORG | **Action: complete an EIPD before go-live** (companion doc). This app processes health-adjacent sensitive data → EIPD mandatory. |
| 9 | 16 | **Sensitive data → express consent**, with limited exceptions (vital interest, legal defense, labor/social-security, legal mandate). | BOTH | App is administrative; staff/council PII rides on the employment/participation basis (Art. 16 e). **EIPD documents the legal basis per data category.** |
| 10 | 16 bis | **Health/biological data — only for purposes of special health law.** An internal-ops actas app is **not** such a purpose, so storing patient health data may lack any legal basis — protection alone is insufficient. | BOTH | **App actively discourages/prompts removal of patient identifiers** (not just masks them); patient PII is treated as residual/accidental, minimized by design. Reinforces the AGENTS.md "no patient data" invariant. |
| 10b | 7 | **Derecho de supresión vs acta immutability** — a titular may request deletion; actas are immutable permanent records. | BOTH | Supresión served on the **reserved PII** (redact/delete that datum via the retention mechanism); the administrative record stays under the **official-records exemption**. Exact reconciliation decided in the **EIPD**. |
| 10c | 14 ter l) | **Disclose automated processing** — the transparency notice must mention the automated PII **scanning/flagging**. | ORG | Privacy policy names the deterministic scan (+ optional local NER); no automated decisions with legal effect on titulares. |
| 10d | — | **All-local processing** (no cloud AI, no external processor, no cross-border transfer). | — | **Compliance asset:** no *encargado* obligations, no international-transfer safeguards needed. Why detection/NER must stay local. |
| 11 | 5 | **Derecho de acceso** | BOTH | Registrante + access-log make an individual's data locatable; ORG process to answer requests. |
| 12 | 7 | **Derecho de supresión** | BOTH | Actas deletable/anonymizable by authorized role; retention job (row 15). |
| 13 | — | **Rectificación / oposición** | BOTH | Edit + draft workflow; ORG process. |
| 14 | 9 | **Derecho a la portabilidad** | APP | Structured actas export (docx/odt already; structured data export on request). |
| 15 | 14 quáter / principio calidad | **Retention limits** — no indefinite storage; delete/anonymize past purpose. | APP | **Split retention:** administrative acta = permanent record (no PII → no limit); reserved free-text (PII) = **configurable crypto-shred window, default permanent** for now, logged as an anonymization event (preserves immutability). App is compliant-capable; **EIPD must set a real window before go-live** (permanent PII retention is a live Art. 14 quáter risk). |
| 16 | primero transit. | **Entry into force 01-DIC-2026.** | — | Compliance must be in place before go-live and before this date. |

## Open compliance actions (not code)

- [ ] **EIPD/DPIA** for the actas processing (Art. 15 ter) — companion doc, before go-live.
- [ ] **Política de tratamiento de datos** published by the CESFAM (Art. 14 ter).
- [ ] **Security-measures document** + **breach-response runbook & register** (Art. 14 quinquies, 14 sexies).
- [ ] **Retention policy** value (window) agreed with the CESFAM (Art. 14 quáter / calidad).
- [ ] Confirm **legal basis** for any health data reaching actas rests on health legislation, not app consent (Art. 16 bis).

> These files are a reference copy for analysis; the BCN pages are the legal SSOT. Legal review by a
> qualified professional is required — this map is engineering's compliance scaffolding, not legal advice.
