#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# Disposable GitHub runner only; all suite installation happens inside a Debian VM.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Run this rehearsal on a disposable GitHub runner' >&2; exit 2; }
[[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ci\.[0-9]+$ ]] || exit 2
suite_tag="$1"
work="${RUNNER_TEMP:?}/debian-acceptance"
mkdir -p "$work/evidence"
test -c /dev/kvm || { echo 'FAIL: this runner has no KVM device' >&2; exit 1; }
sudo apt-get update -qq
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils
# Match the existing cleanboot runner preparation; never execute on a shared host.
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
available="$(df -B1 --output=avail "$work" | tail -n 1 | tr -d ' ')"
[ "$available" -ge 45000000000 ] || { echo 'FAIL: fewer than 45 GB free for the VM' >&2; exit 1; }
image=debian-12-genericcloud-amd64-20261026-2643.qcow2
curl --fail --show-error --location --retry 3 \
  "https://cloud.debian.org/images/cloud/bookworm/20261026-2643/$image" -o "$work/$image"
printf '%s  %s\n' \
  0464b5d4ae3aa4f658468d88da83af7857b71548b30d46dcb6282770955a747fb95a983476db90d25afd0653af607224c7ebd05122ab71faa106fd712aaad652 \
  "$work/$image" | sha512sum --check -
qemu-img create -f qcow2 -F qcow2 -b "$work/$image" "$work/guest.qcow2" 60G
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
cat > "$work/user-data" <<CLOUD
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$work/key.pub")
package_update: true
packages: [sudo, curl, ca-certificates, git, python3, signify-openbsd, acl]
CLOUD
printf 'instance-id: aps-debian-%s\nlocal-hostname: aps-debian-rehearsal\n' "$GITHUB_RUN_ID" > "$work/meta-data"
cloud-localds "$work/seed.img" "$work/user-data" "$work/meta-data"
sudo qemu-system-x86_64 -accel kvm -cpu host -smp 4 -m 10240 \
  -drive "file=$work/guest.qcow2,if=virtio,format=qcow2" \
  -drive "file=$work/seed.img,if=virtio,format=raw" \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
  -display none -serial "file:$work/serial.log" -daemonize -pidfile "$work/qemu.pid"
cleanup() { sudo kill "$(cat "$work/qemu.pid")" 2>/dev/null || true; }
trap cleanup EXIT
ssh_options=(-i "$work/key" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work/known_hosts"
  -o BatchMode=yes -o ConnectTimeout=5 -p 2222)
deadline=$((SECONDS + 300))
until ssh "${ssh_options[@]}" root@127.0.0.1 true 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || { echo 'FAIL: Debian SSH did not start' >&2; exit 1; }
  sleep 3
done
ssh "${ssh_options[@]}" root@127.0.0.1 'cloud-init status --wait'
git archive HEAD > "$work/source.tar"
scp -i "$work/key" -o "UserKnownHostsFile=$work/known_hosts" -P 2222 "$work/source.tar" root@127.0.0.1:/root/source.tar
cat > "$work/rehearse.sh" <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
suite_tag="$1"
. /etc/os-release
test "$ID" = debian && test "$VERSION_ID" = 12 && test "$(uname -m)" = x86_64
printf 'Environment: %s; %s\n' "$PRETTY_NAME" "$(uname -r)"
modprobe fuse
ln -sf /usr/bin/signify-openbsd /usr/local/bin/signify
mkdir /root/source
cd /root/source
tar -xf /root/source.tar
tag=ci-debian-acceptance
mkdir -p /srv/rehearsal/releases/download/"$tag" /root/rehearsal-private
umask 077
signify -G -n -p /root/rehearsal-private/installer.pub -s /root/rehearsal-private/installer.sec -c 'Debian rehearsal only'
sed -i "s|^SIGNIFY_PUBKEY=\"[^\"]*\"|SIGNIFY_PUBKEY=\"$(sed -n 2p /root/rehearsal-private/installer.pub)\"|" install.sh
cp /root/rehearsal-private/installer.pub installer.pub
printf '%s\n' "$tag" > VERSION
git init -q
git config user.email rehearsal@invalid
git config user.name rehearsal
git add -A
git commit -qm 'test(instalador): assemble a private Debian rehearsal fixture' -m 'Assisted-by: Codex:GPT-6'
RELEASE_TAG="$tag" RELEASE_SHA="$(git rev-parse HEAD)" \
  MINISIGN_SECRET_KEY="$(cat /root/rehearsal-private/installer.sec)" MINISIGN_KEY_PASSWORD='' \
  bash scripts/package-release.sh --out /root/rehearsal-private/dist >/dev/null
cp /root/rehearsal-private/dist/apsconecta-"$tag".tar.gz \
   /root/rehearsal-private/dist/SHA256SUMS /root/rehearsal-private/dist/SHA256SUMS.minisig \
   /root/rehearsal-private/dist/apsconecta-"$tag"-install.sh /srv/rehearsal/releases/download/"$tag"/
export VMA_WORK=/root/rehearsal-private/acceptance
export VMA_INSTALL_ENV="APS_SUITE_TAG=$suite_tag MIN_DISK_GB=20"
bash scripts/vm-acceptance.sh --tag "$tag" --repo-url file:///srv/rehearsal --sin-datos --continuar
cd /opt/aps-conecta/instalador
ca_before="$(sha256sum /opt/aps-conecta/certificados/ca/aps-conecta-ca.crt)"
config_before="$(sha256sum sites/*/site.sh)"
bash host/aps-conecta provision --reponer >/root/rehearsal-private/rerun.log 2>&1
test "$ca_before" = "$(sha256sum /opt/aps-conecta/certificados/ca/aps-conecta-ca.crt)"
test "$config_before" = "$(sha256sum sites/*/site.sh)"
bash host/aps-conecta revalidate
printf 'PASS: Debian 12 IP installation and rerun preserve the CA and site configuration\n'
GUEST
scp -i "$work/key" -o "UserKnownHostsFile=$work/known_hosts" -P 2222 "$work/rehearse.sh" root@127.0.0.1:/root/rehearse.sh
ssh "${ssh_options[@]}" root@127.0.0.1 "bash /root/rehearse.sh '$suite_tag'" | tee "$work/evidence/verdicts.log"
