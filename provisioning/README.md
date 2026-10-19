# provisioning/ — the suite's data

This directory holds what an install **reads**, not what applies it. The provisioning pipeline itself
(the runner, the guard helpers, the numbered phases, the welcome-tree library) is
[instalador](https://github.com/APS-Conecta/instalador)'s: it absorbed the install half of this
repository, and its copy is the only live one (see its
[`INSTALLER.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/INSTALLER.md) and
[`MIGRATION.md`](https://github.com/APS-Conecta/instalador/blob/main/aps/MIGRATION.md)). Nothing here
runs, and nothing here mutates an instance.

```
provisioning/
  apps/              # per app: the vendored tarball, its VENDOR file, and *.patch edits (#98)
    <appid>/         # one directory per app of the suite, ours and third party
  data/
    packages.json    # the data-package manifest: masters (pinned origin + sha256) and recipes
    comunas-deis.csv # the comuna coding authority (CUT -> glosa) the recipes validate against
    aio-siblings.txt # the AIO sibling container refs (listed in docs/CONTRACTS.md)
```

## Who reads it

- **instalador's package** copies `provisioning/apps`, `provisioning/data`, `sites` and
  `themes/apsconecta` from this repository at the release tag. The image bake reads `apps/` and the
  theme the same way, and re-runs the `VENDOR` sha256 check before a single byte enters an image.
- **This repository's gate** (`make test`) checks the data in place: every app has exactly one
  tarball, named `<id>-<version>.tar.gz`, whose bytes match the `sha256=` in its `VENDOR`; the
  licence table in `docs/LICENSING.md` agrees with each tarball's `info.xml`; the manifest and the
  comuna reference describe each other. `scripts/release-manifest.sh --validate` checks the form of
  every pin a release carries.

## An app's directory

`VENDOR` has three lines that move together on a bump — `version=`, `sha256=`, `url=` — and the
comments above them say where the tarball came from. A `*.patch` beside the tarball is applied by the
installer's apps phase after it unpacks; why the suite patches apps at all is
[ADR-0002](../docs/adr/0002-app-patches.md). To take a new version: replace the tarball, update the
three lines, and open a PR; `scripts/app-versions.sh` (`make apps-check`) reports which vendored app
has a newer release and changes nothing.

No real data, ever: everything here is public reference data or code (NFR-2).
