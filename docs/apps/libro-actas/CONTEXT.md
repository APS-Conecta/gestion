# CONTEXT — Libro de Actas (app glossary)

Domain language for the **Libro de Actas** app context. Authoritative for this app only; suite-wide
terms live in the PRD §3 glossary (see `../../../CONTEXT-MAP.md`). Terms are used verbatim across specs,
code identifiers (English), and UI (Spanish). A synonym introduced elsewhere is a discipline violation.

This file captures terms resolved during design. Where a term overlaps the PRD §3 glossary, the PRD is
the older SSOT and any divergence must be reconciled by an ADR, not a silent redefinition. The
data-protection terms below are suite-wide by nature but live here until a second app needs them, at
which point they get promoted (per the CONTEXT-MAP rules).

## Actas domain (Libro de Actas app)

- **Equipo (owning team)** — the team that owns an acta: **any team group** — a programa (`prog-*`), a
  unidad (SOME, Farmacia, Dental, OIRS, Estadística-REM, Dirección…), or a sector (`sector-*`). *Not* limited
  to programas. Its members are the group's members. An equipo resolves to its Epic-3 **group folder** and its
  **per-team calendar**. This equipo↔folder↔calendar↔members resolution is a **reusable building block** for
  future apps (e.g. the REM app); build it as a bounded service in `libro_actas` now, extract to a shared
  module when a second app needs it (no shared library until then). The UI labels it "Programa/Equipo".

- **Acta** — the official record of a CESFAM meeting (agreements, attendance, operational/community
  reports). One acta has **two faces**: the *record* (below) and, optionally, a *sanitized transversal
  copy* (below). The PRD term **"Acta de reuniones"** refers to the same object; "Acta" is the record,
  "Actas de reuniones" is the PRD's folder/collection name for their published copies.

- **Acta record** — the authoritative acta held by the **Libro de Actas** app (system of record).
  Structured fields + one free-text field. Access is **restricted to the owning team by default**
  (not all-staff). This is deliberately narrower than the PRD's "Actas de reuniones = All staff read"
  and supersedes it (see the ADR reversing that access-matrix row).

- **Libro de Actas** — the application that is the system of record for actas. A Layer-2 custom
  Nextcloud app (`apps/libro_actas`). Reconciles with the PRD's "Actas de reuniones" collection: the
  app *produces* the actas that the PRD tree *publishes*.

- **Free-text (contenido libre)** — the single unstructured field of an acta record; the **only** place
  sensitive personal/patient data may appear. Everything else in an acta is structured and safe.

- **Borrador (draft)** — an unfinalized acta, **private to its author** (registrante), autosaved. Only the
  author edits it; the team sees nothing until it is signed. Any programa member may create a borrador for
  their programa (no dedicated secretario/a role). Signing (*firma*) turns it into a finalized, immutable acta.

- **Sensitive span** — a fragment of free-text that is personal/legal PII: RUT, nombre, apellido,
  dirección, email, teléfono, causas legales, RIT, causas judiciales. Detected deterministically
  (parsers/regex) first; a local-only NER model is a last-resort fallback (detection only, never leaves
  the instance).

- **Sensitive acta** — an acta record flagged as containing at least one sensitive span (flagged by the
  registrante, or auto-flagged when detection finds a span). Only sensitive actas trigger the
  disclaimer + access-log gate.

