<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0025 — Use official application packages

Accepted, 2026-10-31. Supersedes ADR-0020 and the Office and Custom Menu fork channels.

Use compatible official packages when they satisfy the suite's required behavior. Euro-Office
uses the official DocumentServer and Nextcloud connector. Talk and Custom Menu also use their
official store packages, retaining upstream signatures and identity. APS owns installation,
configuration and functional checks. Phase 12 configures Talk immediately after installation.

The store installs the newest compatible package once; subsequent provisioning preserves it
(ADR-0018). Native checks require a signature file and a successful integrity check. Existing
lock and downgrade protections remain in force. A fresh disposable installation validates the
Office source transition because APS 11.0.7 exceeds official connector 11.0.6.

The search provider retains the temporary upstream-fix bridge governed by ADR-0023 until a
fixed compatible store package passes the same exact-file test. IntraVox retains its configurable
welcome mount and content-preserving import: official 3.1.2 lacks those required contracts.
APS clinical applications and the upload storage guard retain their existing ownership.
