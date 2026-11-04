<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0026 — The tree is Upstream plus the Keep-list

Accepted, 2026-11-04. Part of #278; implemented by #280.

## Context

Every byte where this repository differs from Upstream (nextcloud/all-in-one) has to be carried
through each Upstream merge, and every difference inside an upstream container is a place where
the installer, the images and the apps can drift apart. A difference nobody declared is found at
the next merge, or in a clinic.

## Decision

**Every path outside the Keep-list is Upstream's.** `aps/keep-list.txt` names the Upstream commit
and its tag in its header (`# base: <sha> upstream nextcloud/all-in-one <tag>`), then lists every
path where this repository differs, one `<path> <reason>` line each; a path ending in `/` covers
everything under it. The differences are our layer (the Keep-list, docs, runbooks, theme, our
workflows and scripts, and our three images), the old host layer until #301, the official images'
digest pins, and the upstream automation this repository switches off. Upstream's containers stay
whole: our Nextcloud image is upstream's with the one-click-instance user-cap removal (#176) on
top, built from `aps/images/nextcloud`.

**Upstream's parts stay whole.** Upstream's container and network names, its update machinery
and notifications, and the parts the suite does not use — the other office suites, Whiteboard,
docker-socket-proxy, the community containers, the Helm chart, manual-install, the free-domain
flow, the major-upgrade script and ClamAV's milter — are carried as upstream ships them. The
parts the suite does not use are switched off through AIO's own switches, never by deleting them.

**Upstream automation is switched off in the tree.** A workflow that would publish, open pull
requests, need upstream's secrets or fail our pull requests on upstream's release policy is
deleted, with a Keep-list entry naming why; so is Dependabot's configuration. Repository settings
and the Actions API are not used for it. A workflow already guarded to upstream's repository
stays as it is. Upstream's own CI keeps running on upstream's files. Where it would lint our
layer, our gate lints it at our strength: shellcheck skips our paths and `scripts/test.sh` lints
them, and the static gate's `zizmor over our workflows` step runs without upstream's
`zizmor.yml` and with the online audits.

**The Keep-list check runs on every pull request.** `scripts/keep-list.py` asks Upstream that the
named tag points at the named commit, then compares the tree with it. It fails on an undeclared
difference — a path present upstream but absent here is one — on an entry that no longer
differs, and on an entry without a reason. Its self-test, `scripts/keep-list-test.py`, plants an
undeclared difference and a stale entry in throwaway repositories and must see the check red on
each.

**An Upstream release arrives as a merge.** It is merged into `main` with a merge commit, never a
squash, so `main` records Upstream as a parent and the next merge has a base. The merge takes
Upstream's side for every path outside the Keep-list and moves the Keep-list's base to the new
tag.

## Consequences

- An Upstream merge is mechanical: the Keep-list says which paths are ours, and the check names
  every path the merge left undeclared or stale.
- Every Keep-list entry is carried at every Upstream merge, so an entry stays only while its
  reason holds.
- AIO's page is Upstream's English page until #288 puts the Spanish page on top of it.
- The old install does not work on this tree, and nothing is released before the release gate
  (#303).
