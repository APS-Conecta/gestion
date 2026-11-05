#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The antivirus as staff meet it, on a test build: the EICAR test file a person uploads is refused and deleted, while
an encrypted PDF, as a lab sends a result that only the patient's RUT opens, and a large file upload normally. And the
EICAR test file that reached their files without the upload's scan is deleted by the antivirus's background scan,
whose infected-file action the antivirus step sets to delete; AIO's cron runs that scan, and the check runs it at once
instead of waiting. Any other candidate's names are production ones, which a run never claims: there it says so and
passes."""

import hashlib
import os
import secrets
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from browser import NEXTCLOUD, as_person, machine, occ, person, suite_name  # noqa: E402

USER, UPLOADED, UNSCANNED = "prueba.antivirus", "eicar-subido.txt", "eicar-sin-revisar.txt"
EICAR = r"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR" + r"-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"  # halved: no repo file holds it
ENCRYPTED, RUT = "resultado-cifrado.pdf", "11111111-1"  # the PDF and the password that opens it, a patient's RUT
LARGE, SIZE = "estudio-grande.bin", 200 * 2**20  # bytes: twice ClamAV's own default limits, which AIO's ClamAV raises
# PDF's standard security handler, revision 2: the padding of a password, and every permission granted.
PAD = bytes.fromhex("28bf4e5e4e758a4164004e56fffa01082e2e00b6d0683e802f0ca9fe6453697a")
PERMISSIONS = -4


def rc4(key, data):
    """RC4, the cipher of PDF's standard security handler up to its revision 4; Python's standard library has none."""
    state, j = list(range(256)), 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) % 256
        state[i], state[j] = state[j], state[i]
    out, i, j = bytearray(), 0, 0
    for byte in data:
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        out.append(byte ^ state[(state[i] + state[j]) % 256])
    return bytes(out)


def encrypted_pdf(text, password):
    """A one-page PDF of `text` that opens only with `password`, encrypted by PDF's standard security handler, revision
    2, with the same owner password."""
    padded = (password.encode() + PAD)[:32]
    owner = rc4(hashlib.md5(padded).digest()[:5], padded)
    identifier = secrets.token_bytes(16)
    key = hashlib.md5(padded + owner + struct.pack("<i", PERMISSIONS) + identifier).digest()[:5]
    # The page's content stream, object 4 of generation 0: its key takes both numbers, low-order byte first.
    content = rc4(hashlib.md5(key + b"\x04\x00\x00\x00\x00").digest()[:10],
                  f"BT /F1 18 Tf 72 720 Td ({text}) Tj ET".encode())
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
               b"/Resources << /Font << /F1 5 0 R >> >> >>",
               b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content),
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               b"<< /Filter /Standard /V 1 /R 2 /O <%s> /U <%s> /P %d >>" % (
                   owner.hex().encode(), rc4(key, PAD).hex().encode(), PERMISSIONS)]
    pdf, offsets = bytearray(b"%PDF-1.4\n"), []
    for number, body in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    start = len(pdf)
    pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    pdf += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    pdf += b"trailer\n<< /Size %d /Root 1 0 R /Encrypt 6 0 R /ID [<%s> <%s>] >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1, identifier.hex().encode(), identifier.hex().encode(), start)
    return bytes(pdf)


if os.environ["TEST_BUILD"] != "true":
    print(f"the antivirus check runs on a v0.0.0-ci.N test build only: {os.environ['TAG']}'s names and certificates "
          "are production ones")
    sys.exit()
files = f"https://{suite_name()}/remote.php/dav/files/{USER}"
password = person(USER, "Prueba Antivirus")


def upload(name, body):
    """The status the suite answers the person's upload of the file."""
    status, answer = as_person(USER, password, "PUT", f"{files}/{name}", body)
    print(f"uploading {name} ({len(body)} bytes) answered {status}: {answer.decode(errors='replace')[-300:]}")
    return status


def held(name):
    """Whether the person's files hold the file, as their own client lists them."""
    return as_person(USER, password, "PROPFIND", f"{files}/{name}", headers={"Depth": "0"})[0] == 207


if 200 <= upload(UPLOADED, EICAR.encode()) < 300 or held(UPLOADED):
    sys.exit("the antivirus let the uploaded EICAR test file into the person's files")
if upload(ENCRYPTED, encrypted_pdf("Resultado de laboratorio", RUT)) != 201 or not held(ENCRYPTED):
    sys.exit(f"the encrypted PDF {ENCRYPTED} did not upload normally")

# Written into the person's folder on the server, then listed by Nextcloud's own scan: the upload's scan never saw it.
machine(f"{NEXTCLOUD} sh -c 'cat > /mnt/ncdata/{USER}/files/{UNSCANNED}'", EICAR)
occ(f"files:scan --path=/{USER}/files")
if not held(UNSCANNED):
    sys.exit(f"{UNSCANNED}, written into the person's folder, is not in their files")
print(occ("files_antivirus:background-scan").strip())
if held(UNSCANNED):
    sys.exit("the antivirus's background scan kept the EICAR test file it found instead of deleting it")

# Last, since the background scan scans again each file the uploads' scans saw.
if upload(LARGE, os.urandom(SIZE)) != 201 or not held(LARGE):
    sys.exit(f"the large file {LARGE} did not upload normally")
print(f"the uploaded EICAR test file was refused and deleted, {ENCRYPTED} and the {SIZE // 2**20} MiB {LARGE} uploaded "
      "normally, and the background scan deleted the EICAR test file it found")
