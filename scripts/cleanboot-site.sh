#!/usr/bin/env bash
# Clean boot's clinic: the site file and the planilla a clinic brings, generated at run time and handed
# to the silent install the way an operator hands them over — no establishment ships. Piped answers
# stand in for the operator's; deis.py writes into sites/, so its file is moved out — the install's own
# «centro» step places it back (a7). One copy for both Clean boot jobs: by domain and by IP.
#   scripts/cleanboot-site.sh ADDRESS DIR   → DIR/site.sh (SITE_DOMINIO=ADDRESS) and DIR/usuarios.csv
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
address="${1:?usage: scripts/cleanboot-site.sh ADDRESS DIR}"
dir="${2:?usage: scripts/cleanboot-site.sh ADDRESS DIR}"
# A deterministic pick over the register, not a fixed code (FINDINGS P2): every clinic in
# the register is a valid install, and CI booting the same one every time is a fixture
# that steers — and names a real clinic in a public log. sha256 over the sorted codes
# makes the pick stable per register content, and satisfies the establishment-agnostic
# gate (ADR-0013): no tracked file may hand deis.py a DEIS code (AGNOSTIC_SHAPE).
pick=$(python3 - <<'PY'
import csv, glob, hashlib, sys
files = sorted(glob.glob("sites/establecimientos-deis-*.csv"))
if not files:
    sys.exit("FATAL: no sites/establecimientos-deis-*.csv — nothing to boot against")
with open(files[-1], encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh))
if not rows:
    sys.exit("FATAL: the register is empty — refusing to boot a silent green (B-001)")
codes = sorted(r["codigo"] for r in rows)
pick = codes[int(hashlib.sha256("\n".join(codes).encode()).hexdigest(), 16) % len(codes)]
row = next(r for r in rows if r["codigo"] == pick)
print(pick + "\t" + row["nombre"] + " (" + row["comuna"] + ")")
PY
) || exit 1
code=${pick%%$'\t'*}
[ -n "$code" ] || { echo "FATAL: empty register pick" >&2; exit 1; }
echo "cleanboot: register pick — DEIS $code: ${pick#*$'\t'}"
# The piped answers are generic by construction — ask() always asks sectors then
# programs, for every tipo — so they survive the moving pick unchanged.
printf 'Sector 1\nSector 2\n\nSalud Mental\nInfantil\n\n' | scripts/deis.py "$code" --new "$code"
mv "sites/$code/site.sh" "$dir/site.sh" && rmdir "sites/$code"
# The address (the probe's domain, or the runner's IP), and the establishment-local roles (#103).
# deis.py writes both empty by design, so the create path would never run anywhere if CI did not
# add them. One of each kind on purpose: a jefatura, which must ALSO produce a standing account,
# and a technical role, which must not. Written in the array shape the Provisionador reads.
python3 - "$dir/site.sh" "$address" <<'PY'
import sys
path, address = sys.argv[1:3]
text = open(path, encoding="utf-8").read()
assert text.count('SITE_DOMINIO=""') == 1 and text.count("SITE_ROLES=()") == 1, path
text = text.replace('SITE_DOMINIO=""', f'SITE_DOMINIO="{address}"').replace(
    "SITE_ROLES=()", 'SITE_ROLES=(\n  "role-jefe-sar|Jefe/a de SAR|cat-jefaturas"\n'
    '  "role-tens-sar|TENS – SAR|cat-tecnicos"\n)')
open(path, "w", encoding="utf-8").write(text)
PY
# Two people, one per kind of role — a shared one and the site's own technical one — and
# one of them the first administrator. Generic names: nothing identifies the clinic.
cat > "$dir/usuarios.csv" <<'PLANILLA'
usuario;nombre;apellidos;correo;grupos;primer_admin
ana.prueba;Ana;Prueba Uno;;role-medico;si
beto.prueba;Beto;Prueba Dos;;role-tens-sar;no
PLANILLA
