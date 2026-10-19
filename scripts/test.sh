#!/usr/bin/env bash
# Local quality gate for what stays in gestion (Story 0.4; pruned when the installer moved).
# The CI workflow moved with the installer — instalador's ci.yml runs instalador's own gate —
# so this one is hand-run (`bash scripts/test.sh`) or by whatever minimal gestion workflow the
# org keeps. STATIC checks only now: the subjects are gestion's suite-definition content (the
# vendored apps, the register, the theme), the drift tooling, and the shape rules that hold
# the whole tree. The install half's behavioural gates and self-tests live in instalador's
# scripts/test.sh. Exits non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
if [ ! -f .env ]; then
  echo "  note: .env absent — compose interpolation will fail; run 'make setup' first"
fi
# One parse, not two: the `--profile eurooffice` run went with the profile in #81 — Euro-Office is
# an ordinary service now, so this parse already covers it. The dev overlay is included because it
# is the only other file that can change what compose resolves.
check docker compose -f compose.yaml -f compose.dev.yaml config -q
linted=0
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh dev/*.sh host/*.sh tests/*/*.sh; do
  [ -e "$s" ] || continue
  linted=$((linted + 1)); check bash -n "$s"
done
# A glob that matches nothing stays literal, `[ -e ]` skips it, and the gate reports only the checks
# it did run — so a renamed directory would silently lint nothing and still print all-ok.
#
# The floor this replaced (`-ge 15`) could not see the case it was written for. It counted what the
# globs matched, and the globs are what define that set: a script added in a NEW directory is absent
# from both sides, so the count never moves and the floor stays green. Compare the sweep against
# `git ls-files` instead — the one list that grows when a script is added anywhere. Adding a script
# to an existing directory still costs nothing; adding a directory now fails loudly, which is the
# whole point.
# SUBSET, not equality. The sweep legitimately lints files git has never heard of: cleanboot.yml
# installs a clinic from nothing, its site placed at sites/<DEIS>/site.sh, and linting it is correct — it is
# real shell that a real install sources. Demanding the two lists MATCH failed there and only there,
# which is the worst shape a gate can have: green on every developer's machine, red only in CI.
# What actually matters is that nothing TRACKED escapes the sweep, so subtract and require empty.
check bash -c '
  [ -z "$(comm -23 <(git ls-files "*.sh" | sort) \
                   <(ls scripts/*.sh provisioning/*.sh provisioning/phases/*.sh sites/*/site.sh dev/*.sh host/*.sh tests/*/*.sh 2>/dev/null | sort))" ]'
