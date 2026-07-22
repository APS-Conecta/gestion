# ADR-0001 — Actas access & publication model

- **Status:** Accepted
- **Date:** 2026-07-21
- **Context:** Libro de Actas app (Layer-2, first custom app)
- **Supersedes:** the PRD §4.4 first-cut access-matrix row *"Transversal/Actas de reuniones/«programa» → Read = All staff"*

## Context

The committed PRD models *Actas de reuniones* as **all-staff-readable** transparency documents living in a
Transversal group folder. During design we established that real actas carry a **free-text (desarrollo)**
field that may contain **patient PII** (RUT, nombre, dirección, teléfono, email, causas legales, RIT,
causas judiciales). "All-staff read" over such content would leak PII to the whole CESFAM, and Ley 21.719
(in force 01-DIC-2026) makes that unlawful (Arts. 14 quinquies, 16, 16 bis).

We also could not enforce a disclaimer/audit gate on files sitting in a normal group folder — the Files app,
Collabora and WebDAV bypass any custom app, and we may not patch core (AD-1/AD-9).

## Decision

An acta has **two faces**, and the app is the **only gateway** to the sensitive one:

1. **Acta record (system of record)** — held in **app-controlled storage** (the vault), never a browsable
   group folder. Access is **restricted to the owning *equipo* group + `cat-jefaturas`**, not all-staff.
   The reserved free-text is **encrypted at rest**. Opening a *sensitive-flagged* acta requires accepting a
   **disclaimer**, which writes an **access-log** entry (uid + timestamp to the minute). The disclaimer is an
   **accountability gate, not a barrier**: a cleared viewer sees the full acta including free-text.

2. **Sanitized transversal copy** — an **opt-in** published copy in `Transversal/Actas de reuniones/«equipo»`
   (all-staff), built by an **allowlist** (metadata + structured fields + acuerdos only). **Free prose is
   never auto-published** — the deterministic scan cannot catch names/addresses, so auto-publishing prose
   could leak. Narrative reaches a public copy only via a **human-reviewed quarantine** approval by
   jefatura/dirección/SOME. **Clinical** actas: prose is never published (hard floor).

Supporting rules:

- **Registro (listing) is access-scoped** — raw acta stubs are never shown to all-staff (a meeting's mere
  existence can be sensitive). All-staff visibility comes only from published transversal copies.
- **Publication is held-until-cleared** — every candidate public copy waits for an overnight scan; clean →
  auto (allowlist level); flagged/declared-sensitive → quarantine review.
- **Bulk export (compilado)** is sanitized (no reserved prose), role-restricted, access-scoped, signed,
  audited and watermarked.
- **Immutability** — a finalized acta is frozen; corrections are **addenda** (append-only), never edits.

## Consequences

- **Positive:** PII cannot leak to all-staff by construction; the transparency promise is kept via sanitized
  copies; every sensitive access is signed and logged (the *respaldo* Dirección/SOME can audit); compliant
  with Ley 21.719's security, minimization and secrecy duties.
- **Cost:** the generated acta is not a plain file in a group folder (all access flows through the app); a
  second publication level (quarantine review) exists; the PRD access-matrix row is reversed and must be
  read together with this ADR.
- **Follow-up:** the EIPD (Art. 15 ter) formalizes the legal basis, retention window, and supresión
  reconciliation; see `../compliance-ley-21719.md`.

## Alternatives considered

- **Files in group folders, disclaimer best-effort** — rejected: direct Files/Collabora/WebDAV access
  bypasses the gate; unauditable access to real PII.
- **Blocklist masking + fully automatic publication** — rejected: relies on catching 100% of PII; fuzzy
  identifiers (names/addresses) defeat any parser → all-staff leak.
- **Keep the PRD's all-staff-read default, protect only flagged spans** — rejected: same leak risk and
  unlawful for health data.
