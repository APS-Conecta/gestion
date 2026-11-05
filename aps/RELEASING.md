# RELEASING — test builds and release candidates

The runbook for the maintainer who builds a candidate of the suite. The machine's half is
[.github/workflows/release.yml](../.github/workflows/release.yml), the candidate pipeline; this file
owns the tags, the dispatch and the re-pin at an Upstream merge.

## 1. The tags

- **Candidate tag** — `vX.Y.Z-ci.N` for a test build, `vX.Y.Z-rc.N` for a release candidate. It
  is the git tag of a pre-release and the only tag the pipeline pushes our images under. Any tag
  with a suffix is a pre-release.
- **Version tag** — `vX.Y.Z`: the git tag of a final release, and the immutable tag of its images.
- **Channel tag** — `latest`: the moving image tag servers run on. The mastercontainer runs as
  `ghcr.io/aps-conecta/all-in-one:latest`, and the Nightly update follows it.

The version and channel tags move only when a release candidate is promoted after the release
gate (#303). GitHub's "Latest" follows the same rules, which `aps/release/latest.py` checks after
every publish: a pre-release never becomes "Latest", and a final version becomes "Latest" only
when it is the highest published final version, so an older final never replaces a newer one.

X.Y.Z comes from the changes since the previous final release, by the changelog's Semantic
Versioning: a feature is a minor bump, fixes alone a patch, a breaking change a major. The first
stable release is v1.0.0. A test build that is not meant for a version uses `v0.0.0-ci.N`.

## 2. Our images

- `ghcr.io/aps-conecta/all-in-one` — the mastercontainer: upstream's
  `Containers/mastercontainer/Dockerfile` over this tree, with our Nextcloud and Caddy images
  pinned by digest into its `php/containers.json` and `community-containers/caddy/caddy.json`.
- `ghcr.io/aps-conecta/aio-nextcloud` — [aps/images/nextcloud](images/nextcloud/Dockerfile):
  upstream's Nextcloud image without the one-click-instance user cap (#176).
- `ghcr.io/aps-conecta/aio-caddy` — [aps/images/caddy](images/caddy/Dockerfile): upstream's
  community Caddy rebuilt with the acme-dns DNS module.

Every other container is the official upstream image, pinned by digest in `php/containers.json`
to the set Upstream built from the Keep-list's base commit. The tree pins upstream's Nextcloud
the same way, so upstream's browser tests run it; only the mastercontainer's copy names ours.
`aps/release/pins.sh` checks the pins on every pull request and before every build.

## 3. A test build or a release candidate

Tag the commit, then dispatch the pipeline on the tag:

    git push origin <commit>:refs/tags/v0.0.0-ci.N
    gh workflow run release.yml --repo APS-Conecta/gestion --ref v0.0.0-ci.N

A release candidate's commit must be on `main`; a test build's may be on any branch. Use a
number no tag has used. The repository's `v*` tag ruleset lets only administrators create, move
or delete such a tag, and the pipeline never creates one.

The pipeline refuses a candidate tag that already has a release: a published candidate's images
never move. It proves the commit (the digest pins, `scripts/validate.sh`, Twig and the static
gate), builds our three images from it, labels each with the commit and checks the label before
it pushes the candidate tag, and publishes the pre-release with the three images by digest and
the Bootstrap as `apsconecta-install.sh`, filled with the tag and the mastercontainer's digest
(`aps/release/bootstrap.sh`). The Bootstrap pulls the mastercontainer by that digest and tags it
as the channel tag on the server; it never pulls `latest`. Then the pipeline checks "Latest": a
candidate leaves it where it was. Last, it runs the clean-machine acceptance harness
(`.github/workflows/acceptance.yml`) on the pre-release: the published Bootstrap on a fresh VM as
the manual prints it, then every check module in `aps/acceptance/checks/`. A candidate needs no
environment and reads no secret but the workflow's own token.

A test build of no version, `v0.0.0-ci.N`, runs against the services of
`aps/acceptance/test-build.json`, which the pipeline stamps into it at release time: its
Provisionador claims names on the name service's CI deployment, its Caddy gets Let's Encrypt
staging certificates, and its Bootstrap gives the suite the staging roots to trust, through AIO's
`NEXTCLOUD_TRUSTED_CACERTS_DIR`, whose file the pipeline also gives Euro-Office as
`NODE_EXTRA_CA_CERTS`. Its acceptance run installs the suite to «Listo» on a CI name, checks the
install steps and the baseline settings on the suite, each pinned app at its pin before and after a
store update, the name's certificate, every container's digest, the suite's own address and an
Office document created, edited, saved and reopened in Euro-Office from the Office entry, resets
the machine,
which frees the name first, and claims it again on a reinstall; the run frees every name it
claimed.

A candidate installs the own and fork apps its Suite manifest pins. An app moves in a pull request
that runs the pin tool, which writes the tag and the checksum of the App release into
`aps/provisionador/apps.json`:

    aps/release/pin.py <app id> [<tag>]

A version candidate, `vX.Y.Z-rc.N` or a versioned `vX.Y.Z-ci.N`, runs against production, as the
tree is committed, and an acceptance run never claims a production name. Its run covers the
Bootstrap, the mastercontainer's digest on the channel tag, a harmless rerun, the
mastercontainer's pinned digest and a reset that leaves nothing of the install; the checks that
need a name say they run on a `v0.0.0-ci.N` test build only.

## 4. An Upstream merge

The merge moves the Keep-list's base to the new Upstream tag (AGENTS.md). In the same pull
request, re-pin the official images and our Nextcloud image's base to that release's set:

    aps/release/pins.sh <upstream image tag>

The upstream image tag is the one whose images carry the release's commit as their
`org.opencontainers.image.revision`; v14.4.3's is `20261029_150718`. The script fails unless
every pin resolves to an image built from the Keep-list's base. When upstream's community Caddy
moves, `aps/images/caddy/Dockerfile`'s bases move with it, by digest.

## 5. Repository settings

Settings → Actions → General → Workflow permissions must use **Read repository contents and
packages permissions**, with **Allow GitHub Actions to create and approve pull requests**
disabled. Each job declares the writes it needs. Read back the effective defaults after a
change:

    gh api repos/APS-Conecta/gestion/actions/permissions/workflow

`scripts/ci-tool.sh` owns the raw gate binaries and their pinned checksums: the secret scan's and
`scripts/validate.sh`'s. A tool update changes its version and publisher-verified checksum together.
