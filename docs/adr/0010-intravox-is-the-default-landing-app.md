<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0010 — IntraVox is the default landing app

Accepted, 2026-09-24.

## Context

The [welcome screen](https://aps-conecta.github.io/documentation/desarrollo/intravox.html) makes IntraVox the
intranet surface of APS Conecta. Nextcloud's `defaultapp` decides where a login lands, and flipping it is a
fleet-wide convergence.

## Decision

`defaultapp=intravox` replaces `"dashboard,files"` in `provisioning/phases/15-branding.sh`. Browser-open proof
precedes the flip.

Resolution falls to the hardcoded tail while the app is absent or disabled, so the value is safe under rollback:
disable the app and landing falls back to `dashboard,files`. The pre-flip state needs no counter-edit to be
recoverable. This ADR is the record that the flip is deliberate and where its safety comes from.

## Consequences

- Every staff login lands on the welcome screen.
