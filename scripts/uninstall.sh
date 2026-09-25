#!/usr/bin/env bash
# scripts/uninstall.sh — tear the stack down FOR REAL, with the two things `make down` never did:
# proof the data survives somewhere else (a verified dump) and a typed confirmation before the
# irreversible step (install.sh's #85 comment says it "never DELETES" — this is the command that
# finally does, on purpose).
#
# SCRIPT vs RUNBOOK (docs/MIGRATION.md): this owns everything the REPO installed — the compose
# project, its volumes, generated artifacts, the basemap timer. Host residue the repo never
# touched (tailscale serve routes, /root/backups .baks, transcript JSONLs, where the preservation
# copy goes) is the runbook's checklist, printed at the end.
#
# THE OVERRIDE IS DELIBERATELY EXPENSIVE: volume deletion without a verified dump is allowed only
# by typing a full sentence. Same doctrine as env-init.sh's "there is no --force" — refusal with
# a named, unambiguous way out.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF_TEST=0; REMOVE_IMAGES=0
for arg in "$@"; do   # "$@" is zero words with no args — the ${@:-} shape would pass ONE empty word
  case "$arg" in
    --self-test) SELF_TEST=1 ;;
    --remove-images) REMOVE_IMAGES=1 ;;
    *) echo "uninstall: unknown flag $arg" >&2; exit 2 ;;
  esac
done

# --- posture gate (org L5-04): this is the COMPOSE uninstaller ------------------------------------------------
# `docker compose down -v` below tears compose resources; on a migrated (AIO) host it would
# no-op while every clean-slate detector reports green by absence — the report lying about a
# live clinic whose data sits in nextcloud_aio_* volumes. Refuse instead: the AIO teardown
# is a different runbook (docs/MIGRATION.md), never this script.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud-aio-nextcloud; then
  echo "uninstall: the AIO stack is running — this tool tears down the COMPOSE world only." >&2
  echo "  compose down -v would touch nothing while the report read green; the clinic's data" >&2
  echo "  lives in nextcloud_aio_* volumes. Follow docs/MIGRATION.md for the AIO teardown." >&2
  exit 1
fi

# --- the clean-slate detectors, parameterized so --self-test can fabricate each red -------------
cs_no_project()  {  # [project] — clean = the compose project is gone. json+python3, not
  # `--format '{{.Name}}'`: docker 29's compose ls stopped parsing go-templates (measured:
  # "format value could not be parsed"), and the json form it still accepts is the contract.
  ! docker compose ls -a --format json 2>/dev/null \
    | python3 -c 'import json, sys; sys.exit(0 if any(p.get("Name") == sys.argv[1] for p in json.load(sys.stdin)) else 1)' "${1:-apsconecta-gestion}"
}
cs_no_volume()   { ! docker volume ls --format '{{.Name}}' | grep -qx "$1"; }
cs_no_network()  { ! docker network ls --format '{{.Name}}' | grep -qx "$1"; }
cs_no_listener() { ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print $4}' | grep -qE "[:.]$1$"; }
cs_no_file()     { [ ! -e "$1" ]; }
cs_sites_clean() {  # sites/ holds register CSVs and nothing else (generated trees gone)
  local bad; bad=$(ls -A sites/ 2>/dev/null | grep -vE '^establecimientos-deis-[0-9]{4}-[0-9]{2}-[0-9]{2}\.csv$' || true)
  [ -z "$bad" ]
}
cs_can_probe_listeners() {  # #143: "could not ask" is not "not present" — with neither ss nor
  command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1  # netstat on the host, the
}                                                                # listener check cannot run — red, not green

