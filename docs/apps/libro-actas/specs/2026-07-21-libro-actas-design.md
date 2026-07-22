---
title: "Libro de Actas — design spec"
app_id: libro_actas
status: approved-design
created: 2026-07-21
context: docs/apps/libro-actas/CONTEXT.md
decisions: docs/apps/libro-actas/adr/0001-actas-access-and-publication-model.md
compliance: docs/apps/libro-actas/compliance-ley-21719.md
laws: [docs/legal/ley-21719-datos-personales.md, docs/legal/ley-19628-vida-privada.md]
ui_kit: "@nextcloud/vue (Vue 3, NC34 line) — https://nextcloud-vue-components.netlify.app/"
---

# Libro de Actas — design spec

A Nextcloud 34 custom app (Layer-2) for recording, tracking, generating and publishing **actas de reunión**
for a CESFAM. UI in Spanish (es-CL); code/identifiers in English. Terms below are used verbatim from
[`CONTEXT.md`](../CONTEXT.md). This spec consolidates the design; it is the input to the implementation plan.

## 1. Purpose & non-goals

- **Purpose:** one permissioned place to write an acta (structured + free-text), track **acuerdos** to
  completion across meetings, **generate** the acta as `.docx`/`.odt`, **publish** a sanitized transversal
  copy for transparency, and **search/audit** actas — with strong protection for any patient PII.
- **Non-goals:** it is **not** a clinical/patient-records system (AGENTS.md, AD-3). Patient PII is treated as
  **residual/accidental** and actively discouraged (see §6). No cloud AI; all processing is local.

## 2. Invariant amendment (prerequisite)

This app deliberately stores possible patient PII in the free-text field, contradicting AGENTS.md/AD-3
("no patient data"). ADR-0001 + the EIPD scope the exception to this app with the safeguards below. This must
be recorded before code lands.

## 3. Architecture

- Standard NC34 app in `apps/libro_actas/` (bind-mounted, `custom_apps`), **OCP public APIs only** (AD-9).
- **Backend:** PHP — Controllers → Services → QBMapper on **PostgreSQL**. `OCP\Migration` for schema.
- **Frontend:** Vue 3 with **`@nextcloud/vue`** components (inherits white-label theming, dark mode, a11y).
- **Vault:** generated documents + encrypted blobs in app-controlled storage (`OCP\Files\IAppData`), never a
  browsable group folder.
- **Reusable building block:** an `EquipoService` resolving a team group → its group folder + calendar +
  members (via `IGroupManager`/`IUserManager`/OCP Files/Calendar). Bounded now; extract to a shared module
  when a second app (e.g. REM) needs it — not before.
- **Branch/flow:** built in `feat/app-libro-actas`, PR + 1 approval per the convention gate.

## 4. Domain model (PostgreSQL, QBMapper)

- **`actas`** — id, **folio** (correlative per equipo+year, atomic on finalize), **equipo** (team group id:
  `prog-*`/unidad/`sector-*`), tipo_reunion, tipo_actividad, estado, fecha, **hora_inicio**, **hora_termino**,
  lugar, quorum (bool) + n_participantes (derived), lectura_acta_anterior (ref + aprobada S/N + obs),
  proxima_reunion (datetime), **contenido_libre (encrypted blob)**, is_sensitive (bool), registrante (uid),
  firma (uid+ts on finalize), is_finalized, created/updated.
- **`acta_attendees`** — acta_id, uid, snapshot(nombre, rol, equipo) at save time.
- **`acta_guests`** — acta_id, nombre, primer_apellido, segundo_apellido, rol_cargo (structured, searchable).
- **`acuerdos`** — id, equipo, **texto (immutable)**, responsable (uid, optional), fecha_compromiso (opt),
  estado (pendiente/cumplido), creado_en_acta, cerrado_en_acta.
- **`acuerdo_history`** — acuerdo_id, acta_id, new_estado, ts. Current estado = latest row (no event-sourcing).
- **`acta_addenda`** — id, acta_id (parent), folio (parent + version), author uid+ts, motivo, cambios, own
  is_sensitive + gate.
- **`acta_access_log`** — acta_id (or export scope), uid, ts (to the minute), action (view/export), disclaimer.
- **`acta_drafts`** — per-author borrador payload (autosave); private until finalized.
- **`acta_calendar_link`** — acta_id → calendar event ref.
- **App config** — vocabularies: tipo_reunion, tipo_actividad, estado, tags (admin settings, seeded).