check test -f dev/xdebug.ini
# Same three assertions `ensure_vendored_app` already makes (lib.sh:211-222), moved from seed time to
# PR time. At seed time they run on a CLINIC, during `make install` — the worst place to learn that a
# tarball and its manifest stopped describing each other, because the operator is mid-install and the
# failure reads as the install being broken. Here it needs no stack, no .env, no clock and no network,
# so it runs in any pull request, including a hotfix opened from a clinic.
# NOT a replacement for the seed-time check: that one guards the bytes that actually get unpacked.
check bash -c '
  rc=0
  for v in provisioning/apps/*/VENDOR; do
    d=$(dirname "$v"); id=$(basename "$d")
    n=$(ls "$d"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$n" -ne 1 ]; then echo "$id: expected exactly one *.tar.gz, found $n" >&2; rc=1; continue; fi
    t=$(ls "$d"/*.tar.gz)
    ver=$(sed -n "s/^version=//p" "$v"); sha=$(sed -n "s/^sha256=//p" "$v")
    if [ -z "$ver" ] || [ -z "$sha" ]; then echo "$id: VENDOR lacks version= or sha256=" >&2; rc=1; continue; fi
    [ "$(basename "$t")" = "$id-$ver.tar.gz" ] || { echo "$id: $(basename "$t") is not $id-$ver.tar.gz" >&2; rc=1; }
    echo "$sha  $t" | sha256sum --check --status || { echo "$id: bytes do not match sha256= in VENDOR" >&2; rc=1; }
  done
  exit $rc'
# --- gate (L5 S4): the vendored map libraries are the pinned bytes ---------------------------------
# The Centro pane's engine is Leaflet, two files copied byte-identical from territorio's
# node_modules (docs/LICENSING.md §3); its basemap is OpenStreetMap's tiles, loaded by the browser. Vendored bytes are the one diff a reviewer reads as "just assets":
# territorio upgrades, a re-vendor misses a file, an editor "fixes" a minified line — and the
# installer's map changes with no gate the eye can catch. The image-digests pair-pin discipline,
# applied to vendored files: each must exist and hash to its pin. The negative half mutates one
# byte of a copy — a gate that cannot go red is not a gate (A-010).
check python3 -c '
import hashlib, os, sys, tempfile
PINS = {
    "themes/apsconecta/core/mapa/leaflet.js":
        "db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a",
    "themes/apsconecta/core/mapa/leaflet.css":
        "a7837102824184820dfa198d1ebcd109ff6d0ff9a2672a074b9a1b4d147d04c6",
}
def distinta(corpus):   # the first path whose bytes are not its pin, or None
    for ruta, pin in corpus.items():
        with open(ruta, "rb") as fh:
            if hashlib.sha256(fh.read()).hexdigest() != pin:
                return ruta
    return None
real = distinta(PINS)
with tempfile.TemporaryDirectory() as tmp:
    mutada = os.path.join(tmp, "leaflet.css")
    with open("themes/apsconecta/core/mapa/leaflet.css", "rb") as src:
        datos = bytearray(src.read())
    datos[100] ^= 1
    with open(mutada, "wb") as dst:
        dst.write(datos)
    drill = distinta({**PINS, mutada: PINS["themes/apsconecta/core/mapa/leaflet.css"]})
if real is not None:
    print("the vendored map libraries are not the pinned bytes: " + real)
if drill != mutada:
    print("the mutation drill passed — the gate could not see a changed byte")
sys.exit(0 if real is None and drill == mutada else 1)'
# docs/LICENSING.md claims a licence per app and says it was read "from each app'"'"'s appinfo/info.xml
# inside the shipped tarball". Nothing checked that it still was. `eurooffice` is AGPL-3.0-ONLY and
# the table said -or-later -- materially different grants -- through two documentation audits (#87,
# #88) and a version bump (#167) that edited that very row without looking one cell to the left
# (#171). Reading is what failed; so this reads the tarball, which is tracked and needs no network.
# `agpl` is Nextcloud'"'"'s legacy bare string for AGPL v3 or later -- calendar, side_menu and
# epidemiologia still declare it -- so it normalises rather than failing.
# The empty case FAILS: a table that describes no app, or a glob that matches nothing, is not a pass.
check python3 -c '
import glob, re, sys, tarfile, xml.etree.ElementTree as ET
NORM = {"agpl": "AGPL-3.0-or-later", "agpl3": "AGPL-3.0-or-later", "AGPL3": "AGPL-3.0-or-later"}
declarado = {}
for d in sorted(glob.glob("provisioning/apps/*/")):
    app = d.rstrip("/").split("/")[-1]
    tars = glob.glob(d + "*.tar.gz")
    if not tars:
        print(f"{app}: no tarball to read a licence from"); sys.exit(1)
    with tarfile.open(tars[0]) as t:
        info = [n for n in t.getnames() if n.endswith("appinfo/info.xml")]
        if not info:
            print(f"{app}: {tars[0]} carries no appinfo/info.xml"); sys.exit(1)
        x = ET.fromstring(t.extractfile(info[0]).read())
    lic = (x.findtext("licence") or x.findtext("license") or "").strip()
    declarado[app] = NORM.get(lic, lic)
if not declarado:
    print("no vendored app found under provisioning/apps/ -- this check measured nothing"); sys.exit(1)
tabla, col = {}, None
for linea in open("docs/LICENSING.md", encoding="utf-8"):
    celdas = [c.strip() for c in linea.strip().strip("|").split("|")]
    # The column is read from the header, never hard-coded: the Source column also holds
    # backticks, so "the last backticked cell" picks the wrong one, and a column inserted
    # later would silently shift a fixed index onto its neighbour.
    if "SPDX" in celdas: col = celdas.index("SPDX"); continue
    m = re.search(r"NC app `([a-z_]+)`", linea)
    if not m or col is None: continue
    tabla[m.group(1)] = celdas[col].strip("`") if col < len(celdas) else None
if col is None:
    print("docs/LICENSING.md has no SPDX column -- this check measured nothing"); sys.exit(1)
mal = []
for app, lic in sorted(declarado.items()):
    if app not in tabla:
        mal.append(f"{app}: vendored, but docs/LICENSING.md has no row for it")
    elif tabla[app] != lic:
        mal.append(f"{app}: info.xml says {lic}, docs/LICENSING.md says {tabla[app]}")
if mal:
    print("\n".join(mal)); sys.exit(1)'
# Every service must come back after the host reboots. Read from the RESOLVED config rather than
# grepped: two of them take the policy from the shared anchor, and a service added later must not
# be able to arrive without one — the person who would notice a stack that stayed down is a CESFAM
# administrator with no reason to know `make up`.
check python3 -c '
import json, subprocess, sys
config = json.loads(subprocess.run(["docker", "compose", "config", "--format", "json"],
                                   capture_output=True, text=True, check=True).stdout)
missing = sorted(name for name, service in config["services"].items() if not service.get("restart"))
if missing:
    print("no restart policy: " + ", ".join(missing))
    sys.exit(1)'