- **Sanitized transversal copy (copia transversal saneada)** — a published copy of an acta placed in the
  all-staff `Transversal/Actas de reuniones/«programa»` folder, carrying a pointer back to the app for full
  access. Two publication levels, by the **allowlist** rule (never publish prose we can't prove clean):
  - **Auto (no human):** metadata + structured fields + acuerdos only. Free prose (*desarrollo*) is **never**
    auto-published — the deterministic scan can't catch names/addresses, so auto-publishing prose could leak.
  - **Human-reviewed:** to include narrative in the public copy, a jefatura reviews a masked version in a
    **quarantine queue** and explicitly approves it. Clinical actas: prose never published (hard floor).
  Publishing is always a deliberate act, never a silent side effect of saving an acta.

- **Registro (listing) scope** — the in-app acta list is **access-scoped**: a user sees actas of their
  programas; jefaturas see all. Raw acta stubs are **not** shown to all-staff (the mere existence of a
  meeting can be sensitive). All-staff visibility comes **only** from published transversal copies.

- **Acta (immutable rule)** — once an acta is **finalized/published** it is frozen: its content and its
  generated document never change. Drafts (*borrador*) are editable; finalization freezes.

- **Addendum** — the only way to correct a finalized acta. A new, linked record that references the original,
  states *what* changed and *why*, stamped with author + timestamp. Corrections **append**, never overwrite —
  the original stays intact, the addendum chain is the follow-up trail. Information can be *fixed*, not *altered*.

- **Acuerdo** — a **living** agreement/commitment tracked across meetings (`texto`, `responsable`,
  `fecha compromiso`, `programa`, `estado`: pendiente/cumplido, `creado_en_acta`, `cerrado_en_acta`). It
  **outlives** any single acta. Its current `estado` is a projection of its acuerdo-events. Optional structure:
  only `texto` is required; owner/date/estado are opt-in per acuerdo (agnostic to loose vs tracked styles).

- **Acuerdo event** — a row in a plain `acuerdo_history` table (acuerdo_id, acta_id, new estado, timestamp)
  written whenever an acta creates/reviews/closes an acuerdo. The acuerdo's current estado is simply the
  latest row — no event-sourcing machinery. Its `texto` is **immutable** (set at creation); only
  estado/responsable/fecha move. Anchors every status change to a real meeting = the agreements audit trail.

- **Acuerdos pendientes** — the projection view: acuerdos with `estado = pendiente`, per programa. Feeds
  *lectura del acta anterior* (a new acta auto-loads the programa's open acuerdos to review).

- **Folio** — an acta's official correlative identifier, assigned on finalization and immutable: simple
  date+programa coding, e.g. `SM-2026-001` (programa · año · correlativo). An addendum carries the original
  folio plus a version suffix (e.g. `SM-2026-001-A1`).

- **Quórum** — whether the meeting reached its required attendance to be valid (sí/no), alongside the
  participant count (derived from selected attendees + guests). Recorded on the acta.

- **Registrante** — the authenticated user who records an acta; always stamped on the record.

- **Firma** — a *firma electrónica simple*: the registrante's digital sign-off (uid + timestamp) recording
  who **wrote** the acta. It is the single action that finalizes a draft into an immutable acta. Not
  cryptographic (no FEA/PKI); the generated document may still carry a wet-ink signature block.

- **Access-log gate** — on opening a *sensitive* acta, the viewer must accept a disclaimer; acceptance
  writes an access-log entry (uid, timestamp to the minute). The log accumulates for review by
  Dirección / Jefaturas / SOME. The disclaimer is an **accountability gate, not a barrier**: it does not
  hide content — a cleared viewer sees the acta completely, they just sign for the access.

- **Complete review / clearance** — a cleared viewer (access-scoped: their programa, or a jefatura) can
  read the **full acta including the free-text (desarrollo)**. "Clearance" = access scope + (for sensitive
  actas) the signed disclaimer. Non-sensitive free-text reads with no friction. This guarantees "si se
  necesita, alguien autorizado lo revisa completo." Restrictions on prose (auto-publish, bulk export) apply
  only to viewers **without** clearance, never to a cleared person reviewing one acta.

- **Compilado de actas (bulk export)** — an on-demand single document compiling many actas with a cover,
  **index and outline**, one section per acta (folio, fecha, programa, tipo, asistentes, quórum, acuerdos,
  próxima reunión). **Sanitized** — reserved free-text is *not* bundled in (a full-PII compilation is a
  honeypot and is not built; complete content is reviewed per-acta instead). Role-restricted
  (jefatura/dirección/SOME), **access-scoped**, requires **disclaimer + firma + audit-log**, and is
  **watermarked** with exporter + timestamp so a leaked copy is traceable.

## Data-protection law (Ley 21.719, in force 2026-12-01)

Full texts in `docs/legal/`; obligation → design map in `docs/legal/COMPLIANCE-ley-21719.md`.

- **Responsable de datos** — the CESFAM, legally accountable for the processing this app performs.
- **Titular** — the natural person a datum concerns (a patient, a staff member, a council member).
- **Dato personal** — any datum identifying a titular (e.g. RUT, name, email). Personal but **not**
  automatically sensitive.
- **Dato sensible** — a legally heightened category incl. **datos relativos a la salud**; needs express
  consent or a legal exception. In an acta these appear only in free-text.
- **EIPD** (Evaluación de Impacto en Protección de Datos, ≈ DPIA) — the mandatory pre-go-live risk
  assessment when processing sensitive data (Art. 15 ter).
- **Anonimización** — irreversible removal of identifiability. **Seudonimización** — reversible
  masking/tokenization. The public copy uses masking; retention uses anonymization/deletion.