## 5. Field model & vocabularies

- **Directory-synced (live, no duplication):** equipo ← team groups; rol/cargo ← `role-*`; registrante +
  attendees ← user directory (via OCP). Add a team/role in the suite → appears here.
- **Guests** — structured 4-field rows (searchable), not free-text.
- **Admin-editable vocabularies** — tipo_reunion, tipo_actividad, estado, tags (settings page, seeded defaults).
- **Free-text (desarrollo)** — the single unstructured field; the only PII surface.

## 6. Sensitive-data protection (targeted at `contenido_libre`)

- **Discourage first (Art. 16 bis):** the UI prompts the registrante to **remove patient identifiers**; PII
  is residual, not designed-for.
- **At rest:** `contenido_libre` encrypted via `OCP\Security\ICrypto` (key from instance secret, outside DB).
- **Detection (deterministic-first):** parsers for RUT (**módulo-11 check digit**), email, teléfono, RIT;
  a match **auto-sets is_sensitive** and warns. Local NER (Layer-3, optional, behind a toggle) is a later
  fallback for fuzzy PII (names/addresses) — **always local, detection-only**.
- **Access gate:** opening a **sensitive** acta requires accepting a disclaimer → writes `acta_access_log`.
  Accountability gate, **not** a barrier — cleared viewers see everything (§8).
- **Search isolation:** `contenido_libre` is never indexed / never sent to any search or AI pipeline.

## 7. Access, publication & search (ADR-0001)

- **Registro (listing):** access-scoped (own equipos; jefaturas see all). No all-staff stubs.
- **Acta record:** app vault; restricted to owning equipo + `cat-jefaturas`; disclaimer+audit on sensitive.
- **Transversal copy (opt-in, allowlist):** auto level = metadata + structured + acuerdos, published to
  `Transversal/Actas de reuniones/«equipo»` (all-staff). **Free prose never auto-published.** Narrative →
  human-reviewed **quarantine** approval (jefatura/dirección/SOME). **Clinical = hard floor** (no prose).
- **Held-until-cleared:** every candidate public copy waits for an overnight background scan; clean → auto;
  flagged/declared → quarantine queue (with **notifications** to reviewers).
- **Search (v1):** in-app Registro filters (equipo, tipo, estado, fecha range, tags, attendee/guest names) —
  never `contenido_libre`. Unified-search provider deferred.

## 8. Complete review & clearance

A cleared viewer (access-scoped: own equipo, or jefatura) reads the **full acta including free-text**.
"Clearance" = access scope + (for sensitive actas) the signed disclaimer. Non-sensitive free-text: no
friction. Guarantees "si se necesita, alguien autorizado lo revisa completo." Prose restrictions
(auto-publish, bulk export) apply only to viewers **without** clearance.

## 9. Authoring workflow

- **Create:** any member of an equipo may create an acta for that equipo.
- **Borrador:** private to author, **autosaved**; only the author edits.
- **Firma (finalize):** the registrante's *firma electrónica simple* (uid+ts) freezes the draft into an
  immutable acta and assigns the folio (atomic). Optional wet-ink signature block in the document.
- **Corrections:** finalized actas are immutable → **addendum** only (append-only, own folio version + gate).

## 10. Acuerdos (living, across meetings)

- Optional structure: only `texto` required; responsable/fecha/estado opt-in (agnostic to loose vs tracked).
- **Living entity** with immutable `texto`; estado moves via `acuerdo_history` rows anchored to actas.
- **Acuerdos pendientes** view per equipo; **lectura del acta anterior** auto-loads open acuerdos to review;
  "no aprobada" → prompt an addendum to the prior acta.

## 11. Generar Acta

- **PhpWord**, build-once/export-twice → `.docx` + `.odt`, stored in the vault. Sensitive actas' vault files
  encrypted at rest, served decrypted only after the disclaimer.
- **Agnostic house layout:** cover (logo, **folio**, equipo, tipo) · datos (fecha, hora inicio/término,
  lugar, n° participantes, **quórum**) · asistentes (users + guests) · lectura/aprobación del acta anterior ·
  **acuerdos** (incl. revisión de pendientes) · desarrollo (free-text; masked/omitted in the transversal
  copy) · próxima reunión · firma + bloque de tinta · pie (generado por/fecha, "documento interno").