if [ "$SELF_TEST" = 1 ]; then
  # Fabricate every bad state the report can name — under SELF-TEST-ONLY names that cannot
  # collide with the real project's resources. The real names (apsconecta-gestion_*) are only
  # ever passed to these detectors by the report, after down -v removed them; fabricating under
  # the real names would mean the cleanup rm targets the real volume on any host where it exists
  # — a self-test that destroys data is worse than no self-test (caught in verification).
  docker volume create apsconecta-selftest-volume >/dev/null
  cs_no_volume apsconecta-selftest-volume && { echo "self-test: volume detector green on a live volume" >&2; exit 1; }
  docker volume rm apsconecta-selftest-volume >/dev/null
  docker network create apsconecta-selftest-network >/dev/null
  cs_no_network apsconecta-selftest-network && { echo "self-test: network detector green on a live network" >&2; exit 1; }
  docker network rm apsconecta-selftest-network >/dev/null
  # A throwaway compose project under a fabricated name: create (never up) is enough for
  # `compose ls -a` to see it, and down removes exactly what create made.
  proj=$(mktemp -d); trap 'rm -rf "$proj"' EXIT
  printf 'services:\n  x:\n    image: hello-world\n' > "$proj/compose.yaml"
  docker compose -p apsconecta-selftest -f "$proj/compose.yaml" create >/dev/null 2>&1
  cs_no_project apsconecta-selftest && { echo "self-test: project detector green on a live project" >&2; exit 1; }
  docker compose -p apsconecta-selftest -f "$proj/compose.yaml" down -v >/dev/null 2>&1
  cs_no_project apsconecta-selftest || { echo "self-test: project detector still red after down" >&2; exit 1; }
  # The file-detector red is fabricated under a SELF-TEST-ONLY name, never the real site.css
  # path the report checks: this self-test runs on warm dev trees (and CI's cleanboot) where the
  # generated site.css genuinely exists, and a `touch` + `rm -f` on the real path deletes a live
  # artifact — the next seed regenerates it, writes a WRITES line, and reddens seed-idempotent
  # (caught on the live tree). Same doctrine as the volume/network fabrications above.
  touch themes/apsconecta/core/css/selftest-site.css 2>/dev/null || { mkdir -p themes/apsconecta/core/css && touch themes/apsconecta/core/css/selftest-site.css; }
  cs_no_file themes/apsconecta/core/css/selftest-site.css && { echo "self-test: file detector green on an existing file" >&2; exit 1; }
  rm -f themes/apsconecta/core/css/selftest-site.css
  mkdir -p sites/selftest
  cs_sites_clean && { echo "self-test: sites detector green on a stray tree" >&2; exit 1; }
  rmdir sites/selftest
  listener_port=""; for p in 18180 28180 38180; do cs_no_listener "$p" && listener_port="$p" && break; done
  [ -n "$listener_port" ] || { echo "self-test: no free port to fabricate a listener on" >&2; exit 1; }
  # 127.0.0.1 + an EMPTY directory: the fabricated listener must serve nothing, never the repo
  # root (a self-test that briefly publishes .env is a self-inflicted breach).
  srv=$(mktemp -d)
  python3 -m http.server "$listener_port" --bind 127.0.0.1 --directory "$srv" >/dev/null 2>&1 & listener_pid=$!
  sleep 1; cs_no_listener "$listener_port" && { echo "self-test: listener detector green on a live listener" >&2; kill "$listener_pid"; exit 1; }
  kill "$listener_pid" 2>/dev/null || true; rm -rf "$srv"
  # The cannot-ask state (#143): with neither ss nor netstat reachable, the listener-probe
  # detector must go red — fabricated under a stripped PATH (a detector that reads "ok"
  # without a probe tool reports nothing on the host that needs it most).
  PATH="/nonexistent" cs_can_probe_listeners && { echo "self-test: listener-probe detector green with no probe tool on PATH" >&2; exit 1; }
  echo "uninstall self-test: every clean-slate detector goes red on its fabricated bad state"; exit 0
fi

. "$HERE/env.sh"   # cd repo root, .env the compose way, occ
require_site || exit 1
# shellcheck disable=SC1090
. "sites/$SITE/site.sh"

echo "uninstall: this destroys the stack serving $SITE (DEIS $SITE_DEIS, $SITE_COMUNA)."
echo "             volumes apsconecta-gestion_{postgres_data,nextcloud_data} — the database and the"
echo "             data dir — are DELETED. \`make down\` keeps them; this does not."