# A clinic must never be installed with the secrets this repository publishes. env-init.sh generates
# all four, so a placeholder survives only a hand-copy of the template — which is what somebody does
# when `make setup` refuses because .env is already there. Behavioural, and driven from
# .env.example: the template is what defines a placeholder, so this cannot rot when one is reworded.
check bash -c '
  . scripts/env.sh
  require_real_secrets || exit 1
  shipped() { grep "^$1=" .env.example | cut -d= -f2-; }
  for key in NEXTCLOUD_ADMIN_PASSWORD POSTGRES_PASSWORD OFFICE_JWT_SECRET FIXTURE_USER_PASSWORD; do
    ( export "$key=$(shipped "$key")"; require_real_secrets 2>/dev/null ) && exit 1
  done
  # And a value that CARRIES the marker without EQUALING the template byte for byte. That is
  # what a quoted placeholder becomes once the loader in env.sh strips its quotes, and what a
  # `$$` one becomes once it undoes the escape — both conventions .env.example already uses,
  # at line 21 and lines 5-6. The equality test this replaced let exactly this through: the
  # gate failed OPEN, silently, and a clinic would install with a published secret.
  ( export NEXTCLOUD_ADMIN_PASSWORD="\"$(shipped NEXTCLOUD_ADMIN_PASSWORD)\""; require_real_secrets 2>/dev/null ) && exit 1
  exit 0'
# Regression guard (#39): a `set -e` subshell's status must not be consumed in a conditional
# context — bash suppresses errexit inside it, so what reads as a guard runs on and reports
# success. Two shapes, because the second is the one that shipped:
#   - something TESTS it from the left: `if (`, `while (`, `&& (`. Matched on what PRECEDES
#     the `(` rather than by listing keywords — nothing but whitespace may.
#   - something tests it from the right: `( set -e … ) || exit 1`. This reads exactly like a
#     guard and is not one, and two assertions in THIS file were written that way and
#     asserted nothing across three audit rounds. Which is why the sweep now reads
#     scripts/ too: the original guard looked only at seed.sh, and the defect moved.
# Comments are stripped first, since seed.sh documents the wrong shape on purpose.
# Over `git ls-files`, not a hand-written list of directories: a third copy of that list is a
# third thing to forget, and a sweep that matches nothing passes — which is the very hole the
# lint sweep above was rewritten to close. Python rather than grep because the subshell and the
# `||` that tests it are not always on one line.
check python3 -c '
import re, subprocess, sys

ERREXIT = r"set\s+(-[a-z]*e|-o[ \t]+errexit)"
FROM_THE_LEFT = re.compile(r"\S[ \t]*\(\s*" + ERREXIT)
FROM_THE_RIGHT = re.compile(r"\(\s*" + ERREXIT + r"[^()]*\)[ \t]*(\|\||&&)")

files = subprocess.run(["git", "ls-files", "-z", "*.sh"],
                       capture_output=True, text=True, check=True).stdout.split("\0")
bad = []
for name in filter(None, files):
    with open(name, encoding="utf-8") as handle:
        # Comments are stripped first: seed.sh documents the wrong shape on purpose.
        body = "".join(l for l in handle if not l.lstrip().startswith("#"))
    for hit in FROM_THE_LEFT.finditer(body):
        bad.append(f"{name}: tested from the left — {hit.group(0).strip()!r}")
    for hit in FROM_THE_RIGHT.finditer(body):
        bad.append(f"{name}: tested from the right — the {hit.group(2)} after the subshell")

if bad:
    print("errexit is suppressed in a tested context, so these guard nothing:")
    for line in bad:
        print("  " + line)
    sys.exit(1)'
# Regression guard (ADR-0001): every STATIC asset server.css references must exist on disk. It shipped
# for months declaring four .woff2 files that were never generated, and the TTF fallback swallowed the
# 404s. The COUNT is asserted before the existence loop, and that is the point: `grep | while read`
# runs zero times when grep matches nothing and exits 0, so the guard passed on a file with no themed
# reference at all. Requiring every reference to be a themed absolute path also catches one of four
# drifting, which "at least one" would not.
#
# ONE path is excluded, by exact name and never by pattern: site.css is @import-ed by server.css but
# is GENERATED per install by phase 15 and is not tracked, so a checkout that has never been
# provisioned legitimately does not have it — and server.css declares the fallback that renders the
# product's own name until it does. A `*.css` or directory-wide exclusion here would silently stop
# checking assets added later, which is the exact shape of the bug this guard exists for.
check bash -c '
  css=themes/apsconecta/core/css/server.css
  total=$(grep -oE "url\(\"" "$css" | wc -l)   # the quote matters: server.css says "url()" in prose
  themed=$(grep -oE "url\(\"/themes/apsconecta[^\"]+\"" "$css" | wc -l)
  [ "$total" -ge 1 ] && [ "$total" -eq "$themed" ] || exit 1
  grep -oE "/themes/apsconecta[^\")]+" "$css" | sed "s|^/||" \
    | grep -vFx "themes/apsconecta/core/css/site.css" \
    | while read -r f; do [ -f "$f" ] || exit 1; done'
