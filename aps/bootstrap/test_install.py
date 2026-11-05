# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The Bootstrap's tests: its command line on a server made of PATH shims and fixture files, so the machine that runs
them is neither read for a decision nor changed."""

import fcntl
import os
import pty
import re
import shutil
import subprocess
import sys
import tempfile
import termios
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "provisionador"))
from provisionador import LINK_LOG  # noqa: E402  the block our mastercontainer logs at every start (ADR-0027)

BOOTSTRAP = HERE / "install.sh"
FILL = HERE.parent / "release" / "bootstrap.sh"
TAG = "v9.9.9-ci.1"
PINNED = "ghcr.io/aps-conecta/all-in-one@sha256:" + "a" * 64
CHANNEL = "ghcr.io/aps-conecta/all-in-one:latest"
NAME = "nextcloud-aio-mastercontainer"
DROP_IN = "/etc/sysctl.d/90-apsconecta-gestion.conf"
BLOCK = LINK_LOG.format(url="https://10.0.0.5:8080/#c2VjcmV0IGRlbCBlbmxhY2U", qr="█▀▀▀█ ▄ █\n█▄▄▄█ ▀ █\n",
                        fingerprint=":".join(["AB"] * 32))
LOG = f"Trying to fix docker.sock permissions internally...\n{BLOCK}\nInitial startup of AIO complete!\n"
TOOLS = ("awk", "cat", "date", "grep", "sed", "sleep", "sort")  # the real commands the Bootstrap may run here
READS = ("uname", "id", "nproc", "df", "ss", "ip", "sysctl -n", "docker info", "docker inspect")  # they change nothing
UBUNTU = 'PRETTY_NAME="Ubuntu 24.04.3 LTS"\nNAME="Ubuntu"\nID=ubuntu\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n'
# Each shim logs its command line to $CALLS, then runs its body. The SHIM_* variables set the server's answers; the
# defaults are a server that meets every requirement.
SHIMS = {
    "uname": 'echo "${SHIM_ARCH:-x86_64}"',
    "id": 'echo "${SHIM_UID:-0}"',
    "nproc": 'echo "${SHIM_CPUS:-4}"',
    "df": 'printf "Avail\\n%s\\n" "${SHIM_FREE_BYTES:-100000000000}"',
    "ss": 'printf "%b" "${SHIM_LISTENING:-}"',
    "ip": 'echo "${SHIM_ROUTE-192.0.2.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0}"',
    "sysctl": '[ "$1" != -n ] || echo "${SHIM_MAP_COUNT:-65530}"',
    "tee": 'cat > "$SHIM_TEE"',
    "rm": ":",  # it only logs, so a removal shows up as a call
    "docker": """case "$1" in
  info) [ -n "${SHIM_DOCKER_ROOT-/var/lib/docker}" ] && echo "${SHIM_DOCKER_ROOT-/var/lib/docker}" ;;
  inspect) [ -n "${SHIM_IMAGE:-}" ] && echo "$SHIM_IMAGE ${SHIM_RUNNING:-true}" ;;
  exec) case "$*" in *" test -e "*) [ -n "${SHIM_LISTO:-}" ] ;; *" php "*) echo "${SHIM_DOMAIN:-}" ;; esac ;;
  logs) cat "$SHIM_LOGS" ;;
esac""",
}
REFUSED = "\nEste servidor no cumple los requisitos de APS Conecta Gestión. No se modificó nada.\n"


class Server(unittest.TestCase):
    """A server for the Bootstrap: the release asset, the shims and the files the checks read."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.asset = self.dir / "apsconecta-install.sh"
        with self.asset.open("w") as out:
            subprocess.run(["bash", str(FILL), TAG, PINNED], stdout=out, check=True)
        self.env = {"MEMINFO": self.file("meminfo", "MemTotal:       16384000 kB\n"),
                    "OS_RELEASE": self.file("os-release", UBUNTU), "FUSE_DEVICE": "/dev/null",
                    "SHIM_TEE": str(self.dir / "tee"), "SHIM_LOGS": self.file("logs", LOG)}

    def file(self, name, text):
        path = self.dir / name
        path.write_text(text)
        return str(path)

    def run_bootstrap(self, *args, script=None, without=(), typed=None, **env):
        """The Bootstrap as `curl … | sudo bash -s <args>` runs it, on this server with `env` and without the commands
        `without`, in a session of its own: without a terminal, or with the line `typed` waiting on a pty that is its
        terminal. Returns (exit code, stdout, stderr, the shims' calls)."""
        bin_dir = Path(tempfile.mkdtemp(dir=self.dir))
        for tool in TOOLS:
            (bin_dir / tool).symlink_to(shutil.which(tool))
        for name, body in SHIMS.items():
            if name not in without:
                (bin_dir / name).write_text(f'#!/bin/bash\nprintf "%s\\n" "{name} $*" >> "$CALLS"\n{body}\n')
                (bin_dir / name).chmod(0o755)
        calls = bin_dir / "calls"
        session = {"start_new_session": True}  # without a terminal, /dev/tty does not open
        if typed is not None:
            controller, terminal = pty.openpty()
            for fd in (controller, terminal):
                self.addCleanup(os.close, fd)
            os.write(controller, f"{typed}\n".encode())
            session["preexec_fn"] = lambda: fcntl.ioctl(terminal, termios.TIOCSCTTY, 0)
        with open(script or self.asset, "rb") as stdin:
            done = subprocess.run(["/bin/bash", "-s", *args], stdin=stdin, capture_output=True, text=True, timeout=60,
                                  env=dict(self.env, PATH=str(bin_dir), CALLS=str(calls), **env), **session)
        return done.returncode, done.stdout, done.stderr, calls.read_text().splitlines() if calls.exists() else []

    def assertNoChange(self, calls):
        self.assertEqual([call for call in calls if not call.startswith(READS)], [])


