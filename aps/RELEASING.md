# RELEASING — cutting a signed suite release

The runbook for the maintainer who cuts a release. One tag on instalador is the whole ritual —
the 20-image channel, the composite package, the manifest's release identity (D4). This file owns the parts only a person can do: the keypair, the secrets,
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

## 2. The secrets (once)

On instalador's repository Settings → Secrets and variables → Actions:

- `MINISIGN_SECRET_KEY` — the CONTENTS of `installer.sec` (both lines, untrusted comment
  included). The release job writes them to a 0600 trap-removed file; the key never reaches
  argv, a URL, or a log line (the P45 rule).
- `MINISIGN_KEY_PASSWORD` — the passphrase, or empty for a `-n` key.
- `SPREED_REFRESH_TOKEN` — a fine-grained PAT with **Contents: read and write on
  `APS-Conecta/spreed` alone**, nothing else. The release chain's spreed job uses it to
  dispatch the Talk fork's refresh (ADR-0020); its scope is that one repo, so the worst a
  leak can do is publish a Talk release that still has to pass the job's own verification
  against this repo's `apps.pub` — it can never touch a suite release. A missing token reds
  the spreed job naming this section.

A wrong pair reds the package job loudly ("signing failed — the passphrase
(MINISIGN_KEY_PASSWORD) or the key (MINISIGN_SECRET_KEY) is wrong"); nothing is released
half-signed.

The Talk fork's own setup (once, already done — `APS-Conecta/spreed`): a `release`
environment carrying `APP_SIGNING_KEY`/`APP_SIGNING_KEY_PASSWORD` (the app key `apps.pub`
trusts — the same pair every app repo carries), Actions enabled, and upstream's own push-CI
workflows disabled (the fork never changes code, so upstream's linters have nothing to say).
The refresh refreshes upstream's newest stable spreed per suite release; the first release
was dispatched by hand (`gh workflow run refresh.yml --repo APS-Conecta/spreed -f
nextcloud-major=34`), and every later one rides the release chain.

## 3. The release commit

X.Y.Z is chosen from the changes, not from the last number plus one: read the commits since
the previous tag — `git log --oneline $(git describe --tags --abbrev=0)..HEAD` — and apply the
changelog's Semantic Versioning: a feature anywhere in the range is a minor bump, fixes alone
a patch, a breaking change a major. (The 0.5.0 range was first proposed as v0.4.1, five
features deep; the log is the count.)

Four places, one commit, all saying the same tag (the CLI's self-test pins it; the release job
asserts it):

1. `VERSION` — the tag, one line.
2. `install.sh`'s `BUNDLE_TAG` — the same tag.
3. `host/aps-conecta`'s `BUNDLE_TAG` — the same tag (the file on its own installs it).
4. `aps/CHANGELOG.md` — the dated `## [X.Y.Z]` entry.

## 4. The tag push

    git tag vX.Y.Z && git push origin vX.Y.Z

release.yml runs the whole chain: gates (upstream's own validators + twig-lint + brand gate +
acquisition gate, inline against the tag tree) → the 20-image lockstep publish FROM THE TAG → package-release (composite
assembly, SHA256SUMS, the signature, the verify-PROOF against the committed `installer.pub`,
the constants-filled install asset) → the Release with five assets. Watch it; a red anywhere
names its gate.

**The testbed pin follows**. Once the Release is green, one commit moves the pin in
`scripts/aio-testbed.sh` to `vX.Y.Z` — the suite tag every PR-event and weekly Clean boot
installs. It cannot ride the release commit: the tag's images do not exist until the push
publishes them.

**The retag source (the self-referential lockstep)**. The 16 registry-side images are copied,
not built: `retag-source: ours` — the chain's default on every tag push — copies each from
**our previous suite tag** (the newest digest-complete set; git tags are the suite-tag list).
A wiped registry bootstraps once through `aps/BASE.lock`, which records `ours:v0.4.0` — our
own last digest-complete set, never a vendor image (the vendor arm retired with the hard
fork). The publish record's `retag_source` names what the walk actually copied from
(`ours:vX.Y.Z`), so a Release's lineage is auditable from its manifest asset alone.

**The vendor bump is retired** (the hard fork, D-3.5). Picking up a fresh upstream release was
never a default and is now not a path either: the 16 retagged siblings always copy from our own
previous set. An upstream release arrives the way every upstream change arrives now — a
deliberate merge into main, then an ordinary release; the 4 real builds pick it up from the
tree, and the retags keep the lockstep.

A repair that only needs the image set re-copied (a mixed or partial set, no Release involved)
dispatches Images directly with `retag-source: ours:vX.Y.Z` and `force` — the pinned previous
set, re-copied faithfully.

**Rehearse first, by dispatch**. Two `gh` commands, no git tag, no Release:

    gh workflow run images.yml    --ref <branch> -f suite-tag=v0.0.0-ci.N -f build-ref=<branch> -f force=true
    gh workflow run cleanboot.yml --ref <branch> -f suite-tag=v0.0.0-ci.N

`force` because a rehearsal suite tag is throwaway and its set is usually already on the
registry — every `v0.0.0-ci.N` ever dispatched stays there (immutability, D12; ci.1–ci.8
exist), and the retag pre-check refuses a fully-present set without `force`, whose own
contract names refreshing a throwaway CI tag. That refusal is also why a tag push cannot
substitute: the tag-push chain runs Images without `force`, so re-pushing an existing
`v0.0.0-ci.N` dies at the pre-check — and pushing a never-used one mints a Release that must
then be deleted. A never-published `v0.0.0-ci.N` (VERSION and BUNDLE_TAG set to match on the
branch) is still the way to rehearse the chain itself end-to-end, Release included, deletable;
the dispatch pair is how you iterate on images and install code. A rehearsal takes an `N` above
the one the testbed pins: `force` re-publishes a set, and the pinned set never moves under the
PR runs.

**When a fresh Images dispatch is needed**: only when the image inputs changed — the tree the
four real builds read at `build-ref` (php/, app/, Containers/, themes/ — the theme is the one
suite thing an image carries, ADR-0018); the 16 retagged siblings only ever copy the previous set. When only the install
path moved (the host bundle, provisioning/, scripts/ on the branch), a Clean boot re-dispatch
alone is enough: it checks out the branch and installs the suite tag's already-published
images.

release.yml's repair arm (workflow_dispatch with `suite-tag`, plus `force-images` only for a
chain that died mid-publish) exists for a chain that failed BEFORE `gh release create` — a
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
three optional apps chosen, and the ticket's six criteria, each a ✓/✗ line with its evidence
path (`/tmp/vm-acceptance.*`): the verified bootstrap, «aps-conecta estado», the suite's answer
through the installer's CA (and its refusal without it), a planilla user over OCS, every
default app installed from its channel (own/fork from their releases at the locked tag, store
apps enabled) with the functional opens (notify_push, the office connector), each chosen optional
installed and recorded, buscador's PDF (or the manifest row it still lacks — #149), and
«actualizar --revisar» writing nothing. `--solo-chequeos` re-runs the checks on an installed VM;
`--sin-datos` spares a small VM the national masters; `--sin-respaldo` drives the wizard without
the daily backup — criterion 6 will red, because actualizar refuses without a configured backup,
by design.

A red is named, never waved through: the script exits non-zero with the failing criterion and
the command that diagnoses it. The self-test arm (`--self-test`, wired into `scripts/test.sh`)
pins the classification hermetically — the VM run is for the release, not for CI.