# --- preservation: site.sh IS the record deis.py cannot regenerate -----------------------------
preserved="$SITE-preserved-$(date +%Y%m%d-%H%M%S)"
cp -a "sites/$SITE" "$preserved"
echo "preserved: $preserved/ (move it off this host — MIGRATION.md) — ${#SITE_TEAMS[@]} teams, ${#SITE_FOLDERS[@]} folders, ${#SITE_ACL[@]} ACL rows"

# --- the verified dump, or an expensive explicit refusal --------------------------------------
if ! bash "$HERE/db-dump.sh"; then
  echo "" >&2
  echo "uninstall: the verified dump FAILED — not proceeding to volume deletion." >&2
  echo "  If you mean to destroy the data anyway, type: destroy without a dump" >&2
  printf '  > ' >&2; IFS= read -r answer
  [ "$answer" = "destroy without a dump" ] || { echo "uninstall: keeping the stack. Nothing was done." >&2; exit 1; }
fi

# --- the typed confirmation (the slug, exactly) ------------------------------------------------
printf 'Type the site slug ("%s") to tear the stack down: ' "$SITE"
IFS= read -r answer
[ "$answer" = "$SITE" ] || { echo "uninstall: "$answer" is not "$SITE" — nothing was done." >&2; exit 1; }

if [ "$REMOVE_IMAGES" = 1 ]; then
  docker compose down -v --rmi all --remove-orphans
else
  docker compose down -v --remove-orphans
fi

# --- generated artifacts (the preservation copy above is outside sites/) ----------------------
rm -rf "sites/$SITE"
rm -f themes/apsconecta/core/css/site.css .install.log

# --- the basemap timer, only if it points into THIS tree ---------------------------------------
if command -v systemctl >/dev/null 2>&1 && systemctl cat territorio-basemap.service >/dev/null 2>&1 \
   && systemctl cat territorio-basemap.service | grep -q "$PWD"; then
  if systemctl disable --now territorio-basemap.timer 2>/dev/null; then
    echo "uninstall: territorio-basemap.timer disabled (its ExecStart pointed into this tree)"
  else
    echo "uninstall: territorio-basemap.timer points into this tree but could not be disabled — run as root:"
    echo "  systemctl disable --now territorio-basemap.timer"
  fi
else
  echo "uninstall: no territorio-basemap timer pointing here — nothing to disable"
fi

# --- .env: the only copy of the secrets — guidance, not deletion ------------------------------
if [ -f .env ]; then
  echo "note: .env still holds this install's only secrets. Rotate anything that used"
  echo "      them, then: rm .env  (MIGRATION.md walks the order.)"
fi

# --- the clean-slate report ---------------------------------------------------------------------
fail=0
report() { if "$@"; then echo "  ok:   $*"; else echo "  LEFT: $*"; fail=1; fi; }
report cs_no_project
report cs_no_volume apsconecta-gestion_postgres_data
report cs_no_volume apsconecta-gestion_nextcloud_data
report cs_no_network apsconecta-gestion_default
report cs_can_probe_listeners
for p in "${HTTP_PORT:-8180}" "${OFFICE_PORT:-9980}" "${TILES_PORT:-8084}"; do report cs_no_listener "$p"; done
report cs_sites_clean
report cs_no_file themes/apsconecta/core/css/site.css
report cs_no_file .install.log
report cs_no_file .env   # LEFT by design: the note above is the remedy — the report is honest, not green
if [ "$fail" -eq 0 ]; then
  echo "CLEAN SLATE: nothing this repo installed is left."
else
  echo "CLEAN SLATE INCOMPLETE — the LEFT lines above remain."
fi
echo ""
echo "Runbook residue this script cannot see (docs/MIGRATION.md):"
echo "  - tailscale serve unsets (ports 10001/10008/10009)"
echo "  - /root/backups .bak rotation + deletion"
echo "  - transcript JSONLs (the 2026-09-18 session files)"
echo "  - move $preserved/ off this host"
exit "$fail"