class Refusals(Server):
    def test_the_committed_copy_refuses_to_run(self):
        code, _, err, calls = self.run_bootstrap(script=BOOTSTRAP)
        self.assertEqual(code, 1)
        self.assertIn("este archivo es la copia del repositorio", err)
        self.assertIn("releases/latest/download/apsconecta-install.sh | sudo bash", err)
        self.assertEqual(calls, [])

    def test_a_user_without_sudo_is_refused_before_any_change(self):
        code, _, err, calls = self.run_bootstrap(SHIM_UID="1000")
        self.assertEqual(code, 1)
        self.assertIn("ejecute el instalador como administrador", err)
        self.assertNoChange(calls)

    def test_each_gap_is_named_and_refused_before_any_change(self):
        cases = {
            "an ARM machine": ({"SHIM_ARCH": "aarch64"}, (),
                               "la arquitectura del procesador es aarch64; se requiere x86_64"),
            "4 GiB of memory": ({"MEMINFO": self.file("small", "MemTotal:        4096000 kB\n")}, (),
                                "tiene 4 GiB de memoria; se requieren al menos 6 GiB"),
            "one CPU core": ({"SHIM_CPUS": "1"}, (), "tiene 1 núcleo(s) de CPU; se requieren al menos 2"),
            "12 GB of free disk": ({"SHIM_FREE_BYTES": "12500000000"}, (),
                                   "tiene 12 GB libres en /var/lib/docker; se requieren al menos 20 GB"),
            "Fedora without Docker": (
                {"OS_RELEASE": self.file("fedora", 'PRETTY_NAME="Fedora Linux 42"\nID=fedora\n')}, ("docker",),
                "Docker no está instalado y el instalador solo lo instala en Ubuntu o Debian (este servidor tiene "
                "Fedora Linux 42)"),
            "Docker's Snap package": ({"SHIM_DOCKER_ROOT": "/var/snap/docker/common/var-lib-docker"}, (),
                                      "Docker instalado mediante Snap no es compatible"),
            "a Docker that does not answer": ({"SHIM_DOCKER_ROOT": ""}, (), "Docker está instalado, pero no responde"),
            "8080 and 3478/udp taken": (
                {"SHIM_LISTENING": "tcp LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*\\nudp UNCONN 0 0 [::]:3478 [::]:*\\n"}, (),
                "el puerto 3478 (UDP) está en uso\n  - el puerto 8080 (TCP) está en uso"),
            "no /dev/fuse": ({"FUSE_DEVICE": str(self.dir / "no-fuse")}, (),
                             "falta el dispositivo /dev/fuse para los respaldos"),
            "no default route": ({"SHIM_ROUTE": ""}, (), "no tiene una ruta de red predeterminada, de la que el "
                                                        "instalador toma la dirección del servidor"),
        }
        for case, (env, without, gap) in cases.items():
            with self.subTest(case):
                code, out, err, calls = self.run_bootstrap(without=without, **env)
                self.assertEqual(code, 1, out)
                self.assertEqual(err, f"{REFUSED}  - {gap}\n")
                self.assertNoChange(calls)


def changes(calls):
    """The calls that change the server: everything but the reads."""
    return [call for call in calls if not call.startswith(READS + ("docker logs", "docker exec"))]


class Start(Server):
    def test_a_first_install_runs_the_release_digest_on_the_channel_tag_and_prints_the_link_block(self):
        code, out, err, calls = self.run_bootstrap()
        self.assertEqual(code, 0, err)
        self.assertTrue(out.endswith(BLOCK), out)
        self.assertNotIn("Initial startup", out)
        self.assertEqual(changes(calls), [
            f"tee {DROP_IN}", f"sysctl -p {DROP_IN}",
            f"docker pull --quiet {PINNED}",
            f"docker tag {PINNED} {CHANNEL}",
            f"docker run --init --sig-proxy=false --name {NAME} --restart always --detach --publish 8080:8080 "
            "--env APS_INTERFACE_ADDRESS=10.0.0.5 --volume nextcloud_aio_mastercontainer:/mnt/docker-aio-config "
            f"--volume /var/run/docker.sock:/var/run/docker.sock:ro {CHANNEL}"])
        self.assertEqual((self.dir / "tee").read_text(), "vm.overcommit_memory = 1\nvm.max_map_count = 262144\n")

    def test_the_kernel_settings_keep_a_higher_map_count(self):
        code, _, err, _ = self.run_bootstrap(SHIM_MAP_COUNT="1048576")
        self.assertEqual(code, 0, err)
        self.assertEqual((self.dir / "tee").read_text(), "vm.overcommit_memory = 1\nvm.max_map_count = 1048576\n")


