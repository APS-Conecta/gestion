#!/bin/sh
# Refresh the Protomaps basemap archive the `tiles` service serves.
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
set -eu

DEST="${DEST:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/tiles/chile.pmtiles}"
# All of Chile, including Isla de Pascua (lon -109.4) and Juan Fernandez (-78.8). A bbox stopping at
# the mainland silently excludes two comunas that have health facilities, and including them costs
# about 5 MB because empty Pacific deduplicates away.
BBOX="${BBOX:--110.0,-56.0,-66.4,-17.5}"
THREADS="${THREADS:-8}"
# How far back to look for a published build before giving up.
DAYS="${DAYS:-10}"

# One point and one tile inside the territory, used to prove COVERAGE rather than shape. Defaults
# are La Florida, the comuna this stack was first built for; a bbox change should move these with it.
REF_LON="${REF_LON:--70.58}"
REF_LAT="${REF_LAT:--33.52}"
REF_Z="${REF_Z:-12}"
REF_X="${REF_X:-1244}"
REF_Y="${REF_Y:-2452}"

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
echo "$bounds" | awk -v lon="$REF_LON" -v lat="$REF_LAT" \
  '{ exit !($1 <= lon && lon <= $3 && $2 <= lat && lat <= $4) }' \
  || { echo "refresh-basemap: bounds ($bounds) do not contain $REF_LON,$REF_LAT" >&2; exit 1; }

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
