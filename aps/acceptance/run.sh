#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The clean-machine acceptance harness (Seam 1), for a disposable GitHub runner with KVM only: boot a fresh Debian 12
# VM on a network it shares with the runner, as a laptop shares the clinic's; install a published candidate in it by
# one of its ways in; then run every check in aps/acceptance/checks/ in name order. It tests the candidate's release,
# never this tree. The ways in:
#   bootstrap  the candidate's Bootstrap, exactly as the manual prints it
#   coolify    Coolify on the machine, set up as its admin does, then the candidate's tag as a resource of it,
#              deployed through Coolify's API (coolify.sh, ADR 0029)
#
# A check is an executable file aps/acceptance/checks/<NN>-<name>.<sh|py>; NN orders it. It runs on the runner, from
# the repo root, with:
#   TAG       the candidate: the release the machine installs; gh reads the release with the job's token
#   WAY       the way in: bootstrap or coolify
#   COMMAND   the way in, run on the machine: the Bootstrap, as the manual prints it for that release; or the resource's
#             deploy through Coolify's API, which prints the resource's logs
#   BOOTSTRAP the Bootstrap, as the manual prints it for that release, whichever the way in
#   CONSOLE   a file holding what the first run of COMMAND printed, link included; it stays out of the evidence, and
#             one-command.sh runs COMMAND again with the link's secret masked
#   MACHINE   runs one shell command line on the VM as the operator, whose sudo needs no password; like ssh, it passes
#             stdin through: "$MACHINE" "sudo docker ps"
#   ADDRESS   the VM's address on the shared network, where the runner's browser reaches it
#   EVIDENCE  an empty directory for the check's own files, such as screenshots
#   NAMES     a directory where a check that claims an APS name keeps its credential, one file per DEIS code
#             (claim.py does): the harness frees each name with its own credential at its end, even when a check failed
#   TEST_BUILD  true for a test build (v0.0.0-ci.N), which claims its names on the name service's CI deployment and
#             gets Let's Encrypt staging certificates, as the candidate's own services.json says; false for any other
#             candidate, whose names and certificates are production ones. What needs an APS name runs on a test build
#             only, and on any other candidate the check says so
# A check never prints a secret. python3 has Playwright with Chromium and Firefox (acceptance.yml installs them);
# browser.py is the one way to open them. Exit 0 passes. A failing check is named in the log, its EVIDENCE gets every
# container's log, with the link's secret and AIO's credentials blanked out, and the disk usage, and the workflow
# attaches it to the run.
# The VM gets the memory and disk floor the candidate's Bootstrap declares (MIN_MEMORY_GIB, MIN_DISK_GB), with room for
# Coolify itself on the Coolify way in, plus a fixed
# CPU count until #300 measures one, so a green run proves that floor.
# Usage: run.sh <tag> <bootstrap|coolify>
set -euo pipefail
[[ "$#" -eq 2 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ && "$2" =~ ^(bootstrap|coolify)$ ]] \
  || { echo "usage: $0 <tag> <bootstrap|coolify>" >&2; exit 2; }
