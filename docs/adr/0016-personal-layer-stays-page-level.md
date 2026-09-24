# ADR-0016 — personal layer stays page-level; NC Dashboard is not the landing complement

- **Status:** accepted (2026-09-24, with this plan's approval).
- **Affects:** `provisioning/phases/41-intravox.sh` (team pages + team ACL), the welcome
  payload's per-team pages, the Dashboard app's posture (enabled, unprovisioned).

## Context

The welcome screen's personal layer had two candidate shapes: per-user widget surfaces through
Nextcloud's Dashboard app (cards assembled per account), or per-team pages with ACL-filtered
team news. The APS Conecta reality that decided it: **shared workstations**. Staff log in for
short sessions on machines that are not "theirs"; a per-user dashboard surface is personalization
nobody has a session long enough to curate, and its maintenance cost lands on the same editors
who carry the content.

Design decision D8: personal value = team pages + ACL-filtered team news. Each `SITE_TEAMS`
entry gets a generated page (one template, rendered per team at seed time) whose news widget
reads the team's own folder — pages Editors create there are team news by construction, because
the page ACL already restricts the folder to the team and jefaturas. Dashboard stays an ordinary
enabled app, unprovisioned.

## Decision

The personal layer is **page-level only**: one `equipo.tpl`, instantiated per `SITE_TEAMS` entry
by phase 41, ACL rule pair per team (baseline-deny for `IntraVox Users`, target-allow for the
team's own gid). No NC Dashboard provisioning, no per-user widget surface, no welcome-screen
reference to Dashboard. Team changes flow through the documented import-once recovery
(delete `es/` + reseed — staff edits under `es/` are data; export first), recorded in
`docs/WELCOME-SCREEN.md`.

**Revisit trigger:** a demonstrated need for per-user glanceables that shared-workstation
reality (short sessions) doesn't already negate. Own-calendar and birthday surfaces stay on the
ROADMAP (#2/#3) and are not smuggled in through this layer.