class Reruns(Server):
    def test_a_rerun_before_listo_restarts_the_mastercontainer_and_prints_its_fresh_link_block(self):
        code, out, err, calls = self.run_bootstrap(SHIM_IMAGE=CHANNEL)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.endswith(BLOCK), out)
        self.assertEqual(changes(calls), [f"docker restart {NAME}"])

    def test_a_stopped_mastercontainer_is_started_before_its_state_is_read(self):
        code, _, err, calls = self.run_bootstrap(SHIM_IMAGE=CHANNEL, SHIM_RUNNING="false", SHIM_LISTO="1")
        self.assertEqual(code, 0, err)
        self.assertEqual(changes(calls), [f"docker start {NAME}"])

    def test_a_rerun_after_listo_changes_nothing_and_prints_the_suite_address(self):
        for domain, address in (("", "https://10.0.0.5:8080"), ("cesfam.example.cl", "https://cesfam.example.cl")):
            with self.subTest(domain or "no domain yet"):
                code, out, err, calls = self.run_bootstrap(SHIM_IMAGE=CHANNEL, SHIM_LISTO="1", SHIM_DOMAIN=domain)
                self.assertEqual(code, 0, err)
                self.assertEqual(out, f"APS Conecta Gestión ya está instalada en este servidor: {address}\n")
                self.assertEqual(changes(calls), [])

    def test_another_mastercontainer_is_refused_before_any_change(self):
        code, _, err, calls = self.run_bootstrap(SHIM_IMAGE="ghcr.io/nextcloud-releases/all-in-one:latest")
        self.assertEqual(code, 1)
        self.assertIn("ya tiene un contenedor maestro de AIO que no es de APS Conecta Gestión "
                      "(ghcr.io/nextcloud-releases/all-in-one:latest). No se modificó nada.", err)
        self.assertEqual(changes(calls), [])


class Reset(Server):
    def test_each_refusal_removes_nothing(self):
        cases = {
            "a wrong typed answer": (("restablecer",), {"typed": "eliminar"},
                                     "la confirmación no coincide. No se eliminó nada."),
            "no terminal": (("restablecer",), {},
                            "no se pudo leer la confirmación desde la terminal. No se eliminó nada."),
            "a Docker that does not answer": (("restablecer",), {"SHIM_DOCKER_ROOT": ""},
                                              "Docker está instalado, pero no responde. No se eliminó nada."),
            "an unknown argument": (("restablecr",), {}, "el instalador no conoce «restablecr». Sin argumentos instala "
                                    "APS Conecta Gestión; con «restablecer», la elimina de este servidor."),
        }
        for case, (args, options, refusal) in cases.items():
            with self.subTest(case):
                code, out, err, calls = self.run_bootstrap(*args, **options)
                self.assertEqual(code, 1, out)
                self.assertTrue(err.endswith(f"\nError: {refusal}\n"), err)
                self.assertNoChange(calls)


def findings(text):
    """What the install path must not have: a second command, an Enter prompt, a host service or a host timer."""
    code = re.sub(r"(?m)(^|\s)#.*$", "", text)
    found = []
    if re.search(r"systemctl|systemd|\.service\b|\.timer\b|\bcron", code):
        found.append("a host service or timer")
    reset = re.search(r"(?ms)^reset_suite\(\) \{$.*?^\}$", code)
    reads = re.findall(r"(?m)^.*\bread\b.*$", code)
    if any(reset is None or line not in reset.group(0) or "< /dev/tty" not in line for line in reads):
        found.append("an Enter prompt outside the reset's confirmation")
    if len(re.findall(r"\bsudo\b", text)) != len(re.findall(r"\| sudo bash\b", text)):
        found.append("a second command")  # the only command it names is itself
    return found


class Static(unittest.TestCase):
    def test_the_bootstrap_has_no_second_command_enter_prompt_host_service_or_timer(self):
        self.assertEqual(findings(BOOTSTRAP.read_text()), [])

    def test_the_check_finds_each_one(self):
        planted = """reset_suite() {
  read -r answer < /dev/tty
}
main() {
  systemctl enable --now aps-provisionador.timer
  read -r -p "Presione Enter para continuar" _
  say "Continúe con: sudo bash /opt/aps-conecta/instalador/host/aps-conecta install"
}
"""
        self.assertEqual(findings(planted), [
            "a host service or timer", "an Enter prompt outside the reset's confirmation", "a second command"])


if __name__ == "__main__":
    unittest.main()