# Regression guard: every brand SVG must PARSE, not merely exist. Nextcloud serves a malformed SVG
# with a 200 and the browser renders nothing — silent, and the existence check above cannot see it.
# A double hyphen inside an XML comment once made logo-header.svg unparseable and the header logo
# vanished while every gate stayed green.
check python3 -c 'import glob,sys,xml.etree.ElementTree as ET
bad=[]
for f in sorted(glob.glob("themes/apsconecta/core/img/**/*.svg", recursive=True)):
    try: ET.parse(f)
    except Exception as e: bad.append(f"{f}: {e}")
if bad: print("\n".join(bad)); sys.exit(1)'
# Regression guard (B-011): a lockup that draws text must carry the font that text is set in. An SVG
# served as an image is an isolated document and cannot see server.css's @font-face, so the wordmark
# still renders — just in the OS fallback, which nobody reports as a bug.
# themes/apsconecta/tools/embed-fonts.py puts the subset in; this asserts it was run.
check python3 -c 'import glob,sys,re
bad=[]
for f in sorted(glob.glob("themes/apsconecta/core/img/**/*.svg", recursive=True)):
    s = open(f, encoding="utf-8").read()
    if not re.search(r"<text[ >]", s): continue
    if "@font-face" not in s or "data:font/woff2;base64," not in s:
        bad.append(f"{f}: draws <text> with no embedded @font-face — run themes/apsconecta/tools/embed-fonts.py")
    for fam in set(re.findall(r"font-family=\"([^\"]+)\"", s)):
        if "," in fam:
            bad.append(f"{f}: font-family=\"{fam}\" keeps an OS fallback; the embedded face must be the only option")
if bad: print("\n".join(bad)); sys.exit(1)'

# scripts/deis.py writes sites/<slug>/site.sh and provisioning/seed.sh SOURCES it, so every value
# it emits is shell syntax unless it is quoted. It was not: five register fields went into the file
# inside double quotes, raw. Six values in the shipped register carry a `"` or a backtick, and the
# two failure modes are different sizes of bad — DEIS 113314's address holds a backtick, which is a
# syntax error that kills the phase loop, while DEIS 201079's name holds quotes, which parses CLEAN,
# runs `Juan` as a command and leaves SITE_NOMBRE EMPTY. A clinic provisioned with no name, silently.
#
# Behavioural, and over the WHOLE register rather than the six known-bad rows: the register is
# regenerated from DEIS by `--snapshot`, so tomorrow's hostile value is one nobody has seen. Every
# row is emitted, sourced by a real bash, and compared byte-for-byte with what the CSV holds — one
# bash process for all of them, because 2655 forks is a gate nobody would keep.
#
# `bash -n` alone would not catch it: the DEIS 201079 shape passes a syntax check and still loses
# the value. The round trip is the assertion.
check python3 -c '
import csv, glob, re, subprocess, sys, os
sys.path.insert(0, "scripts")
import deis

register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))
if len(rows) < 100:
    print("register looks truncated: " + str(len(rows)) + " rows"); sys.exit(1)

FIELDS = {"SITE_NOMBRE": "nombre", "SITE_DIRECCION": "direccion",
          "SITE_COMUNA": "comuna", "SITE_SERVICIO_SALUD": "servicio_salud",
          "SITE_COMUNA_CUT": "comuna_codigo", "SITE_LON": "longitud", "SITE_LAT": "latitud"}

script = ["set -u"]
for row in rows:
    script.append(deis.block(row, "gate"))
    for var in FIELDS:
        script.append("printf \"%s\\n\" \"$" + var + "\"")
# On stdin, not argv: 2655 blocks is past ARG_MAX and bash never starts.
out = subprocess.run(["bash"], input="\n".join(script), capture_output=True, text=True)
if out.returncode != 0:
    print("sourcing the generated identity blocks failed: " + out.stderr.strip()[:300]); sys.exit(1)

got = out.stdout.split("\n")
bad = []
for i, row in enumerate(rows):
    for j, (var, field) in enumerate(FIELDS.items()):
        want, have = row[field], got[i * len(FIELDS) + j]
        if want != have:
            bad.append("DEIS " + row["codigo"] + " " + var + ": wrote " + repr(want) + ", bash read " + repr(have))
if bad:
    print("values the generated site.sh does not round-trip (" + str(len(bad)) + "):")
    for line in bad[:5]:
        print("  " + line)
    sys.exit(1)
