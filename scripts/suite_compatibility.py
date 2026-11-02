#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Read-only checks for the image capabilities this installer actually consumes."""

import argparse
import json
from pathlib import Path
import subprocess


PROBES = {
    "wizard": ("nextcloud-aio-mastercontainer", "el resultado de inicio requerido", [
        "sh", "-c", "file=/var/www/docker-aio/php/src/Controller/DockerController.php; "
        '[ -r "$file" ] || exit 2; grep -Fq "aps-start-result:" "$file"; status=$?; '
        'if [ "$status" -eq 1 ]; then printf "aps-incompatible\\n"; exit 42; fi; exit "$status"',
    ]),
    "provision": ("aps-conecta-nextcloud", "la configuración de aplicaciones requerida", [
        "sh", "-c", '[ -r / ] || exit 2; '
        'if [ ! -e "$1" ]; then printf "aps-incompatible\\n"; exit 42; fi; '
        '[ -f "$1" ] && [ -r "$1" ] || exit 2', "check", "/configure-apps.sh",
    ]),
}


def check(capability, root):
    """Return (exit status, diagnostic): 0 supported, 1 incompatible, 2 unverifiable."""
    container, requirement, command = PROBES[capability]
    image = "imagen no disponible"
    try:
        version = (Path(root) / "VERSION").read_text().strip()
        if not version:
            raise ValueError("empty installer version")
    except (OSError, ValueError):
        return 2, "no se pudo leer VERSION del instalador — restaure el paquete antes de reintentar"
    try:
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{json .Config.Image}}\t{{json .State.Running}}", container],
            capture_output=True, text=True, timeout=15, check=True,
        )
        image, running = map(json.loads, result.stdout.strip().split("\t"))
        if not isinstance(image, str) or not image or running is not True:
            raise ValueError("container unavailable")
        result = subprocess.run(["docker", "exec", container, *command],
                                capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            return 0, ""
        # Docker's own failures can exit 1; only the probe can prove a missing capability.
        if result.returncode != 42 or result.stdout != "aps-incompatible\n":
            raise ValueError("probe unavailable")
    except (OSError, ValueError, subprocess.SubprocessError):
        return 2, (f"no se pudo comprobar la compatibilidad de {container} ({image}) con el instalador "
                   f"{version} — compruebe el acceso a Docker y que el contenedor esté en marcha "
                   f"(docker inspect {container}); después reintente. No se ha confirmado una incompatibilidad")
    return 1, (f"la imagen de la suite ({image}) no corresponde a este instalador ({version}): "
               f"falta {requirement}. Utilice el instalador y las imágenes de una "
               "combinación aprobada (guía de instalación, §14 para ensayos); conserve los datos "
               "y volúmenes, corrija la combinación y reintente")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capability", choices=PROBES)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    status, message = check(args.capability, args.root)
    if message:
        print(message)
    raise SystemExit(status)
