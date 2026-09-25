#!/usr/bin/env bash
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

# env.sh first — its own rule: anything that reads .env or runs `docker compose` sources it. This
# script now does both: the REF anchor below queries the running stack (`docker compose exec`) and
# needs SITE, and SITE_DEIS comes from the generated site file, sourced in the parent shell the
# same way seed.sh sources it (seed.sh:24). The shebang moved /bin/sh → bash for this; the systemd
# unit invokes the script by path, so the shebang governs and nothing else changes for the timer.
# shellcheck source=env.sh
. "$(dirname -- "$0")/env.sh"
require_site || exit 1
# shellcheck disable=SC1090  # the path is SITE, resolved at run time
. "sites/$SITE/site.sh"

DEST="${DEST:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/tiles/chile.pmtiles}"
# All of Chile, including Isla de Pascua (lon -109.4) and Juan Fernandez (-78.8). A bbox stopping at
# the mainland silently excludes two comunas that have health facilities, and including them costs
# about 5 MB because empty Pacific deduplicates away. Comuna-blind by design.
BBOX="${BBOX:--110.0,-56.0,-66.4,-17.5}"
THREADS="${THREADS:-8}"
# How far back to look for a published build before giving up.
DAYS="${DAYS:-10}"

# One point and one tile inside the territory, used to prove COVERAGE rather than shape. The anchor
# IS the establishment this stack serves — its DEIS point, read from territorio's own import
# (external_id 'deis:<SITE_DEIS>': the cut artifact's uid contract, apps/territorio
# datasets/_registry/sources.json). Not a hand-picked constant: the comuna-center pair this replaces was
# already one tile row off the comuna center it claimed to be, and the map exists so THIS
# establishment's territory is navigable.
#
# REF_LON/REF_LAT still override — CI, or a coordinate-less establishment (a comuna's cut drops
# them; the pilot's own cut has three). A missing point with no override is a LOUD failure, not a
# fallback: a REF that silently defaulted elsewhere would "verify" a bbox that may not contain
# the clinic this stack serves at all. The failure lands before any download, so the serving
# archive is never touched by it.
REF_Z="${REF_Z:-12}"
REF_LON="${REF_LON:-}"
REF_LAT="${REF_LAT:-}"
if [ -z "$REF_LON" ] || [ -z "$REF_LAT" ]; then
  # Posture-split probes (org L5-01): the compose read this script was born with is a permanent
  # red on every AIO clinic — no compose db exists there, so nothing ever pinned REF_LON/REF_LAT
  # and the monthly timer failed while MIGRATION.md listed it as a post-AIO gate. The AIO arm
  # uses the names migrate-to-aio.sh:207 pins (DB=nextcloud-aio-database, user oc_nextcloud,
  # database nextcloud_database); the detection is the docker-ps-by-name idiom install.sh,
  # smoke's check 1 and test.sh's gates share.
  psql_q() {  # SQL -> stdout, quiet
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud-aio-nextcloud; then
      docker exec nextcloud-aio-database psql -U oc_nextcloud -d nextcloud_database -Atc "$1" 2>/dev/null
    else
      docker compose exec -T db psql -U apsconecta -d apsconecta -Atc "$1" 2>/dev/null
    fi
  }
  # Probe with psql itself, not `exec db true`: a psql probe that answers distinguishes "stack
  # unreachable" from everything else, so the feature read below can only fail for data reasons
  # (no table, no row) — and both of those share one remedy, "import the comuna package first".
  if ! psql_q "SELECT 1" >/dev/null; then
    echo "refresh-basemap: cannot query the stack for the DEIS point — is it running?" >&2
    exit 1
  fi
  coords="$(psql_q \
    "SELECT geometry::json->'coordinates' FROM oc_territorio_feature WHERE external_id = 'deis:$SITE_DEIS' LIMIT 1" \
    || true)"
  # Matched on external_id, not a dataset slug: --dataset is operator input (the pilot's own live
  # import landed under a different slug than the registry's convention — measured on the live
  # stack), while the 'deis:' uid namespace is the cut artifact's contract. The same code in two
  # datasets is the same point either way.
  coords="${coords#[}"; coords="${coords%]}"
  case "$coords" in
    ''|*,*,*|*[!0-9.,-]*)
      echo "refresh-basemap: territorio has no Point for deis:$SITE_DEIS (got: '${coords:-nothing}')." >&2
      echo "  Import the comuna package first (scripts/comuna-package.sh), or pin the anchor:" >&2
      echo "    REF_LON=<lon> REF_LAT=<lat> $0" >&2
      exit 1 ;;
  esac
  REF_LON="${coords%%,*}"
  REF_LAT="${coords##*,}"
fi

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

# --- the serving arm (org L5-01): the archive is only the deliverable because something serves it.
# If the tiles container is running, prove the path a browser takes — a ranged GET must answer 206
# with bytes from the archive just installed (the same Range contract tiles.nginx.conf declares and
# test.sh's nginx arm asserts). If nothing serves on this host, say so loudly but do not fail: a
# dev box refreshing an archive it serves through a container it has not brought up yet is the
# supported case, and the unit's own contract is freshness.
TILES_PORT="${TILES_PORT:-8084}"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aps-conecta-tiles; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1023' \
    "http://localhost:${TILES_PORT}/chile.pmtiles" 2>/dev/null || echo 000)
  [ "$code" = "206" ] || {
    echo "refresh-basemap: the tiles container is running but a ranged GET answered HTTP ${code} (expected 206)" >&2
    echo "  the archive was installed; the serving path is broken — check docker logs aps-conecta-tiles" >&2
    exit 1
  }
  echo "refresh-basemap: serving arm green — ranged GET answered 206 from the new archive"
else
  echo "refresh-basemap: no tiles container running — archive refreshed, serving arm not exercised"
fi