# The CUT parity half: territorio'"'"'s Comuna::of() accepts exactly five digits, and a register
# value that missed that shape would disarm the import door silently on every install — the
# phase writes whatever the register says. Wrong-shaped CUTs are a register defect, and this
# is where it goes red instead.
bad_cut = [r["codigo"] for r in rows if not re.fullmatch(r"[0-9]{5}", r["comuna_codigo"])]
if bad_cut:
    print("comuna_codigo values Comuna::of() would refuse (not 5 digits) — a phase 16 write"
          " of any of these silently disarms the import door: " + ", ".join(bad_cut[:5]))
    sys.exit(1)'
# The register's coordinates have a WRITER (deis.py --coordenadas) that runs by hand once per
# MINSAL release, so this is where it is proven. On a scratch register of three real rows —
# 201079's quotes and 113314's backtick among them — it must refuse a source that misses an
# establishment and one whose latitude or longitude is not plain degrees, leaving the file untouched;
# then append the two columns as published (text, never re-rounded) with every original line kept
# byte for byte; then rewrite the same bytes when run again.
check python3 -c '
import csv, glob, os, shutil, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
point = {"110485": ("-33.976637", "-71.468749"), "201079": ("-51.728207", "-72.482647"),
         "113314": ("-33.56136", "-70.67469")}
rows = [r for r in csv.DictReader(open(register, encoding="utf-8")) if r["codigo"] in point]
if len(rows) != 3:
    print("the three probe rows are not in the register -- this check measured nothing"); sys.exit(1)
def source(path, codes, bad=None):
    feats = []
    for c in codes:
        lat, lon = point[c]
        if c == "113314" and bad:
            lat, lon = bad
        feats.append("{\"type\":\"Feature\",\"geometry\":null,\"properties\":{\"cod_vig\":" + c
                     + ".0,\"latitud\":" + lat + ",\"longitud\":" + lon + "}}")
    open(path, "w", encoding="utf-8").write("{\"type\":\"FeatureCollection\",\"features\":[" + ",".join(feats) + "]}")
def run(path):
    try:
        deis.coordinates_from(path)
        return None
    except SystemExit as e:
        return str(e)
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE); os.makedirs(os.path.join(tmp, "sites"))
    reg = os.path.join(tmp, "sites", "establecimientos-deis-2099-01-01.csv")
    with open(reg, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh); w.writerow(deis.COLUMNS); w.writerows([r[k] for k in deis.COLUMNS] for r in rows)
    before = open(reg, "rb").read()
    gj = os.path.join(tmp, "src.geojson")
    source(gj, ["110485", "201079"]); short = run(gj)
    source(gj, list(point), bad=("\"-33.5; id\"", "-70.67469")); hostile = run(gj)
    source(gj, list(point), bad=("-33.56136", "-70.6e1")); hostile_lon = run(gj)
    untouched = open(reg, "rb").read() == before
    source(gj, list(point)); full = run(gj)
    after = open(reg, "rb").read()
    again = run(gj) is None and open(reg, "rb").read() == after
    out = list(csv.DictReader(open(reg, encoding="utf-8")))
finally:
    shutil.rmtree(tmp)
old, new = before.split(b"\r\n"), after.split(b"\r\n")
fails = []
if not short or "113314" not in short: fails.append("a source missing 113314 was not refused: " + repr(short))
if not hostile or "113314" not in hostile: fails.append("a latitude that is not plain degrees was not refused: " + repr(hostile))
if not hostile_lon or "113314" not in hostile_lon: fails.append("a longitude that is not plain degrees was not refused: " + repr(hostile_lon))
if not untouched: fails.append("a refused run changed the register")
if full is not None: fails.append("the full source was refused: " + full)
if not out or tuple(out[0]) != deis.COLUMNS + deis.COORDS: fails.append("the header is not the ten columns, then latitud,longitud")
if any((r["latitud"], r["longitud"]) != point[r["codigo"]] for r in out): fails.append("coordinates not written as published")
if len(old) != len(new) or not all(n.startswith(o + b",") for o, n in zip(old, new) if o): fails.append("an original line changed")
if not again: fails.append("a second run did not rewrite the same bytes")
if fails:
    print("\n".join(fails)); sys.exit(1)'
# A --snapshot whose points never came is the newest file, so every reader would take it and
# block() would die on a KeyError inside the installer. load() stops instead, naming both ways
# out, and a refused --coordenadas on it says how to step back to the register before it. On a
# scratch tree: an older register with points, then a fresh ten-column snapshot of the same rows.
check python3 -c '
import csv, glob, os, shutil, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
rows = list(csv.DictReader(open(register, encoding="utf-8")))[:3]
if len(rows) != 3 or not all(r.get("latitud") for r in rows):
    print("no register rows with points to build the scratch tree -- this check measured nothing"); sys.exit(1)
