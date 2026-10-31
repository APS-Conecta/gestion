# RELEASING — cutting a signed suite release

The runbook for the maintainer who cuts a release. One tag on instalador is the whole ritual —
the complete suite image set, the composite package, the manifest's release identity (D4). This file owns the parts only a person can do: the keypair, the secrets,
the release commit, and what to do when a key must change. The machine's
half — gates → images → package → sign → prove → Release — is
[.github/workflows/release.yml](../.github/workflows/release.yml), and every guard it runs is
self-tested in [scripts/package-release.sh](../scripts/package-release.sh).

## 1. The keypair (once)

The signature is Ed25519 in signify/minisign format, made and proven by `signify-openbsd` — the
same apt package the clinic verifies with (Ubuntu universe, Debian main). Generate the pair on
a machine you trust:

    sudo apt-get install signify-openbsd
    sudo ln -sf /usr/bin/signify-openbsd /usr/local/bin/signify   # Ubuntu ships the binary under its full name
    signify -G -n -p installer.pub -s installer.sec -c "APS Conecta instalador release key"

`-n` makes a passphrase-less key — simplest, and the key's protection is where it lives, not
the passphrase. To carry one anyway, feed it on stdin (`printf 'la frase\n' | signify -G …`);
the sign step reads the passphrase the same way, and `MINISIGN_KEY_PASSWORD` carries it in CI.

Replace the placeholder **in one commit**: `installer.pub`'s two lines AND `install.sh`'s
`SIGNIFY_PUBKEY` constant (the repo carries a placeholder on purpose — a placeholder that signs
is a bug, not a state, and `package-release.sh` reds on the word until this commit lands). The
two readers are pinned equal by the gate (`scripts/test.sh`) and re-proven at every release.

Keep `installer.sec` OUT of the repository. After registering the secrets (§2), store it where
you store the farm's other keys, or delete it — rotation (§6) does not need the old secret key.

## 2. The Release environment and secrets (once)

On this repository's Settings → Environments → **Release**, restrict deployment refs to
**tags matching `v*`**. Use no required human reviewers or wait timer: successful automated
gates permit progression. Disable administrator bypass of environment protection. The
repository's active `v*` tag ruleset restricts creation, updates and deletion to the release
owner's administrator role; it admits owner-managed numeric `vX.Y.Z-ci.N` rehearsals.

Store these secrets in that environment:

- `MINISIGN_SECRET_KEY` — the CONTENTS of `installer.sec` (both lines, untrusted comment
  included). The release job writes them to a 0600 trap-removed file; the key never reaches
  argv, a URL, or a log line (the P45 rule).
- `MINISIGN_KEY_PASSWORD` — the passphrase, or empty for a `-n` key.
The signing pair reaches the package assembly step. The gates and image builds use their
job permissions. App repositories retain the separate app-signing identity.

Populate environment secrets through GitHub's UI or the CLI's masked interactive prompt:

    gh secret set MINISIGN_SECRET_KEY --repo APS-Conecta/gestion --env Release < installer.sec
    gh secret set MINISIGN_KEY_PASSWORD --repo APS-Conecta/gestion --env Release

Finish migration by removing the old repository-level copies of these names. Verify the
Release environment's secret names and complete a protected rehearsal; secret values never
belong in chat, argv, repository files or logs.

