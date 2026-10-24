<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0012 — Personal layer stays page-level; NC Dashboard is not the landing complement

Accepted, 2026-09-24.

## Context

The welcome screen's personal layer had two candidate shapes: per-user widget surfaces through Nextcloud's
Dashboard app (cards assembled per account), or per-team pages with ACL-filtered team news. The APS Conecta
reality decides it: **shared workstations**. Staff log in for short sessions on machines that are not theirs.
A per-user dashboard surface is personalization nobody has a session long enough to curate, and its
maintenance cost lands on the same editors who carry the content.

## Decision

The personal layer is **page-level only**: one `equipo.tpl`, instantiated per `SITE_TEAMS` entry by phase 41,
with an ACL rule pair per team (baseline-deny for `IntraVox Users`, target-allow for the team's own gid). No NC
Dashboard provisioning, no per-user widget surface, no welcome-screen reference to Dashboard.

**Revisit trigger:** a demonstrated need for per-user glanceables that shared-workstation reality (short
sessions) does not already negate. Own-calendar and birthday surfaces are not smuggled in through this layer.

## Consequences

- Personal value is team pages plus ACL-filtered team news. A team page's news widget reads the team's own
  folder, so pages Editors create there are team news by construction: the page ACL already restricts the
  folder to the team and jefaturas.
- Dashboard stays an ordinary enabled app, unprovisioned.
