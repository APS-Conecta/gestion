# RELEASING — cutting a signed suite release

The runbook for the maintainer who cuts a release. One tag on instalador is the whole ritual —
the 20-image channel, the composite package, the manifest's release identity (gestion's tag
ritual retired, D4). This file owns the parts only a person can do: the keypair, the secrets,
the release commit, the frozen window, and what to do when a key must change. The machine's
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
you store the farm's other keys, or delete it — rotation (§7) does not need the old secret key.

## 2. The secrets (once)

On instalador's repository Settings → Secrets and variables → Actions:

- `MINISIGN_SECRET_KEY` — the CONTENTS of `installer.sec` (both lines, untrusted comment
  included). The release job writes them to a 0600 trap-removed file; the key never reaches
  argv, a URL, or a log line (the P45 rule).
- `MINISIGN_KEY_PASSWORD` — the passphrase, or empty for a `-n` key.

A wrong pair reds the package job loudly ("signing failed — the passphrase
(MINISIGN_KEY_PASSWORD) or the key (MINISIGN_SECRET_KEY) is wrong"); nothing is released
half-signed.

## 3. The release commit

Three files, one commit, all saying the same tag (the CLI's self-test pins it; the release job
asserts it):

1. `VERSION` — the tag, one line.
2. `install.sh`'s `BUNDLE_TAG` — the same tag.
3. `aps/CHANGELOG.md` — the dated `## [X.Y.Z]` entry.

## 4. The frozen window

gestion's `main` is release-frozen between the last content merge and the tag push: the image
bake and the composite package both read gestion at the tag's moment (the sparse clone at the
release-frozen ref). Nothing may land on gestion's main inside that window — a hotfix waits,
or the tag waits.

## 5. The tag push

    git tag vX.Y.Z && git push origin vX.Y.Z

release.yml runs the whole chain: gates (upstream's own validators + twig-lint + brand gate +
acquisition gate, inline against the tag tree) → the 20-image lockstep publish FROM THE TAG → package-release (composite
assembly, SHA256SUMS, the signature, the verify-PROOF against the committed `installer.pub`,
the constants-filled install asset) → the Release with five assets. Watch it; a red anywhere
names its gate.

**The retag source (the self-referential lockstep)**. The 17 registry-side images are copied,
not built: `retag-source: ours` — the chain's default on every tag push — copies each from
**our previous suite tag** (the newest digest-complete set; git tags are the suite-tag list).
A wiped registry bootstraps once through `aps/BASE.lock`, which records `ours:v0.4.0` — our
own last digest-complete set, never a vendor image (the vendor arm retired with the hard
fork). The publish record's `retag_source` names what the walk actually copied from
(`ours:vX.Y.Z`), so a Release's lineage is auditable from its manifest asset alone.

**The vendor bump is retired** (the hard fork, D-3.5). Picking up a fresh upstream release was
never a default and is now not a path either: the 17 retagged siblings always copy from our own
previous set. An upstream release arrives the way every upstream change arrives now — a
deliberate merge into main, then an ordinary release; the 3 real builds pick it up from the
tree, and the retags keep the lockstep.

A repair that only needs the image set re-copied (a mixed or partial set, no Release involved)
dispatches Images directly with `retag-source: ours:vX.Y.Z` and `force` — the pinned previous
set, re-copied faithfully.

**Rehearse first**: a `v0.0.0-ci.N` tag (VERSION and BUNDLE_TAG set to match on a rehearsal
branch) runs the identical chain end-to-end and is deletable. The repair arm
(workflow_dispatch with `suite-tag`, plus `force-images` only for a chain that died mid-publish)
exists for a chain that failed BEFORE `gh release create` — a published Release's assets never
move (D12).

## 6. Auditing a release offline

An auditor (or an operator who wants to see it themselves) needs only the Release page and
`signify-openbsd`:

    curl -fsSLO https://github.com/APS-Conecta/instalador/releases/download/vX.Y.Z/{apsconecta-vX.Y.Z.tar.gz,SHA256SUMS,SHA256SUMS.minisig}
    curl -fsSLO https://github.com/APS-Conecta/instalador/raw/main/installer.pub
    signify -V -p installer.pub -m SHA256SUMS -x SHA256SUMS.minisig && sha256sum -c SHA256SUMS

The signature covers `SHA256SUMS`, which names `apsconecta-vX.Y.Z.tar.gz`: a signature that
verifies is a signature for that tag's package — the tag binds through the signed bytes. The
public key is committed, printed by the wizard, and embedded in the install asset; matching the
copy you audit against the one you already trust is the whole ceremony.

## 7. Rotation and compromise

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