def stop(fn, *a):
    try:
        fn(*a); return None
    except SystemExit as e:
        return str(e)
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE); os.makedirs(os.path.join(tmp, "sites"))
    for name, cols in (("2099-01-01", deis.COLUMNS + deis.COORDS), ("2099-02-01", deis.COLUMNS)):
        with open(os.path.join(tmp, "sites", "establecimientos-deis-" + name + ".csv"), "w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh); w.writerow(cols); w.writerows([r[k] for k in cols] for r in rows)
    loaded = stop(deis.load)
    gj = os.path.join(tmp, "empty.geojson")
    open(gj, "w", encoding="utf-8").write("{\"type\":\"FeatureCollection\",\"features\":[]}")
    refused = stop(deis.coordinates_from, gj)
    os.remove(os.path.join(tmp, "sites", "establecimientos-deis-2099-02-01.csv"))
    back = deis.load()
    os.remove(os.path.join(tmp, "sites", "establecimientos-deis-2099-01-01.csv"))
    with open(os.path.join(tmp, "sites", "establecimientos-deis-2099-03-01.csv"), "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh); w.writerow(deis.COLUMNS); w.writerows([r[k] for k in deis.COLUMNS] for r in rows)
    alone = stop(deis.load)
finally:
    shutil.rmtree(tmp)
fails = []
if not loaded or "--coordenadas" not in loaded or "fall back to establecimientos-deis-2099-01-01.csv" not in loaded:
    fails.append("load() on a snapshot without points did not stop with both ways out: " + repr(loaded))
if not refused or "remove establecimientos-deis-2099-02-01.csv to fall back" not in refused:
    fails.append("a refused --coordenadas on a fresh snapshot did not say how to step back: " + repr(refused))
if back[0] != "2099-01-01" or len(back[1]) != 3:
    fails.append("removing the snapshot did not hand the register back: " + repr(back[0]))
if not alone or "fall back" in alone:
    fails.append("with no register before it, the fix hint must not offer a fallback: " + repr(alone))
if fails:
    print("\n".join(fails)); sys.exit(1)'
# The welcome declaration has a WRITER (deis.py) and a READER (seed.sh's guard + phase 41). This
# proves the writer's output is what the reader expects: written to a scratch tree (write_site
# refuses an existing sites/<name>/), sourced by a real bash, the rows read back — and `equipos`
# absent, because that is the product decision the default carries (review L0-01).
check python3 -c '
import csv, glob, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, "scripts")
import deis
register = sorted(glob.glob("sites/establecimientos-deis-*.csv"))[-1]
row = next(csv.DictReader(open(register, encoding="utf-8")))
tmp = tempfile.mkdtemp()
try:
    deis.HERE = os.path.join(tmp, "scripts"); os.makedirs(deis.HERE)
    deis.write_site(row, "gate", "probe", sectors=[], programs=[])
    out = subprocess.run(["bash", "-c", "set -u; . sites/probe/site.sh; printf \"%s\\n\" \"${SITE_WELCOME[@]}\""],
                         cwd=tmp, capture_output=True, text=True)
finally:
    shutil.rmtree(tmp)
if out.returncode != 0:
    print("sourcing the written site file failed: " + out.stderr.strip()[:300]); sys.exit(1)
rows = out.stdout.split()
if rows != ["noticias|wall", "vida-cesfam|", "documentos|wall"]:
    print("SITE_WELCOME default is not the three declared rows: " + repr(rows)); sys.exit(1)'
# --- gate: the tree stays establishment-agnostic (ADR-0013, generalized from the one-code grep) ---
# Shape-based, not literal: the pilot's residue was a hardcoded `deis.py` call in CI's fixture and steering
# examples in docs. A literal grep on one clinic's code is the pilot's number all over again — the next
# clinic's code passes it. The SHAPE is the contract: no tracked file may hand deis.py a DEIS
# code. Only the register CSVs are excluded — they ARE the codes, by design — and dated history
# is scrubbed (slice 5), so nothing else gets a pass. git grep, not grep -r: tracked files only,
# so a developer's sites/<slug>/site.sh (untracked, generated) never trips it. The shape lives in
# ONE exported variable so the self-test below red-tests the same bytes this check runs — and the
# planted literal is ASSEMBLED at run time (%s + a fabricated code), because a literal here would
# itself be a tracked hit and the gate would trip on its own detector test forever.
AGNOSTIC_SHAPE='deis\.py [0-9]{4,6}'
export AGNOSTIC_SHAPE
check bash -c '
  hits=$(git grep -nE "$AGNOSTIC_SHAPE" -- . ":(exclude)sites/establecimientos-deis-*.csv" 2>/dev/null || true)
  [ -z "$hits" ] || { printf "establishment-agnostic gate — tracked files naming a DEIS code:\n%s\n" "$hits" >&2; exit 1; }'
# The negative half: the detector must detect, and must not fire on a clean line. Same shape
# variable, fabricated corpus, run-time-assembled plant.
check bash -c '
  tmp=$(mktemp); trap "rm -f $tmp" EXIT
  printf "run: scripts/deis.py %s --new x\nclean line, no code\n" 999999 > "$tmp"
  grep -nE "$AGNOSTIC_SHAPE" "$tmp" >/dev/null || { echo "agnostic detector: planted literal went undetected" >&2; exit 1; }
  printf "nothing here at all\n" | grep -nE "$AGNOSTIC_SHAPE" >/dev/null && { echo "agnostic detector: false positive on a clean line" >&2; exit 1; }
  exit 0'

# --- gate: sites/ ships the register and NOTHING else ------------------------------------
# The register CSVs are tracked under sites/ beside generated site trees that .gitignore keeps
# out by DIRECTORY — which stops nothing from `git add -f sites/x/site.sh` landing a real site
# record (identity, teams, folders, ACL — a clinic's whole shape) in the public repo. The list
# comes from git ls-files (sites/-PREFIXED paths), piped; the filter is a function so the
# self-test exercises the same bytes. The register is a FLOOR, not an option: an empty listing
# (register deleted, glob renamed) is the empty-glob-goes-green class — red, not green.
sites_register_only() {  # sites/-prefixed file list on stdin; exit 0 = only register CSVs, >=1
  local list n bad
  # Captured ONCE: two greps over one stdin would race — the first consumes the stream and the
  # second reads an exhausted pipe, outputs nothing, and the intruder check goes green vacuously
  # (caught by sanity-running the fence against the real repo, not by review).
  list=$(cat)
  n=$(printf "%s\n" "$list" | grep -cE "^sites/establecimientos-deis-[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv$" || true)
  [ "$n" -ge 1 ] || { printf "no register CSV tracked under sites/ — the register is the floor\n" >&2; return 1; }
  bad=$(printf "%s\n" "$list" | grep -vE "^sites/establecimientos-deis-[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv$" || true)
  [ -z "$bad" ] || { printf "unexpected tracked files under sites/:\n%s\n" "$bad" >&2; return 1; }
}
export -f sites_register_only
check bash -c 'git ls-files sites/ | sites_register_only'
# Negative half, fabricated lists through the same function: a site.sh must be flagged, an
# empty listing must be flagged, the register alone must pass.
check bash -c '
  printf "sites/establecimientos-deis-2026-07-23.csv\nsites/x/site.sh\n" | sites_register_only \
    && { echo "sites gate: a tracked site.sh was not flagged" >&2; exit 1; }
  printf "" | sites_register_only && { echo "sites gate: an empty listing went green" >&2; exit 1; }
  printf "sites/establecimientos-deis-2026-07-23.csv\n" | sites_register_only'

# --- a21 (L5): the separate tiles server stays gone --------------------------------------------
# The grep is a21's own clause, with the pattern assembled without its literals
# ("nginx:alp""ine|TILES_""PORT|:80""84"): a21 covers scripts/ too, and a gate that spelled its
# own banned tokens would be its own hit. tiles.nginx.conf gone, no nginx pin, port or knob left
# anywhere the map used to need one.
check bash -c '
  test ! -e tiles.nginx.conf \
    && ! git grep -qE "nginx:alp""ine|TILES_""PORT|:80""84" -- .env.example compose.yaml host scripts provisioning'

# --- gate: the data manifest and the comuna reference describe each other ---------------------
# packages.json pins the masters; comunas-deis.csv is the coding authority the recipes validate
# against. One python block holds the validator ONCE and runs it on the real corpus AND on three
# fabricated defect corpora (single-sourced: the self-test exercises the same bytes the real check
# runs — slice 4's locked lesson). The row-count expectation is READ FROM THE MANIFEST, not
# restated: a future ODS refresh (a 347th comuna) is one manifest edit + one CSV regen, and this
# gate follows — never three uncoordinated literals.
check python3 -c '
import json, re, sys
def validate(rows, why, expect):
    if len(rows) != expect: print(why + ": " + str(len(rows)) + " rows, expected " + str(expect)); sys.exit(1)
    for cut, glosa in rows:
        if not re.fullmatch(r"[0-9]{5}", cut): print(why + ": CUT " + repr(cut) + " is not 5 digits"); sys.exit(1)
        if "\xa0" in glosa: print(why + ": glosa of " + cut + " carries a non-breaking space"); sys.exit(1)
    if not any(c == "99999" for c, _ in rows): print(why + ": the 99999/Ignorada sentinel row is gone"); sys.exit(1)
m = json.load(open("provisioning/data/packages.json"))
assert m["masters"], "no masters in the data manifest"
for x in m["masters"]:
    for k in ("id", "origin", "sha256", "records"):
        if not x.get(k): print("master " + x.get("id", "?") + ": missing " + k); sys.exit(1)
expect = m["comuna_reference"]["records"]
real = [l.rstrip("\n").split(",", 1) for l in open("provisioning/data/comunas-deis.csv", encoding="utf-8")][1:]
validate(real, "comunas-deis.csv", expect)
# The negative half — three corpora, one defect each, through the SAME validator:
try:
    validate([("1234", "Cuatro"), ("99999", "Ignorada"), ("12345", "Santiago")], "4-digit CUT", expect)
except SystemExit: pass
else: print("fabricated 4-digit corpus passed"); sys.exit(1)
try:
    validate([("99999", "Ignorada"), ("12345", "NBSP\xa0glosa")], "NBSP glosa", 2)
except SystemExit: pass
else: print("fabricated NBSP corpus passed"); sys.exit(1)
try:
    validate([("12345", "Santiago"), ("13101", "Providencia")], "missing sentinel", 2)
except SystemExit: pass
else: print("fabricated sentinel-less corpus passed"); sys.exit(1)
print("ok")'
# (comuna-package's self-test arm retired with the move: the import's idempotence stays
# armed by instalador's CLI datos arms - the recorded gap, the plan's Verification Notes)

# --- gate: the runbooks moved (D13) ---------------------------------------------------------
# The anchor contract (six heading slugs) and the §14/§11 CA-twin walkthrough live in
# instalador's gate now, read against aps/INSTALLER.md + aps/GUIA-CLINICA.md. gestion's
# copies are deleted with this slice; nothing here re-states them.

# --- gate: the suite's containers are aps-conecta-* (the AIO fork's patch 240) ----------------
# The fork renames its 19 sibling containers; the mastercontainer, the nextcloud-aio network and
# compose project and the nextcloud_aio_* volumes keep upstream's names. A sibling spelled the old way
# anywhere gestion talks to the suite misses it without a word: a `docker ps` filter that matches
# nothing reads as «not running», a prefix filter sees only the wizard. So no name, no prefix with the
# old hyphen and no glob of the old prefix survives but the mastercontainer's. git grep exits 1 on no
# match and 128 on error, so only a real search passes; [-*] keeps this line from matching itself.
# CHANGELOG and BUGS are history; the vendored tarballs are not text.
check bash -c 'out="$(git grep -nE "nextcloud-aio[-*]" -- . ":!CHANGELOG.md" ":!BUGS.md" ":!provisioning/apps")"; rc=$?; [ "$rc" -le 1 ] && ! printf "%s\n" "$out" | sed "s/nextcloud-aio-mastercontainer//g" | grep -E "nextcloud-aio[-*]"'

# --- gate: the release manifest's form — every pin present, every category counted -------------
check bash scripts/release-manifest.sh --validate
check bash scripts/release-manifest.sh --self-test

# --- the movers' hermetic self-tests retired with them (D2): standings, env.sh, usuarios and
# comuna-package answer from instalador's gate now; gestion's own arms follow (release-manifest).
# #197: the template ships no Nextcloud container and no caller restates its default or guards it
# (`:-` `-` `:?` `?`) — env.sh section 3 is the one place it is decided. git grep exits 1 on no
# match and 128 on error, so only a real "none found" passes (a tree without git is red, not green).
# The [R] keeps the pattern from matching this line itself.
check bash -c '! grep -q "^NC_CONTAINER=" .env.example && { git grep -qE "NC_CONTAINE[R]:?[?-]" -- . ":!scripts/env.sh"; [ $? -eq 1 ]; }'

echo "== desktop_workspace pin seat (hermetic — unpacks the vendored tarball + applies its patches) =="
# D2 (org plan Phase 8): the vendored app's pins live in gestion, not in upstream's
# absent CI. Needs node always; the PHP arm rides php when present (CI installs it).
if command -v node >/dev/null 2>&1; then
  if bash tests/desktop_workspace/run.sh; then echo "  ok:   desktop_workspace pins"; else echo "  FAIL: desktop_workspace pins"; fail=1; fi
else
  echo "  skipped: desktop_workspace pins (no node on this box)"
fi
echo "== self-tests (hermetic — no docker, no stack) =="
# The movers' self-tests (provisionador, host bundle, tiles, migrate-to-aio, env.sh,
# standings, usuarios, db-dump, uninstall) run in instalador's gate now — their code lives
# there. comuna-package's has no runner post-move: its comuna reference stays in gestion and
# the import's idempotence stays armed by the CLI's datos arms (the recorded gap, Verification
# Notes). gestion's remaining hermetic arms follow.

if [ "$fail" -eq 0 ]; then
  echo "PASS: local gate green"
  exit 0
else
  echo "FAIL: local gate has failures"
  exit 1
fi
