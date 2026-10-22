<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0005 — `main` is the development trunk; a release is a tag

Accepted, 2026-08-08.

## Context

Every app this repository ships is pinned by version and sha256. Without a version of its own, a clinic
would install whatever `main` happened to be that day, and a bug report could not name the bytes that
produced it.

## Decision

**`main` is the trunk. A release is a tag plus a GitHub Release, and that tag is what a clinic
installs.** No `develop` branch, no `production` branch, no second repository. GitFlow's branch model
exists to support several shipped versions at once; with no back-versions to patch, branches would buy
nothing and cost merges. A branch is also a moving pointer that cannot answer "which bytes does that
instance have?"; a tag can.

`provisioning/seed.sh` prints its version in its header, so a run says which version of this
repository produced it.

**Our own apps are pinned at a milestone, not at every tag.** This repository pins the version it decided
to ship; it does not act as the app's CI.

## Consequences

- A clinic install has a name: the release it was installed from, which the seed's header logs.
