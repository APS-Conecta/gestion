# Agile operating model — APS Conecta Gestión

How a **3-person, part-time team** runs this program (kickoff **2026-07-14**, ~12 months). It is
deliberately light: the goal is working software, not process. This doc owns the *process*; it links to
the artifacts that own everything else (epics, roadmap, contribution rules) rather than restating them.

## Why continuous flow, not sprints

We already work this way: one change at a time, PR-by-PR, merge, continue. Forcing fixed two-week
sprints onto a small part-time team — one member of whom does not write code — would add ceremony
without adding value, and "working software over comprehensive process" is the point. So the model is
**continuous flow (Kanban)**: **the board is the process.** Work is pulled, not pushed; we limit how much
is in progress at once; nothing is timeboxed.

This honors the Agile values at this team's scale:

- **Individuals & interactions over process** — a weekly conversation beats a rulebook.
- **Working software over documentation** — every merged PR is working, gated software.
- **Customer collaboration** — the owner (product side) sits *inside* the flow (design in, UAT out),
  not across a contract boundary.
- **Responding to change** — no sprint commitment to break; re-prioritize the board any day.

## The board

The shared work surface is a single **private, org-level GitHub Projects (v2)** board (stood up when this
model is adopted). Columns:

**Backlog → Ready → In Progress → In Review → UAT / Testing → Done**

- **WIP limits** keep flow honest: at most a couple of items in *In Progress* at once — finish before
  starting. If a column clogs, that is the signal to unblock, not to start more.
- An **Iteration** field marks gentle time buckets for reporting only (not commitments).
- Cards link to the real issues/PRs; issue templates (`.github/ISSUE_TEMPLATE/`) feed the Backlog.

## Roles map to columns

| Role | Owns which columns |
|------|--------------------|
| **Owner** ([@ddespinoza](https://github.com/ddespinoza)) | Fills **Backlog** (what should change, why), sets **Ready** priority (design input), and signs off **UAT / Testing** (acceptance). Reports from **Done**. |
| **Developers** ([@juliomosorio](https://github.com/juliomosorio), [@mmaartinn](https://github.com/mmaartinn)) | Pull from **Ready** → **In Progress** → **In Review** (implementation, debugging, code review). |

The owner files work through the plain-language issue template; the devs through the technical one.

## Cadence (light, not corporate)

- **Weekly async check-in** — each person posts, in writing: what moved on the board, what's blocked.
  Sync only if something needs a conversation.
- **Demo / review** — on a gentle beat (e.g. when a meaningful slice reaches *UAT*), the owner sees it
  working and accepts or bounces it. This is where acceptance happens.
- **Retro** — short, occasional (roughly monthly, or after a rough patch): what to keep, what to change.
  Actions go back on the board.

None of these are gates; they are rhythm. The gates are below.

## Definition of Ready

A card is **Ready** to pull when: it states what should change and **how we'll know it's done**
(acceptance), and it's small enough for one reviewable PR.

## Definition of Done

A card is **Done** when it clears the repo's existing PR gate — **owned by
[`CONTRIBUTING.md`](../../CONTRIBUTING.md)** (`make test`, Conventional Commits, `ai-assisted` disclosure,
**1 approval**) — plus the two things this flow adds:

- For user-visible behavior, the **owner has accepted it in UAT** (e.g. the browser runbook
  [`docs/ACCEPTANCE-EDITING.md`](../ACCEPTANCE-EDITING.md)).
- Docs updated where a fact changed (one owner per fact).

## Where the work comes from

The board is seeded from real, already-scoped work — not a fictional backlog:

- **Done so far:** v1 = Foundation + Spine A (Epics 0–4). See [`ROADMAP.md`](../../ROADMAP.md).
- **The immediate item:** the v1 human browser-acceptance run (`docs/ACCEPTANCE-EDITING.md`).
- **The backlog ahead:** the post-v1 roadmap (Tables → REM app → search → Paperless-ngx → Analytics →
  AI), per [`ROADMAP.md`](../../ROADMAP.md) and [`epics.md`](epics.md). The BMad planning artifacts under
  `docs/planning/` remain the source for scoping each next epic;
  [`sprint-status.yaml`](implementation/sprint-status.yaml) tracks story state (a BMad artifact name — we
  track flow on the board, not fixed sprints).

## Constraints that shape planning

- **OSS-first, free, self-hosted** — no paid tools or licenses enter the stack (see
  [`docs/LICENSING.md`](../LICENSING.md)). This bounds every "what tool?" decision toward free/OSS.
- **Part-time capacity** — plan for realistic throughput, not full-time velocity. Flow (not fixed
  commitments) absorbs the variability.
- **No patient data** — internal ops only; synthetic fixtures in dev.