A wrong pair reds the package job loudly ("signing failed — the passphrase
(MINISIGN_KEY_PASSWORD) or the key (MINISIGN_SECRET_KEY) is wrong"); nothing is released
half-signed.

Talk installs its official signed package through the scoped store command (ADR-0025).

Repository Settings → Actions → General → Workflow permissions must use **Read repository
contents and packages permissions**, with **Allow GitHub Actions to create and approve pull
requests** disabled. Publishing jobs declare their required writes explicitly; Images keeps
its reusable-workflow package-write ceiling and narrows every non-publishing job to read.
Read back the effective repository defaults after changing them:

    gh api repos/APS-Conecta/gestion/actions/permissions/workflow

`scripts/ci-tool.sh` owns the raw gate binaries and their pinned checksums. The Dockerfile
workflow reuses `scripts/validate.sh --docker-lint`; it has no separate downloader or exit-status
policy. A tool update changes its version and publisher-verified checksum together.

## 3. The release commit

X.Y.Z is chosen from the changes, not from the last number plus one: read the commits since
the previous tag — `git log --oneline $(git describe --tags --abbrev=0)..HEAD` — and apply the
changelog's Semantic Versioning: a feature anywhere in the range is a minor bump, fixes alone
a patch, a breaking change a major. (The 0.5.0 range was first proposed as v0.4.1, five
features deep; the log is the count.)

Three places, one commit, all saying the same tag (the CLI's self-test pins it; the release job
asserts it):

1. `VERSION` — the tag, one line.
2. `install.sh`'s `BUNDLE_TAG` — the same tag.
3. `aps/CHANGELOG.md` — the dated `## [X.Y.Z]` entry.

## 4. The tag push

    git tag vX.Y.Z && git push origin vX.Y.Z

release.yml proves stable tags are contained in main, freezes the checked-out commit and runs
the full local gate (including existing browser checks), validators, Twig and both ownership
gates on that tree. Only numeric `vX.Y.Z-ci.N` rehearsals may be off main. Images and
packaging check out the proven SHA, never a second resolution of the tag.
The packager receives `RELEASE_SHA`, using it for archived bytes, date and provenance even
without a local tag. Before publication, the remote tag (including annotated tags) must still
resolve to that same commit. The complete image set passes its native checks, then package-release assembles the composite,
including SHA256SUMS, the signature, the verify-PROOF against the committed `installer.pub`,
the constants-filled install asset) → the Release with five assets. Watch it; a red anywhere
names its gate.

**The testbed pin follows**. Once the Release is green, one commit moves the pin in
`scripts/aio-testbed.sh` to `vX.Y.Z` — the suite tag every PR-event and weekly Clean boot
installs. It cannot ride the release commit: the tag's images do not exist until the push
publishes them.

**One source tree for every image.** Images resolves `build-ref` once, generates its build
matrix from `php/containers.json` and the mastercontainer, and checks out that commit in every
build. Every surviving `Containers/*/Dockerfile` must have a matrix entry. PostgreSQL is tested
before publication; Euro-Office keeps its cache exception. The manifest verifies each image's
source label (`https://github.com/APS-Conecta/gestion`) and revision against that commit.
There is no previous-image copy step or base lock. Upstream updates arrive through deliberate
merges into main, then ordinary builds.

Before any build can push, Images checks the repository and target Release through GitHub.
A published Release, including a prerelease, always refuses rebuilding, even with `force`.
An unreadable publication state also refuses. `force` permits repairing a complete image set
only while its Release is absent or still a draft.

**Rehearse first, by dispatch.** Two `gh` commands publish images and test them without
creating a git tag or Release:

    gh workflow run images.yml    --ref <branch> -f suite-tag=v0.0.0-ci.N -f build-ref=<commit-sha>
    gh workflow run cleanboot.yml --ref <branch> -f suite-tag=v0.0.0-ci.N

Choose an unused rehearsal number above the testbed's pin. Reusing a complete unpublished
rehearsal set requires `-f force=true`; use a new number when preserving prior evidence.
Git tags, GitHub Releases and Latest changes require the release owner's authorization.

**When a fresh Images dispatch is needed:** changes to any container directory or shared
build input (including PHP, the application and themes) need new images. When only the host
bundle, provisioning or install scripts change, Clean boot can install the already-published
suite images while checking out the new branch code. Independently released apps remain
outside the images (ADR-0018).

**Protected release rehearsal.** After the owner authorizes an exact rehearsal commit with
matching VERSION, BUNDLE_TAG and changelog, the owner creates its numeric CI tag. Tag push
runs the protected chain automatically. Its suite Release uses `--prerelease --latest=false`;
record the current `/releases/latest` tag before and after to prove Latest stayed unchanged.

For a repair, dispatch from the tag itself (`--ref vX.Y.Z`), not a branch: Release environment
eligibility follows the workflow ref. The repair arm uses `suite-tag`, plus `force-images`
only for a chain that died mid-publish, and exists for a chain that failed BEFORE `gh release create` — a
published Release's assets never move (D12).

