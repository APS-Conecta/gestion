#!/usr/bin/env bash
# scripts/comuna-package.sh — cut one comuna's data packages out of the national masters.
#
# CUT-ON-DEMAND: the masters are national (hundreds of MB, refreshed upstream), the cut is
# seconds, and one install needs exactly one comuna. The manifest (provisioning/data/packages.json)
# pins the masters by sha256 — a release certifies the bytes it certified — and a moved master
# fails the fetch-verify LOUDLY rather than silently cutting different data (the re-record is an
# edit, the drift is the report).
#
# NO ARG = THE INSTALL'S OWN COMUNA: sites/<slug>/site.sh carries SITE_COMUNA_CUT (the slice-1
# seam), so on an installed host the script with no argument cuts THIS clinic's comuna. An explicit
# CUT overrides — the pilot's migration runbook passes one for the record, CI or a dev box passes
# one to test a different comuna.
set -eu

. "$(dirname -- "$0")/env.sh"
DATA="provisioning/data"

cut_of() {  # [ref] CUT — membership + comuna-ness; prints the glosa
  local ref="$DATA/comunas-deis.csv"; [ $# -gt 1 ] && { ref="$1"; shift; }
  local row
  row=$(awk -F, -v c="$1" 'NR>1 && $1==c {print $2; exit}' "$ref")
  [ -n "$row" ] || { echo "comuna-package: CUT $1 is not in the DEIS comuna reference ($ref)" >&2; return 1; }
  [ "$1" != "99999" ] || { echo "comuna-package: 99999 is DEIS's 'Ignorada' (unknown comuna), not a comuna" >&2; return 1; }
  printf '%s' "$row"
}

if [ "${1:-}" = "--self-test" ]; then
  # Against the REAL reference — same bytes the real path reads, no fabrication needed:
  # a valid CUT resolves, the sentinel is refused, a non-member is refused.
  cut_of 01101 >/dev/null || { echo "self-test: a valid CUT failed membership" >&2; exit 1; }
  cut_of 99999 >/dev/null 2>&1 && { echo "self-test: the sentinel was not refused" >&2; exit 1; }
  cut_of 12345 >/dev/null 2>&1 && { echo "self-test: a non-member CUT was accepted" >&2; exit 1; }
  echo "comuna-package self-test: membership, sentinel and non-member all behave"; exit 0
fi

CUT="${1:-}"
if [ -z "$CUT" ]; then
  require_site || exit 1
  # shellcheck disable=SC1090
  . "sites/$SITE/site.sh"
  CUT="${SITE_COMUNA_CUT:-}"
fi
[ -n "$CUT" ] || { echo "usage: $0 <CUT>   (or no argument, on an installed host: the site file's own CUT)" >&2; exit 2; }
GLOSA="$(cut_of "$CUT")"
echo "comuna-package: CUT $CUT — $GLOSA"

command -v ogr2ogr >/dev/null 2>&1 || { echo "comuna-package: ogr2ogr not on PATH — install gdal-bin (once per host; the UV master is a .shp)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "comuna-package: python3 required" >&2; exit 1; }

# The work dir. Default: a mktemp dir whose trap cleans the partial fetches on failure — on
# success the trap comes OFF at the end so the cuts outlive the child ("import them, then
# remove"). WORK_DIR set: the work dir is created INSIDE it from the start and the trap is
# skipped entirely — an explicit WORK_DIR is the operator's keep-them mode, and the contract
# the installer's datos arm (Phase 21) passes so its docker cp knows exactly where the cuts land.
WORK_DIR="${WORK_DIR:-}"
if [ -n "$WORK_DIR" ]; then
  mkdir -p "$WORK_DIR"
  work="$WORK_DIR/comuna-package.$$"
  mkdir "$work"
else
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT INT TERM
fi
fetch_verify() {  # ID URL SHA256 DEST
  curl -fL --max-time 600 -o "$4" "$2" \
    || { echo "comuna-package: fetching $1 failed — is the master still at its recorded URL? (a moved master is re-recorded by edit, never silently cut)" >&2; exit 1; }
  echo "$3  $4" | sha256sum --check --status \
    || { echo "comuna-package: $1's bytes do not match the manifest sha256 — the master moved; re-record it" >&2; exit 1; }
}
cut_count() {  # FILE MIN LABEL — the drift-exit: an empty cut is loud, never a silent green
  local n; n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["features"]))' "$1")
  [ "$n" -ge "$2" ] || { echo "comuna-package: $3 cut to $n features — too few (expected at least $2); the selector or the master is wrong, and this stops BEFORE any import is suggested" >&2; exit 1; }
  echo "$n"
}

