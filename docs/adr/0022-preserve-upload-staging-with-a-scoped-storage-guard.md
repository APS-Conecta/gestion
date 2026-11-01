<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# 0022 — Preserve upload staging with a scoped storage guard

Nextcloud 34 tests a nonexistent staging filename with a directory-only creatability
check, so existing-file uploads bypass staging. Our staff DAV test confirms that a
rejected infected overwrite removes the previous clean file. This matches
[upstream issue 62853](https://github.com/nextcloud/server/issues/62853).

The own app `files_upload_guard` preserves staging during PUT and MOVE requests. It
checks CREATE on the parent of Nextcloud 34's generated
`<32-hex-hash>.ocTransferId<digits>.part` path and refuses an occupied or non-creatable staging location. Other permission
probes delegate unchanged; core still enforces target UPDATE permissions. A share
that permits updating but provides no writable staging location fails closed.

Temporary chunk PUTs under `/dav/uploads/` retain core handling: Nextcloud probes
them through its files view but writes them through a separate uploads view. The
final MOVE still registers the guard and protects the assembled destination.

This explicitly narrows AD-9 in ADR-0002 for this app to the standard private
`OC\Files\Storage\Wrapper\Wrapper` base and that staging-name convention. Registration
uses public events and `IStorageFactory`. A public-only decorator cannot preserve
the private storage type and wrapper traversal; copying its many methods would add
an unsafe compatibility layer. Core and store apps remain unmodified. ADR-0017 and
ADR-0018 still apply: phase 12 installs the app from its signed own release, using
the existing app key and lock file. No app is embedded in an image.

The app declares Nextcloud 34 compatibility only. Release checks must prove new and
successful overwrite uploads, rejected-overwrite preservation, chunk assembly,
parent CREATE and target UPDATE enforcement, and the normal installation/update
lifecycle. Remove the exception and app once an official supported release passes
those same checks without the guard.

## Amendment — 2026-11-01

The app also initializes missing mount parents through the public DAV plugin event and
Folder interface, after authentication and before target resolution. First uploads into
sector and unit folders retain native permissions and official DAV integrity. The staging
wrapper retires after its original checks pass without it; the mount listener retires when
first-request acceptance passes without it. Remove the app after both fixes retire.