[[ "${GITHUB_ACTIONS:-}" = true && -c /dev/kvm ]] || { echo "$0 runs on a disposable GitHub runner with KVM only" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
work="$RUNNER_TEMP/acceptance"
mkdir -p "$work/evidence" "$work/names"
bootstrap="https://github.com/$GITHUB_REPOSITORY/releases/download/$1/apsconecta-install.sh"
export TAG="$1" WAY="$2" ADDRESS=192.168.77.10 MACHINE="$work/machine" CONSOLE="$work/console.txt" NAMES="$work/names"
export BOOTSTRAP="curl -fsSL $bootstrap | sudo bash" COMMAND="curl -fsSL $bootstrap | sudo bash"

aio_configuration=/mnt/docker-aio-config/data/configuration.json # in the mastercontainer
aio_credentials='(.password // empty),
  (.secrets // {} | to_entries[] | select(.key | test("PASSWORD|SECRET")) | .value | strings)'
masked=()
mask_secrets() { # AIO's passphrase and, once AIO made them, its passwords and secrets, each masked in the log once found
  local config found
  config="$("$MACHINE" "sudo docker exec nextcloud-aio-mastercontainer cat $aio_configuration" 2> /dev/null || true)"
  while IFS= read -r found; do
    [[ -z "$found" || " ${masked[*]} " == *" $found "* ]] && continue
    masked+=("$found")
    printf '\n::add-mask::%s\n' "$found"
  done < <(jq -r "$aio_credentials" <<< "$config" 2> /dev/null || true)
}
blanked() { # <command>: what it printed on the machine, without the links' secrets, their QR codes and AIO's credentials
  local log found
  log="$("$MACHINE" "$1" 2>&1 || true)"
  for found in "${masked[@]}"; do log="${log//"$found"/[secret]}"; done
  printf '%s\n' "$log" | aps/acceptance/blank-link-secret.sh
}
collect() { # <dir>: every container's log, blanked, and the disk usage of the runner and the machine
  local name
  mkdir -p "$1"
  df -h > "$1/runner-disk.txt"
  "$MACHINE" 'df -h; sudo docker system df; sudo docker ps --all' > "$1/machine.txt" 2>&1 || true
  mask_secrets
  for name in $("$MACHINE" "sudo docker ps --all --format '{{.Names}}'" 2> /dev/null || true); do
    blanked "sudo docker logs --timestamps $name" > "$1/$name.log"
  done
}
free_names() { # every APS name a check claimed, freed with its own credential on stdin, as the reset frees one
  local credential held=0
  for credential in "$NAMES"/*.json; do
    [ -e "$credential" ] || continue
    if python3 -B aps/provisionador/provisionador.py release-name < "$credential"; then
      rm -f "$credential"
    else
      echo "::error title=CI name held::the name of DEIS code $(basename "$credential" .json) stays held; APS Conecta" \
        "frees it with gestion-aio's «APS name release» workflow on the ci deployment"
      held=1
    fi
  done
  return "$held"
}
on_exit() { # a failure outside the checks names its stage and collects the same evidence; every claimed name is freed
  local rc=$?
  [ "$rc" -eq 0 ] || [ -z "$stage" ] || { echo "::error title=Acceptance run failed::$stage"; collect "$work/evidence/run"; }
  free_names || rc=1
  exit "$rc"
}
stage="read the hardware floor from the candidate's Bootstrap"
trap on_exit EXIT
curl -fsSL --retry 5 -o "$work/apsconecta-install.sh" "$bootstrap"
floor() { sed -n "s/^$1=\([0-9][0-9]*\)\$/\1/p" "$work/apsconecta-install.sh"; }
memory="$(floor MIN_MEMORY_GIB)" disk="$(floor MIN_DISK_GB)"
[[ -n "$memory" && -n "$disk" ]] \
  || { echo "the Bootstrap of $TAG declares no MIN_MEMORY_GIB or MIN_DISK_GB, the floor the VM gets" >&2; exit 1; }
[ "$WAY" != coolify ] || memory=$((memory + 2)) disk=$((disk + 8))  # Coolify's own containers and images

stage="boot a fresh Debian 12 VM"
image=debian-12-genericcloud-amd64-20261026-2643.qcow2
curl -fsSL --retry 5 -o "$work/debian.qcow2" "https://cloud.debian.org/images/cloud/bookworm/20261026-2643/$image"
echo "0464b5d4ae3aa4f658468d88da83af7857b71548b30d46dcb6282770955a747fb95a983476db90d25afd0653af607224c7ebd05122ab71faa106fd712aaad652  $work/debian.qcow2" \
  | sha512sum --check --quiet
# The Bootstrap checks MIN_DISK_GB as free space on /var/lib: 4 GiB of headroom hold the Debian image and ext4's
# reserved blocks.
qemu-img create -q -f qcow2 -F qcow2 -b "$work/debian.qcow2" "$work/disk.qcow2" "$((disk + 4))G"

# The shared network: a tap device, DHCP and DNS from dnsmasq, NAT to the internet. Its DNS has no answer for Let's
# Encrypt's production service: a run gets certificates from the staging one only, which the test browser trusts.
sudo ip tuntap add dev aps0 mode tap
sudo ip address add 192.168.77.1/24 dev aps0
sudo ip link set aps0 up
sudo sysctl -qw net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 192.168.77.0/24 ! -o aps0 -j MASQUERADE
sudo iptables -I FORWARD -i aps0 -j ACCEPT
sudo iptables -I FORWARD -o aps0 -j ACCEPT
sudo dnsmasq --interface=aps0 --except-interface=lo --bind-interfaces --dhcp-range="$ADDRESS,$ADDRESS,12h" \
  --address=/acme-v02.api.letsencrypt.org/

ssh-keygen -q -t ed25519 -N '' -C acceptance -f "$work/key"
printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat "$work/key.pub")" > "$work/user-data"
printf 'instance-id: gestion-acceptance\nlocal-hostname: gestion\n' > "$work/meta-data"
cloud-localds "$work/seed.img" "$work/user-data" "$work/meta-data"
: > "$work/evidence/serial.log" # the runner's own file, so the evidence upload can read it
sudo qemu-system-x86_64 -accel kvm -cpu host -smp 2 -m "${memory}G" \
  -drive "file=$work/disk.qcow2,if=virtio,format=qcow2" -drive "file=$work/seed.img,if=virtio,format=raw" \
  -netdev tap,id=lan,ifname=aps0,script=no,downscript=no -device virtio-net-pci,netdev=lan \
  -display none -serial "file:$work/evidence/serial.log" -daemonize

cat > "$work/ssh_config" << SSH
Host machine
  HostName $ADDRESS
  User debian
  IdentityFile $work/key
  UserKnownHostsFile $work/known_hosts
  StrictHostKeyChecking accept-new
  BatchMode yes
  ConnectTimeout 10
  ServerAliveInterval 30
  LogLevel ERROR
SSH
printf '#!/bin/sh\nexec ssh -F "%s" machine "$@"\n' "$work/ssh_config" > "$MACHINE"
chmod +x "$MACHINE"
for _ in $(seq 60); do "$MACHINE" true 2> /dev/null && break; sleep 5; done
"$MACHINE" 'sudo cloud-init status --wait' > /dev/null
"$MACHINE" bash -s << 'OS'
. /etc/os-release
echo "$PRETTY_NAME, $(uname -m), $(nproc) CPUs, $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) kB of memory"
[ "$ID $VERSION_ID" = "debian 12" ]
OS

stage="Coolify, set up as its admin does"
if [ "$WAY" = coolify ]; then
  # The candidate's mastercontainer by the digest its release names, and what a test build's Coolify needs (coolify.sh).
  mastercontainer="$(gh release view "$TAG" --json body --jq .body \
    | { grep -oE 'ghcr\.io/aps-conecta/all-in-one@sha256:[0-9a-f]{64}' || true; } | sort -u)"
  [[ "$mastercontainer" =~ ^[^[:space:]]+$ ]] \
    || { echo "the release $TAG names no one mastercontainer by digest" >&2; exit 1; }
  mkdir -p "$work/coolify"
  cp aps/acceptance/test-build.json aps/acceptance/acme-dns-storage.py "$work/coolify/"
  cp aps/acceptance/letsencrypt-staging-roots.pem "$work/coolify/ca.crt"
  "$MACHINE" 'sudo tee /usr/local/sbin/aps-coolify > /dev/null && sudo chmod 755 /usr/local/sbin/aps-coolify' \
    < aps/acceptance/coolify.sh
  tar -C "$work/coolify" -cf - . \
    | "$MACHINE" 'sudo install -d -m 700 /root/.aps-files && sudo tar -C /root/.aps-files -xf -'
  "$MACHINE" "sudo aps-coolify setup $GITHUB_REPOSITORY $TAG $ADDRESS /root/.aps-files $mastercontainer"
  export COMMAND="sudo aps-coolify deploy $mastercontainer"
fi

stage="the way in: $WAY"
echo "$COMMAND"
aps/acceptance/one-command.sh "$CONSOLE"

stage="read whether the candidate is a test build"
# How a run tells a test build from any other candidate: the name service its build's own services.json names, which
# release.yml stamps from aps/acceptance/test-build.json into a test build's mastercontainer. On the Coolify way in,
# coolify.sh's setup applies the same rule to the candidate's image first, since its proxy configuration needs it before
# the deploy.
services=/var/www/docker-aio/aps/provisionador/services.json
claims="$("$MACHINE" "sudo docker exec nextcloud-aio-mastercontainer cat $services" | jq -r .name_service)"
TEST_BUILD=false
[ "$claims" != "$(jq -r .name_service aps/acceptance/test-build.json)" ] || TEST_BUILD=true
export TEST_BUILD
echo "test build: $TEST_BUILD; $TAG claims its names from $claims"

stage=""
failed=()
for check in aps/acceptance/checks/*; do
  name="$(basename "${check%.*}")"
  export EVIDENCE="$work/evidence/$name"
  mkdir -p "$EVIDENCE"
  echo "::group::$name"
  if timeout 25m "$check" < /dev/null; then # 40-install waits up to 20 minutes for «Listo»
    mask_secrets
    echo "::endgroup::"
    echo "passed: $name"
  else
    echo "::endgroup::"
    echo "::error title=Acceptance check failed::$name"
    collect "$EVIDENCE"
    failed+=("$name")
  fi
done
[ "${#failed[@]}" -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
echo "acceptance: every check passed"
