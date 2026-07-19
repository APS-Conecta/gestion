#!/usr/bin/env bash
# Office format + OSS-licence audit (Story 4.3) — the machine-checkable half of Epic 4.
# For the ACTIVE office backend it asserts:
#   (1) the six required formats can be EDITED — odt/docx (Writer), ods/xlsx (Calc), odp/pptx (Impress);
#   (2) the backend is OSS / self-hosted with NO paid licence.
# The per-format check reads the backend's OWN generated capability list (Collabora /hosting/discovery),
# never a hand-maintained table — so it can't drift from what the server actually serves
# (documenting-a-repo: prefer generated over hand-written).
#
# NOT covered here (no gate can): in-browser rendering, live convergence, cursor presence, and open/save
# FIDELITY are human/browser checks — see docs/ACCEPTANCE-EDITING.md.
set -euo pipefail

OCC="docker compose exec -T --user www-data nextcloud php occ"
OFFICE_PORT="${OFFICE_PORT:-9980}"

# An app is enabled iff its appconfig `enabled` value is "yes" (same test as office-smoke.sh).
enabled() { [ "$($OCC config:app:get "$1" enabled 2>/dev/null || true)" = "yes" ]; }

# The six formats we must be able to EDIT, as "mimetype|ext" pairs (odt/docx, ods/xlsx, odp/pptx).
FORMATS=(
  "application/vnd.oasis.opendocument.text|odt"
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document|docx"
  "application/vnd.oasis.opendocument.spreadsheet|ods"
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet|xlsx"
  "application/vnd.oasis.opendocument.presentation|odp"
  "application/vnd.openxmlformats-officedocument.presentationml.presentation|pptx"
)

rich=off; euro=off
enabled richdocuments && rich=on
enabled eurooffice     && euro=on

# AD-11: exactly one connector active.
if [ "$rich" = on ] && [ "$euro" = off ]; then
  echo "Active office backend: Collabora (richdocuments)"

  disc="$(curl -skf "https://localhost:${OFFICE_PORT}/hosting/discovery")" \
    || { echo "FAIL: could not fetch Collabora /hosting/discovery"; exit 1; }

  # (1) Per-format EDIT assertion, straight from the server's generated discovery.
  missing=0
  for pair in "${FORMATS[@]}"; do
    mime="${pair%%|*}"; ext="${pair##*|}"
    if printf '%s' "$disc" | python3 -c '
import sys, xml.etree.ElementTree as ET
doc = ET.fromstring(sys.stdin.read()); mime = sys.argv[1]
editable = any(a.get("name") == "edit"
               for app in doc.iter("app") if app.get("name") == mime
               for a in app.findall("action"))
sys.exit(0 if editable else 1)' "$mime"; then
      echo "  ✓ ${ext}  editable"
    else
      echo "  ✗ ${ext}  NOT editable (no <action name=\"edit\"> for ${mime})"; missing=1
    fi
  done
  [ "$missing" = 0 ] || { echo "FAIL: one or more required formats are not editable"; exit 1; }

  # (2) OSS / no-paid-licence audit. The free build self-identifies as the "Development Edition"
  # (the paid product drops those words); the image is the OSS collabora/code.
  product="$(curl -skf "https://localhost:${OFFICE_PORT}/hosting/capabilities" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("productName",""))' 2>/dev/null || true)"
  case "$product" in
    *"Development Edition"*) echo "  ✓ OSS build: ${product} (Collabora CODE, AGPL — no paid licence)";;
    "") echo "FAIL: could not read productName from /hosting/capabilities"; exit 1;;
    *)  echo "FAIL: productName '${product}' is not the free CODE 'Development Edition' build"; exit 1;;
  esac

  echo "PASS: Collabora — 6/6 formats editable + OSS build, no paid licence"

elif [ "$euro" = on ] && [ "$rich" = off ]; then
  echo "Active office backend: Euro-Office (eurooffice)"
  # Euro-Office (OnlyOffice-derived, AGPL) exposes no WOPI discovery to parse per-format, so the
  # authoritative per-format EDIT proof for this backend is the human acceptance run
  # (docs/ACCEPTANCE-EDITING.md). Here we assert only what IS machine-checkable: server health + OSS image.
  curl -sf "http://localhost:${OFFICE_PORT}/healthcheck" >/dev/null \
    || { echo "FAIL: Euro-Office /healthcheck not reachable"; exit 1; }
  img="$(docker inspect apsconecta-gestion-eurooffice-1 --format '{{.Config.Image}}' 2>/dev/null || true)"
  case "$img" in
    *euro-office/documentserver*) echo "  ✓ OSS image: ${img} (Euro-Office, AGPL — no paid licence)";;
    *) echo "FAIL: unexpected Euro-Office image '${img}'"; exit 1;;
  esac
  echo "PASS: Euro-Office — server healthy + OSS image (per-format editing: see docs/ACCEPTANCE-EDITING.md)"

else
  echo "FAIL: expected exactly ONE office connector enabled (AD-11); got richdocuments=${rich}, eurooffice=${euro}"
  exit 1
fi