- PDF via the running office server = later add.

## 12. Bulk export (compilado)

Sanitized single document: cover + **index/outline**, one section per acta (folio, fecha, equipo, tipo,
asistentes, quórum, acuerdos, próxima reunión). **No reserved free-text bundled.** Role-restricted
(jefatura/dirección/SOME), access-scoped, requires **disclaimer + firma + audit**, **watermarked** with
exporter + timestamp.

## 13. Calendar sync

One-way (app → Calendar), **per-equipo shared calendar** (provisioned + group-shared). On finalize with a
*próxima reunión*, create/update an event (`OCP\Calendar\ICreateFromString`) linking back to the acta.
The acta immutably records the planned date; the event is a mutable convenience. Acuerdo due-date reminders
deferred.

## 14. Retention (Ley 21.719, Art. 14 quáter)

Split: **administrative acta = permanent record** (no PII → no limit); **reserved free-text = configurable
window, default permanent for now** → at end-of-window, **securely delete the encrypted blob/field**, logged
as an anonymization event (immutability preserved). App is compliant-capable; the **EIPD sets the real
window** before go-live. Backups vs purge: purge doesn't reach old backups — an EIPD/ORG note.

## 15. Compliance (Ley 21.719)

Full obligation → design map in [`compliance-ley-21719.md`](../compliance-ley-21719.md). Key: encryption
(14 quinquies), minimization/privacy-by-design (14 quáter), secrecy (14 bis), disclosure of automated
scanning (14 ter), breach reporting (14 sexies, ORG), **EIPD required** (15 ter), sensitive/health-data basis
(16, 16 bis) — reinforcing "discourage patient PII". All-local processing = no *encargado* / no cross-border
obligations. **In force 01-DIC-2026.**

## 16. Notifications, jobs, i18n, a11y

- **Notifications** (OCP) — acta awaiting quarantine review (to jefaturas), acta finalized in your equipo.
- **Background jobs** — overnight publication scan; retention purge (when a window is set).
- **i18n/l10n** — Spanish UI via Nextcloud gettext/.po; **a11y** via `@nextcloud/vue` + WCAG basics.
- **Fixtures/provisioning (AD-2)** — seed vocabularies, sample actas, create+group-share per-team calendars.

## 17. Phasing (reviewable PRs, each leaves the app working)

- **PR0 · Foundations** — ADR-0001, this spec, CONTEXT, compliance map; app skeleton (`info.xml`, enable).
- **PR1 · Core + security spine (MVP)** — model + migrations; directory-synced vocabularies + admin settings;
  create/edit **private borrador** + autosave; **firma → finalize → immutable**; folio (atomic)/quórum/times/
  attendees+guests; **encryption + is_sensitive + deterministic RUT(módulo-11)/email/tel/RIT scan +
  disclaimer/audit gate**; access-scoped Registro.
- **PR2 · Acuerdos** — entity + history + pendientes view + lectura/aprobación anterior + **addenda**.
- **PR3 · Generar Acta** — PhpWord `.docx`/`.odt` → vault.
- **PR4 · Transversal publication** — allowlist copy + **quarantine queue** + overnight scan job + jefatura
  approval + **notifications**.
- **PR5 · Calendar sync** — one-way, per-equipo calendar (+ provisioning).
- **PR6 · Retention** — configurable purge job (default off/permanent).
- **PR7 · Bulk export** — sanitized compilado, signed/audited/watermarked.
- **later** — local-AI NER fallback; unified-search provider; attachments; multi-team actas; PDF.

## 18. Testing

PHPUnit on services (encryption round-trip, RUT módulo-11, folio atomicity, allowlist publication, acuerdo
projection, generator); the repo's `make test` static+smoke gate before each PR.

## 19. References

- Component kit: `@nextcloud/vue` — https://nextcloud-vue-components.netlify.app/ (pull live docs via Context7).
- Nextcloud app dev docs (via Context7 MCP, per README).
- Laws: `docs/legal/` · Compliance map: `../compliance-ley-21719.md` · Glossary: `../CONTEXT.md` · ADR: `adr/`.
