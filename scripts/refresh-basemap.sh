#!/usr/bin/env bash
# Refresh the Protomaps basemap archive the suite serves at /tiles/.
#
# Territorio's ADR-0019 has the why. The two things that make this a script rather than a cron
# one-liner:
#
#   1. THE SOURCE URL CANNOT BE PINNED. Protomaps publishes dated planet builds and removes the old
#      ones — a build nine days old already answered 404 when this was written. So the date is
#      discovered, newest first, and a hardcoded one would rot silently.
#   2. THE ARTEFACT IS VERIFIED, NOT THE EXIT CODE. A truncated download, an error page saved under
#      the right name, or a half-written file all leave a zero exit somewhere. The new archive has
#      to open, say the right zoom range, and answer for a tile before it is allowed to replace a
#      working one.
#
# Writes to a temporary file and moves it into place only once it has passed, so a failed run leaves
# the serving archive untouched. A stale basemap is a missing street; a broken one is a blank map.
#
# It reads nothing of the install it serves — no .env, no site, no running suite — because it runs
# before any of them exist: the install's step 4 builds the map before anyone chooses a centre (R47).
set -eu

DEST="${DEST:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/tiles/chile.pmtiles}"
# All of Chile, including Isla de Pascua (lon -109.4) and Juan Fernandez (-78.8). A bbox stopping at
# the mainland silently excludes two comunas that have health facilities, and including them costs
# about 5 MB because empty Pacific deduplicates away. Comuna-blind by design.
BBOX="${BBOX:--110.0,-56.0,-66.4,-17.5}"
THREADS="${THREADS:-8}"
# How far back to look for a published build before giving up.
DAYS="${DAYS:-10}"

# Coverage, proven at fixed points of the country rather than at the clinic's: the archive exists
# before any centre is chosen, so no anchor may depend on one (85ed2f0 read the establishment's
# point from territorio's database, which made the build wait for a seeded suite — R47). ANCHORS are
# the corners of what BBOX promises — Santiago, Hanga Roa on Isla de Pascua, Punta Arenas — and the
# header bounds must contain every one. The tile read stays on the mainland, Santiago at z12: an
# island tile may hold too few bytes to prove anything. REF_LON/REF_LAT move that read; the chosen
# centre's own point is checked where it is chosen, at Centro.
ANCHORS="-70.6506,-33.4378 -109.4333,-27.1500 -70.9171,-53.1638"
REF_Z="${REF_Z:-12}"
REF_LON="${REF_LON:--70.6506}"
REF_LAT="${REF_LAT:--33.4378}"

# X/Y from the anchor, not from the environment: the verify contract below checks CONTAINMENT for
# the point and BYTES for the tile, so the tile must agree with the point — deriving it removes a
# constant that could drift from the pair it has to match. python3, not awk: this host's awk lacks
# tan (measured — sin/cos/atan2 answer, tan does not), and python3 is already a host dependency
# (scripts/deis.py, test.sh's gates). At z12 the derivation and the hand-picked constants this
# replaces disagree by a tile row (2453 vs 2452 at the same anchor) — exactly the hand-drift the
# computation removes; both tiles sit inside the bbox.
read -r REF_X REF_Y <<< "$(python3 -c '
import math, sys
lon, lat, z = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
n = 1 << z
print(int((lon + 180) / 360 * n), int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n))
' "$REF_LON" "$REF_LAT" "$REF_Z")"
[ -n "${REF_Y:-}" ] || { echo "refresh-basemap: no tile derived from $REF_LON,$REF_LAT" >&2; exit 1; }

command -v pmtiles >/dev/null 2>&1 || { echo "refresh-basemap: pmtiles CLI not on PATH" >&2; exit 1; }

build=""
day=0
while [ "$day" -le "$DAYS" ]; do
  candidate=$(date -u -d "-${day} days" +%Y%m%d)
  url="https://build.protomaps.com/${candidate}.pmtiles"
  if curl -fsS -I "$url" >/dev/null 2>&1; then
    build="$url"
    echo "refresh-basemap: using $candidate"
    break
  fi
  day=$((day + 1))
done
[ -n "$build" ] && : || { echo "refresh-basemap: no published build in the last $DAYS days" >&2; exit 1; }

tmp="${DEST}.new.$$"
trap 'rm -f "$tmp"' EXIT INT TERM
mkdir -p "$(dirname "$DEST")"

pmtiles extract "$build" "$tmp" --bbox="$BBOX" --download-threads="$THREADS"

# --- the artefact, not the exit code ---

# It has to be a PMTiles archive and not whatever else can land in a file.
magic=$(dd if="$tmp" bs=1 count=7 2>/dev/null || true)
[ "$magic" = "PMTiles" ] || { echo "refresh-basemap: $tmp does not start with the PMTiles magic" >&2; exit 1; }

# It has to describe the pyramid we asked for. `pmtiles show` reads the header and directory, so
# this also proves the directory survived the download.
header=$(pmtiles show "$tmp")
echo "$header" | /usr/bin/grep -q "max zoom: 15" || { echo "refresh-basemap: unexpected zoom range:" >&2; echo "$header" >&2; exit 1; }

# It has to declare bounds that CONTAIN the territory. A correct-looking archive of the wrong
# region passes every check above: right magic, right zoom range, right size.
bounds=$(echo "$header" | sed -n 's/^bounds: (long: \([-0-9.]*\), lat: \([-0-9.]*\)) (long: \([-0-9.]*\), lat: \([-0-9.]*\)).*/\1 \2 \3 \4/p')
[ -n "$bounds" ] || { echo "refresh-basemap: could not read bounds from the header" >&2; exit 1; }
for point in $ANCHORS "$REF_LON,$REF_LAT"; do
  echo "$bounds" | awk -v lon="${point%,*}" -v lat="${point#*,}" \
    '{ exit !($1 <= lon && lon <= $3 && $2 <= lat && lat <= $4) }' \
    || { echo "refresh-basemap: bounds ($bounds) do not contain $point" >&2; exit 1; }
done

# And it has to actually answer, with BYTES, for a tile a browser will ask for. An archive can have
# a valid header, the right bounds and an empty body.
#
# The byte count is the whole check and not decoration: `pmtiles tile` exits 0 and prints nothing
# for a tile it does not hold, so the obvious `pmtiles tile ... >/dev/null || fail` form can never
# fail. Measured while writing this — an archive of Amsterdam passed that form for a tile over
# Santiago, which is exactly the wrong-region case the bounds check above now catches too.
tile_bytes=$(pmtiles tile "$tmp" "$REF_Z" "$REF_X" "$REF_Y" 2>/dev/null | wc -c)
[ "$tile_bytes" -gt 1000 ] || {
  echo "refresh-basemap: tile $REF_Z/$REF_X/$REF_Y came back as $tile_bytes bytes" >&2; exit 1; }

size=$(wc -c < "$tmp")
[ "$size" -gt 500000000 ] || { echo "refresh-basemap: $size bytes is too small for this bbox" >&2; exit 1; }

# Same filesystem, so this is atomic: a reader either sees the whole old file or the whole new one.
mv "$tmp" "$DEST"
trap - EXIT INT TERM
chmod 644 "$DEST"
echo "refresh-basemap: $DEST is now $size bytes"

