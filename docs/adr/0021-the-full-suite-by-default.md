<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0021 — The full suite by default

Accepted, 2026-10-30. Part of #175; implemented in stages beginning with #183.

Every establishment receives Office, Talk, full-text search, previews, antivirus and AppAPI
through HaRP. Supporting a fixed service set gives installation, readiness and acceptance one
contract; resource limits must produce an explicit suitability verdict rather than silently
remove a capability. Farmacia, Estadística and Tótem remain optional apps. Talk recording stays
off until the measured hardware policy in #189/#190 permits it.

This amends [ADR-0020](0020-spreed-is-a-fork-app-with-signed-releases.md): there is no Talk switch
in the wizard, saved options, resolver, provisioning or acceptance. Spreed always follows its
signed fork release and lock. Its wiring must converge during provisioning, replacing the
next-boot policy. The latter implementation belongs to #187: #183 establishes the service set,
#184–#186 supply antivirus, full-text and AppAPI integration, and #187 supplies provisioning-time
Talk wiring. Container presence alone is not evidence that those integrations work.

Old saved service selections cannot disable an included service or enable recording. The saved
options record continues to represent optional app choices. Service settings are fixed at the
configuration boundary, and readiness follows the service inventory rather than a separate
six-container assumption.