## 5. Auditing a release offline

An auditor (or an operator who wants to see it themselves) needs only the Release page and
`signify-openbsd`:

    curl -fsSLO https://github.com/APS-Conecta/gestion/releases/download/vX.Y.Z/{apsconecta-vX.Y.Z.tar.gz,SHA256SUMS,SHA256SUMS.minisig}
    curl -fsSLO https://github.com/APS-Conecta/gestion/raw/main/installer.pub
    signify -V -p installer.pub -m SHA256SUMS -x SHA256SUMS.minisig && sha256sum -c SHA256SUMS

The signature covers `SHA256SUMS`, which names `apsconecta-vX.Y.Z.tar.gz`: a signature that
verifies is a signature for that tag's package — the tag binds through the signed bytes. The
public key is committed, printed by the wizard, and embedded in the install asset; matching the
copy you audit against the one you already trust is the whole ceremony.

## 6. Rotation and compromise

Rotate cheaply and without ceremony — the design makes rotation non-eventual:

1. Generate a new pair (§1) and replace `installer.pub` + `install.sh`'s constant in one commit.
2. Register the new secrets (§2). The next release signs with the new key; old Releases keep
   verifying with the old pubkey (deterministic Ed25519 — keep the retired `installer.pub`
   beside the audit, or fetch it from the tag that last carried it).
3. A clinic mid-flight is never stranded: the bootstrap it runs embeds the sha256 of the package
   it fetches, and `preflight` verifies the kept package against the key the INSTALLED tree
   carries (`$ROOT/installer.pub`) — a key change reaches a clinic at its next deliberate
   update (INSTALLER §10), never as a surprise red.

**Compromise of the key alone** (no repository access) cannot ship a package a clinic will
install: the one-liner's asset embeds the expected sha256, and that asset lives at a tag-pinned
URL inside the repository. A compromised key WITH repository access is repository compromise —
rotate (above) and cut the next release; already-published Releases stay verifiable and their
bytes never moved.

## 7. The acceptance run (#54)

A release is accepted on a scratch Ubuntu 24.04 VM, by domain and by IP, with no token — the
establishment's own command, on a machine nobody configured. The rehearsal (§4) proves the
chain; this proves the published artifact.

**The VM.** Any pristine Ubuntu 24.04 x86-64 machine with ≥ 20 GB free disk, ≥ 4 GB RAM and
ports 8080/443/3478 free. **By IP** (the installer's own certificate) any VM qualifies. **By
domain** the VM must be publicly reachable on 443 under a DNS name that resolves to it — the
domain posture's certificate is ACME's, as upstream (a cloud VM plus its own DNS name is the
simplest honest example; an RFC-2606 name or a reverse proxy in front reds the posture, not
the suite).

**The command.** One line, from the repo, on the VM:

    curl -fsSL https://github.com/APS-Conecta/gestion/raw/main/scripts/vm-acceptance.sh \
      | sudo bash -s -- [--tag vX.Y.Z] [--dominio su.dominio]

Without `--tag` the run resolves `latest` by redirect — no token, no API call. The script runs
the whole acceptance: the real one-liner from the release URL, the silent install with the
three optional apps chosen, and the ticket's five criteria, each a ✓/✗ line with its evidence
path (`/tmp/vm-acceptance.*`): the verified bootstrap, «aps-conecta estado», the suite's answer
through the installer's CA (and its refusal without it), a planilla user over OCS, every
default app installed from its channel (own/fork from their releases at the locked tag, store
apps enabled) with the functional opens (notify_push, the office connector), each chosen optional
installed and recorded, and «actualizar --revisar» writing nothing. `--solo-chequeos` re-runs the
checks on an installed VM; `--sin-datos` spares a small VM the national masters; `--sin-respaldo`
drives the wizard without the daily backup — criterion 5 will red, because actualizar refuses
without a configured backup, by design.

A red is named, never waved through: the script exits non-zero with the failing criterion and
the command that diagnoses it. The self-test arm (`--self-test`, wired into `scripts/test.sh`)
pins the classification hermetically — the VM run is for the release, not for CI.
