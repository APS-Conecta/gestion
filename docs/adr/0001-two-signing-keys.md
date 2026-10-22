<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0001 — Two signing keys: one for the suite, one for apps

Accepted, 2026-10-22.

## Context

A suite release is signed with the installer key: `installer.pub`, also embedded in `install.sh`. Own and
fork apps now publish their own app releases from their own repos. If those repos signed with the installer
key, any app repo able to publish would also be able to sign a fake installer.

## Decision

Two signify keys:

- `installer.pub` signs suite releases. Its secret key lives only in the suite repo's release secrets.
- `apps.pub` signs app releases. It ships inside the signed suite release. Its secret key reaches an app repo
  only through that repo's protected `release` environment, with the owner as required reviewer.

## Consequences

- A compromised app repo can sign an app, never a suite release.
- The installer verifies every app release against the `apps.pub` of the suite release it already verified.
- Rotating the app key is a new suite release.