# --- recipe 1: the UV cadastre ------------------------------------------------------------
# sha/URL/records read from the manifest at run time, not restated here (single source).
uv_sha=$(python3 -c 'import json; print([m for m in json.load(open("provisioning/data/packages.json"))["masters"] if m["id"]=="unidades-vecinales-2024"][0]["sha256"])')
uv_url=$(python3 -c 'import json; print([m for m in json.load(open("provisioning/data/packages.json"))["masters"] if m["id"]=="unidades-vecinales-2024"][0]["origin"])')
fetch_verify unidades-vecinales-2024 "$uv_url" "$uv_sha" "$work/uv.zip"
unzip -oq "$work/uv.zip" -d "$work/uv"   # the .shp inside; ogr2ogr converts (comuna-cut.php's own tool)
shp=$(find "$work/uv" -name '*.shp' | head -1)
ogr2ogr -f GeoJSON "$work/uv-national.geojson" "$shp"
python3 - "$work/uv-national.geojson" "$work/uv-$CUT.geojson" "$CUT" <<'PY'
import json, sys
src, dst, cut = sys.argv[1], sys.argv[2], sys.argv[3]
national = json.load(open(src, encoding="utf-8"))
# The import's property contract (the recipe's transform, and the measured reason the first cut
# died at "El feature 1 no tiene nombre"): uid from the official t_id_uv_ca, name from t_uv_nom
# (bare UV numbers — source data), the division_territorial/unidad_vecinal taxonomy pair. Raw
# t_* properties stay OUT: territorio maps what it knows, and an unmapped name aborts the import.
kept = []
for f in national["features"]:
    p = f["properties"]
    if p.get("t_com", "").strip().zfill(5) != cut:
        continue
    kept.append({"type": "Feature", "geometry": f["geometry"],
                 "properties": {"uid": p["t_id_uv_ca"], "name": p.get("t_uv_nom", ""),
                                 "category": "division_territorial",
                                 "subcategory": "unidad_vecinal"}})
out = {"type": "FeatureCollection", "comuna": cut,   # the collection-level claim: arms the import door
       "features": kept}
json.dump(out, open(dst, "w", encoding="utf-8"))
PY
uv_n=$(cut_count "$work/uv-$CUT.geojson" 1 "the UV cut")

# --- recipe 2: the DEIS establishments ----------------------------------------------------
deis_sha=$(python3 -c 'import json; print([m for m in json.load(open("provisioning/data/packages.json"))["masters"] if m["id"]=="minsal-deis-establecimientos"][0]["sha256"])')
deis_url=$(python3 -c 'import json; print([m for m in json.load(open("provisioning/data/packages.json"))["masters"] if m["id"]=="minsal-deis-establecimientos"][0]["origin"])')
fetch_verify minsal-deis-establecimientos "$deis_url" "$deis_sha" "$work/deis.csv"
python3 - "$work/deis.csv" "$work/deis-establecimientos-$CUT.geojson" "$CUT" <<'PY'
import csv, json, sys
src, dst, cut = sys.argv[1], sys.argv[2], sys.argv[3]
# FORMAT TRAP (measured at implement, recorded in the manifest): the DEIS dump is SEMICOLON-
# delimited, and TipoEstablecimientoGlosa writes FULL phrases ('Centro de Salud Familiar (CESFAM)')
# — the subcategory map matches substrings, never bare siglas.
def subcat(glosa):
    g = (glosa or "").upper()
    if "CESFAM" in g: return "cesfam"
    if "SAPU" in g: return "sapu"
    return "establecimiento"
kept = []
for r in csv.DictReader(open(src, encoding="utf-8-sig"), delimiter=";"):
    if r.get("ComunaCodigo", "").strip().zfill(5) != cut:
        continue
    lat, lon = (r.get("Latitud") or "").strip(), (r.get("Longitud") or "").strip()
    if not lat or not lon:
        continue  # a Point needs coordinates; the pilot's own cut drops 3 of 47 this way (sources.json:408)
    kept.append({
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [float(lon), float(lat)]},
        "properties": {
            "uid": "deis:" + r["EstablecimientoCodigo"],
            "name": r["EstablecimientoGlosa"],
            "category": "salud",
            "subcategory": subcat(r.get("TipoEstablecimientoGlosa", "")),
            "address": " ".join(x.strip() for x in (r.get("TipoViaGlosa", ""), r.get("NombreVia", ""), r.get("Numero", "")) if x and x.strip()),
        },
    })
json.dump({"type": "FeatureCollection", "comuna": cut, "features": kept},
          open(dst, "w", encoding="utf-8"))
PY
deis_n=$(cut_count "$work/deis-establecimientos-$CUT.geojson" 1 "the DEIS cut")

# Success: the cuts outlive this script — the import commands below are for a human to run against
# them, so the cleanup trap comes OFF here (a failure above still cleans its partial fetches; a
# successful cut is the operator's to import and then remove, as the closing line says).
trap - EXIT INT TERM

echo "comuna-package: CUT $CUT — $uv_n unidades vecinales, $deis_n establecimientos; the cuts are in $work (import them, then remove):"
echo "  occ territorio:import $work/uv-$CUT.geojson --dataset=unidades-vecinales --label='Unidades Vecinales'"
echo "  occ territorio:import $work/deis-establecimientos-$CUT.geojson --dataset=deis-establecimientos"