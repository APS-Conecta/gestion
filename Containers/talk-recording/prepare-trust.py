#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later

import json
from pathlib import Path
import ssl
import sys


def prepare_trust(system_ca, certificate_dir, output_dir):
    certificates = sorted(path for path in certificate_dir.glob("*") if path.is_file())
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    for path in [system_ca, *certificates]:
        context.load_verify_locations(cafile=str(path))

    bundle = b"\n".join(path.read_bytes() for path in [system_ca, *certificates]) + b"\n"
    (output_dir / "ca-certificates.crt").write_bytes(bundle)
    policies = {"policies": {"Certificates": {"Install": [str(path) for path in certificates]}}}
    (output_dir / "firefox-policies.json").write_text(json.dumps(policies) + "\n", encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: prepare-trust.py SYSTEM_CA CERTIFICATE_DIR OUTPUT_DIR")
    try:
        prepare_trust(*(Path(value) for value in sys.argv[1:]))
    except (OSError, ssl.SSLError) as error:
        sys.exit(f"Recording certificate trust could not be prepared: {error}")
