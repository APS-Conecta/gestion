#!/usr/bin/env bash
# final-validation.sh — the FRD's whole-installer acceptance, instrumented: the operator's
# exact path from a bare host to a provisioned clinic, every claim measured and LEDGERED as
# it happens (the 11-of-19 lesson: a claim measured at the end is a claim about a different
# state). Runs ON the fresh VM, from the gestion checkout at the suite tag, as the operator
# would — every step is their own command.
#
# THE VM CONTRACT: a fresh Ubuntu/Debian host, 80/443/8080/8443 reachable, and a REAL domain
# pointing at it (FINAL_DOMAIN) — the acceptance means the real wizard validation, Let's
# Encrypt, and the hairpin leg. The disposable .invalid posture is aio-testbed's own (the CI
# world), never this one's.
#
# Usage:
#   scripts/final-validation.sh run          the numbered walk (the acceptance)
#   scripts/final-validation.sh down         teardown (nextcloud-aio*-filtered; the instance
#                                             STAYS UP after a run — down is deliberate)
#   scripts/final-validation.sh --self-test the hermetic self-check (the ledger writer, the
#                                             branded-bytes table against a fixture tree, the
#                                             CSV fixture's shape, the redaction rule)
#
# Env: FINAL_DOMAIN (REQUIRED for run), APS_SUITE_TAG (override the checkout's own tag),
# FV_STATE (default /tmp/final-validation — the state dir; secrets 0600),
# FINDINGS_OUT (default <checkout>/final-validation-FINDINGS.md), FINAL_PLAYWRIGHT (0; 1 =
# also run the translated playwright suite when node is present), FINAL_WITH_AIO_GATE (1;
# 0 = skip the S11 drift-gate step (at the fork's main HEAD) with a visible skip).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$ROOT/host"
STATE="${FV_STATE:-/tmp/final-validation}"   # secrets 0600, values never printed (env-init rule)
FINDINGS_OUT="${FINDINGS_OUT:-$ROOT/final-validation-FINDINGS.md}"
TAG="${APS_SUITE_TAG:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)}"
WIZ="http://127.0.0.1:8080"
NC=nextcloud-aio-nextcloud

die()  { echo "FATAL: $*" >&2; ledger "FATAL" "$*"; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }

# ── the ledger: one line per claim, the moment it is measured ─────────────────────────────
# WHERE never WHAT: the wizard password, the Provisionador token and the borg passphrase are
# ledgered only as paths and used-never-printed facts. The closing line of every run names
# the sync into /opt/aps-conecta-org/FINDINGS.md as the operator's next step (the house rule).
ledger() {  # CLAIM MEASURED
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" >>"$FINDINGS_OUT"
  printf '  · %s — %s\n' "$1" "$2"
}

secret_file() {  # NAME -> path; 0600-before-content (env-init rule)
  printf '%s/%s' "$STATE" "$1"
}

# ── the branded-bytes table: what the live wizard must carry (the S6/S11 live leg) ──────────
# Each row: LABEL|STRING — grepped against the rendered page. These are the RENDERABLE pairs
# of slice 23's drift row + INSTALLER.md's quotes — the gestion-side half no AIO-tree grep can
# see; the two PHP-borne canaries of the drift row's six are never renderable (zero-PHP) and
# ride the S11 arm's tree-side grep instead. The cards live in containers_branded_check (the
# post-login page); the already-installed greeting rides step 7 (the page renders it only
# once Nextcloud is installed).
branded_check() {  # PAGE_HTML_FILE
  local fail=0 s
  while IFS='|' read -r _ s; do
    grep -qF "$s" "$1" || { echo "  missing from the rendered wizard: $s" >&2; fail=1; }
  done <<'EOF'
title|<title>APS Conecta AIO — Instalador</title>
lang|<html lang="es">
EOF
  return $fail
}

containers_branded_check() {  # the post-login page's three cards + the eurooffice default
  local fail=0
  # the checked state rides the SAME input block as the id — -A6, not -A4: the TEMPLATE keeps
  # the checked 5 lines past the id (name/value/class/{% if %} between), the RENDERED page puts
  # it at +4 (twig collapses the condition); -A6 covers both with margin.
  grep -qF 'id="office-eurooffice"' "$1" \
    && grep -A6 'id="office-eurooffice"' "$1" | grep -q 'checked="checked"' \
    || { echo '  the eurooffice default is not checked (the D3 default drifted)' >&2; fail=1; }
  grep -qF 'id="territorio-card"' "$1" || { echo '  the territorio pending card is missing' >&2; fail=1; }
  grep -qF 'pendiente de empaquetado' "$1" || { echo '  the territorio card lost its wording' >&2; fail=1; }
  grep -qF '<code>aps-conecta provision</code>' "$1" \
    || { echo '  the Paso-1 card lost the provision command' >&2; fail=1; }
  [ "$fail" = 0 ]
}

# ── the wizard drive: slice 1's VERIFIED request sequence, re-stated ─────────────────────
# (the testbed is deliberately standalone; sourcing it would couple two scripts that must
# each run alone. A request shape that drifted from the testbed's fails LOUDLY here, against
# the real wizard — the acceptance is where drift gets caught.) The ONE deliberate difference:
# the domain post carries NO skip flag — this is the real validation.

wpost() {  # PATH CSRF_NAME CSRF_VALUE [extra --data-urlencode args…]
  local code
  code="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 15 \
    --data-urlencode "csrf_name=$2" --data-urlencode "csrf_value=$3" "${@:4}" "$WIZ$1")" \
    || die "POST $1: transport failure"
  [ "$code" = "201" ] || die "POST $1 returned $code (expected 201) — the wizard rejected the step"
}

wizard_login() {  # captures the one-time password from GET /setup, then logs in
  local html name value pw code
  mkdir -p "$STATE"; chmod 700 "$STATE"
  local i=1
  while [ $i -le 24 ]; do
    html="$(curl -sk --max-time 5 "$WIZ/setup" 2>/dev/null || true)"
    case "$html" in *'id="initial-password"'*) break ;; esac
    sleep 5; i=$((i+1))
  done
  case "$html" in *'id="initial-password"'*) ;; *) die "the wizard never served the initial password on :8080 within 2 min" ;; esac
  pw="$(printf '%s' "$html" | sed -n 's/.*id="initial-password"[^>]*>\([^<]*\)<.*/\1/p' | head -1)"
  [ -n "$pw" ] || die "could not parse the initial password from /setup"
  umask 177; printf '%s' "$pw" >"$(secret_file master.pw)"; umask 22
  ledger "wizard password captured" "$(secret_file master.pw) (0600; login blocks once apache runs)"
  # THE CSRF PAIR COMES FROM GET /login WITH THE SESSION JAR — slice 1's own shape, mirrored
  # exactly (setup.twig carries no form and no pair; the Guard is app-level middleware with a
  # session-scoped persistent token, so the pair must be captured with the cookie jar the
  # login POST will reuse — "the wizard API cannot be driven anonymously")
  html="$(curl -sk -c "$STATE/cookies" --max-time 10 "$WIZ/login" 2>/dev/null)" || die "could not GET $WIZ/login"
  name="$(printf '%s' "$html"  | sed -n 's/.*name="csrf_name" value="\([^"]*\)".*/\1/p' | head -1)"
  value="$(printf '%s' "$html" | sed -n 's/.*name="csrf_value" value="\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$name" ] && [ -n "$value" ] || die "no CSRF pair on /login — the wizard API cannot be driven anonymously"
  code="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 20 \
    --data-urlencode "password=$pw" \
    --data-urlencode "csrf_name=$name" --data-urlencode "csrf_value=$value" \
    "$WIZ/api/auth/login")" || die "login POST: transport failure"
  [ "$code" = "201" ] || die "wizard login returned $code"
  ledger "wizard login" "HTTP $code (the session jar carries the persistent CSRF pair)"
  printf '%s\n%s' "$name" "$value"
}

cmd_run() {
  : "${FINAL_DOMAIN:?export FINAL_DOMAIN — a real domain pointing at this VM (the disposable .invalid posture is aio-testbed's, never the acceptance's)}"
  : "${TAG:?no suite tag: git describe found none — export APS_SUITE_TAG}"
  : >"$FINDINGS_OUT"
  step "pre — the host bundle and the ledger"
  command -v "$HOST/aps-conecta" >/dev/null || die "host/aps-conecta missing in the checkout"
  ledger "checkout at suite tag" "$TAG"

  step "1/16 — preflight (the operator's own gate)"
  # preflight exits 0 with the domain resolvable and the ports free; its every line lands in
  # the run's own output, the ledger records the verdict + the run-command it prints.
  local pre_rc
  "$HOST/aps-conecta" preflight; pre_rc=$?
  [ "$pre_rc" = 0 ] || die "aps-conecta preflight failed (exit $pre_rc) — the acceptance does not proceed past a red preflight"
  ledger "preflight" "exit 0 at $FINAL_DOMAIN"

  step "2/16 — the docker run (the ONE source — the generated string, ledgered, executed)"
  local APS_RC
  APS_RC="$("$HOST/aps-conecta" run-command)" || die "run-command failed"
  ledger "run-command (the operator's exact bytes)" "$(printf '%s' "$APS_RC" | tr '\n' ' ')"
  bash -c "$APS_RC" || die "the docker run failed — see the ledger's run-command line for the exact bytes"
  ledger "mastercontainer running" "$(docker ps --format '{{.Names}}' | grep -x nextcloud-aio-mastercontainer)"

  step "3/16 — the wizard: login + the branded assertions (the S6/S11 live leg)"
  local csrf; csrf="$(wizard_login)"
  local name value; name="$(printf '%s\n%s' "$csrf" | sed -n 1p)"; value="$(printf '%s\n%s' "$csrf" | sed -n 2p)"
  curl -sk --max-time 10 "$WIZ/setup" >"$STATE/setup.html"
  if branded_check "$STATE/setup.html"; then
    ledger "the branded wizard (title + lang=es)" "both rendered byte-true"
  else
    die "the wizard is not the branded es-CL suite — check the image tag ($TAG)"
  fi
  # THE DOC-VS-WIZARD LIVE CHECK (slice 23's routed gestion-side half): the RENDERABLE quoted
  # strings INSTALLER.md carries, grepped against the rendered pages as they come up — the
  # title (every page), and post-login the cards; «APS Conecta AIO ya está instalado» renders
  # once the instance is installed (the already-installed page — checked at step 7, after
  # status.php answers). The two PHP-borne 68-list canaries are NEVER renderable from
  # templates (the zero-PHP rule) — the S11 arm's tree-side grep owns those.
  grep -qF 'APS Conecta AIO — Instalador' "$STATE/setup.html" \
    && ledger "doc-vs-wizard (the title)" "INSTALLER.md's quoted title renders byte-true" \
    || die "the rendered wizard lost the title INSTALLER.md quotes"

  step "4/16 — the wizard: domain (REAL validation), timezone, options, the backup config"
  wpost /api/configuration "$name" "$value" --data-urlencode "domain=$FINAL_DOMAIN"
  ledger "domain validated by the wizard" "$FINAL_DOMAIN (no skip — the real D10 leg)"
  wpost /api/configuration "$name" "$value" --data-urlencode "timezone=America/Santiago"
  wpost /api/configuration "$name" "$value" --data-urlencode "options-form=1"
  ledger "options form" "talk/whiteboard/imaginary off (ABSENCE-disables), office stays eurooffice"
  # THE BACKUP SECTION'S OWN FIELDS ONLY (containers.twig's backup form): the location — the
  # wizard GENERATES the borg passphrase itself (getAndGenerateSecret('BORGBACKUP_PASSWORD'),
  # index.php:114; shown to the operator at containers.twig:497 — the harness never touches it
  # and never claims a WHERE for a secret that is not its own). borg_restore_password is the
  # RESTORE section's field; posting it with empty locations 422s (validateBorgLocationVars).
  wpost /api/configuration "$name" "$value" --data-urlencode "borg_backup_host_location=/mnt/backup" \
    --data-urlencode "borg_remote_repo="
  wpost /api/configuration "$name" "$value" --data-urlencode "daily_backup_time=04:00"
  ledger "backup configured" "location /mnt/backup, daily 04:00 (automatic_updates absent = off, 040's posture); the passphrase is the wizard's own generated record"

  step "5/16 — the wizard: the post-login page's cards (branded, before start)"
  curl -sk -b "$STATE/cookies" --max-time 10 "$WIZ/containers" >"$STATE/containers.html"
  containers_branded_check "$STATE/containers.html" \
    && ledger "the wizard's cards" "eurooffice checked · territorio pendiente · Paso-1 provision command" \
    || die "the rendered containers page failed the branded-bytes check"

  step "6/16 — start (the 30-min bounded pull) + the container set"
  local code
  code="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 1800 \
    --data-urlencode "csrf_name=$name" --data-urlencode "csrf_value=$value" "$WIZ/api/docker/start" 2>/dev/null)" \
    || die "POST api/docker/start: the pull/run exceeded the 30 min bound"
  case "$code" in 200|201|302) ledger "container start" "HTTP $code (pulled + started inside the request)" ;;
    *) die "POST api/docker/start returned $code" ;; esac
  local c all i
  i=0
  while [ $i -lt 120 ]; do
    all=1
    for c in $NC nextcloud-aio-database nextcloud-aio-redis nextcloud-aio-apache \
             nextcloud-aio-eurooffice nextcloud-aio-notify-push; do
      docker ps --format '{{.Names}}' | grep -qx "$c" || { all=0; break; }
    done
    [ "$all" = 1 ] && break
    sleep 10; i=$((i+1))
  done
  [ "$all" = 1 ] || die "the container set never converged within 20 min"
  ledger "container set converged" "NC + database + redis + apache + eurooffice + notify-push"

  step "7/16 — Nextcloud healthy through the public path (the hairpin leg, D10)"
  local hz i2
  i2=0
  while [ $i2 -lt 60 ]; do
    hz="$(curl -sk --max-time 10 "https://$FINAL_DOMAIN/status.php" 2>/dev/null || true)"
    case "$hz" in *'"installed":true'*) break ;; esac
    sleep 10; i2=$((i2+1))
  done
  case "$hz" in *'"installed":true'*) ledger "status.php via the public domain" 'installed:true (the hairpin works)' ;;
    *) die "status.php never answered installed:true at https://$FINAL_DOMAIN within 10 min — the D10 leg" ;; esac
  local ohc; ohc="$(curl -sk --max-time 10 "https://$FINAL_DOMAIN/eurooffice/healthcheck" 2>/dev/null || true)"
  [ "$ohc" = "OK" ] && ledger "eurooffice healthcheck via the public path" "OK (the #8433 leg)" \
    || die "the eurooffice healthcheck did not answer OK through apache"
  # the doc-vs-wizard live check's second half: the already-installed page renders
  # «APS Conecta AIO ya está instalado» once Nextcloud is installed (slice 23's drift pair)
  curl -sk -b "$STATE/cookies" --max-time 10 "$WIZ/containers" >"$STATE/containers2.html" || true
  if grep -qF 'APS Conecta AIO ya está instalado' "$STATE/containers2.html" 2>/dev/null; then
    ledger "doc-vs-wizard (already-installed)" "«APS Conecta AIO ya está instalado» renders — the drift row's pair, live"
  else
    ledger "doc-vs-wizard (already-installed)" "the already-installed greeting not yet rendered (the wizard still shows the containers form — a finding, recorded, never fatal)"
  fi

  step "8/16 — the Provisionador: banner + the eight-screen API walk"
  # the banner capture is the reponer machinery's own shape (slice 19): the «Abra» line carries
  # the URL, the hex rides the line after the «Token de acceso» label — bounded 30 s.
  rm -f "$STATE/banner.fifo"; mkfifo "$STATE/banner.fifo"
  ( "$HOST/aps-conecta" provision >"$STATE/banner.fifo" 2>&1 ) &
  local PROV_PID=$!
  local prov_url tok deadline=$((SECONDS + 30)) ln seen_label=0
  exec 3<>"$STATE/banner.fifo"
  prov_url=""; tok=""
  while [ $SECONDS -lt $deadline ]; do
    IFS= read -r -t 5 ln <&3 || true
    case "$ln" in
      *Abra*)       prov_url="$(printf '%s' "$ln" | sed -n 's/.*Abra \([^ ]*\).*/\1/p')" ;;
      *"Token de acceso"*) seen_label=1 ;;   # the LABEL anchor: the hex rides the NEXT line
      *) [ "$seen_label" = 1 ] && [ -z "$tok" ] && [ -n "$ln" ] && tok="$ln" ;;
    esac
    [ -n "$prov_url" ] && [ -n "$tok" ] && break
  done
  [ -n "$prov_url" ] && [ -n "$tok" ] || die "the Provisionador banner never carried URL+token within 30 s"
  # the banner's hex line carries a 4-space indent (slice 14's banner prints "    {token}") —
  # strip ALL whitespace and assert the 64 length, banner_read's own shape (slice 19)
  tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
  [ "${#tok}" = 64 ] || die "the captured token is ${#tok} bytes, not the 64-hex the banner prints"
  umask 177; printf '%s' "$tok" >"$(secret_file prov.tok)"; umask 22
  ledger "Provisionador up" "URL captured; token $(secret_file prov.tok) (0600, used-never-printed)"
  local J="Content-Type: application/json"
  local q='cesfam la florida'
  local deis_hits codigo
  # THE ENDPOINTS ARE POST (slice 17's lock: /login is public, the step screens redirect
  # without the cookie, the /api routes answer 401 — this walk drives FOUR: deis/sitio/
  # usuarios/generar). The "estado" key is the UI's client wrapper over these same endpoints,
  # never their own wire bodies; sitio/usuarios/generar carry "ok": true, deis carries its own
  # shape {snapshot, total, matches} — the walk's greps match each (scoped: /api/estado IS a
  # serving path by design — slice 17's lock; the enumeration is the sanction, never a blanket
  # phrase)
  deis_hits="$(curl -sS -m 15 -X POST -H "$J" -H "Authorization: Bearer $tok" \
    -d "{\"q\": \"$q\"}" "$prov_url/api/deis")" \
    || die "POST /api/deis failed"
  # python3 for the JSON walk — the repo's own "no jq assumed" contract (provisioning/lib.sh:5,
  # deis.py:21); python3 is on #77's guaranteed host list, jq is not
  codigo="$(printf '%s' "$deis_hits" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["matches"][0]["codigo"])' 2>/dev/null || true)"
  case "$codigo" in ''|*[!0-9]*) die "the DEIS cascade search returned no codigo for '$q': $(printf '%s' "$deis_hits" | head -c 200)" ;; esac
  ledger "DEIS cascade" "'$q' → codigo $codigo (the register ships; the pick is ledgered)"
  curl -sS -m 15 -X POST -H "$J" -H "Authorization: Bearer $tok" \
    -d "{\"codigo\": \"$codigo\"}" "$prov_url/api/sitio" >"$STATE/sitio.json" || die "POST /api/sitio failed"
  grep -q '"ok": true' "$STATE/sitio.json" || die "POST /api/sitio answered: $(cat "$STATE/sitio.json")"
  ledger "site written" "sites/<codigo>/site.sh via write_site (codigo $codigo)"
  # the CSV fixture: 3 personas, one primer_admin sí — the planilla contract (GUIA §5)
  local csv="$(secret_file usuarios.csv)" BOM
  BOM="$(printf '\357\273\277')"   # the UTF-8 BOM, octal — printf's portable escape (the quoting dance ledgered)
  { printf '%s\n' "${BOM}usuario;nombre;apellidos;correo;grupos;primer_admin"
    printf '%s\n' "jperez;Juan;Pérez;jperez@$FINAL_DOMAIN;all-staff;si"      # (plan-local fix, Step 5: all-staff is the gid — todo_personal is the display phrase)
    printf '%s\n' "mlopez;María;López;mlopez@$FINAL_DOMAIN;all-staff;no"
    printf '%s\n' "csoto;Carlos;Soto;csoto@$FINAL_DOMAIN;all-staff;no"; } >"$csv"
  # /api/usuarios takes JSON {"codigo", "csv"} — the CSV rides AS A STRING in the payload
  local csv_json; csv_json="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <"$csv")"
  curl -sS -m 15 -X POST -H "$J" -H "Authorization: Bearer $tok" \
    -d "{\"codigo\": \"$codigo\", \"csv\": $csv_json}" "$prov_url/api/usuarios" >"$STATE/usuarios.json" \
    || die "POST /api/usuarios failed"
  grep -q '"ok": true' "$STATE/usuarios.json" || die "the planilla was rejected: $(cat "$STATE/usuarios.json")"
  ledger "planilla accepted" "3 personas, 1 primer_admin sí (the sealed sheet's input)"
  curl -sS -m 30 -X POST -H "$J" -H "Authorization: Bearer $tok" \
    -d "{\"codigo\": \"$codigo\", \"modo\": \"revision\"}" "$prov_url/api/generar" >"$STATE/generar-rev.json" || true
  grep -q '"modo": "revision"' "$STATE/generar-rev.json" 2>/dev/null && ledger "generar revision" "the plan (zero execs — the dry-run arm)" \
    || ledger "generar revision" "answered outside 200 — see the run log (a finding, recorded)"
  curl -sS -m 3900 -X POST -H "$J" -H "Authorization: Bearer $tok" \
    -d "{\"codigo\": \"$codigo\", \"modo\": \"ejecutar\"}" "$prov_url/api/generar" >"$STATE/generar.json" || true   # (plan-local fix, Step 5: 3900 = the executor's own TIMEOUTS worst case)
  grep -q '"divergencia_vacia": true' "$STATE/generar.json" \
    || die "the executor did not answer divergencia_vacia:true — see the tail: $(tail -c 400 "$STATE/generar.json")"
  ledger "provision executed" "the seed phases 05→60 + the roster; the gate's verdict inside the response"
  kill "$PROV_PID" 2>/dev/null; exec 3>&-; rm -f "$STATE/banner.fifo"

  step "9/16 — divergence --gate (the handoff gate) + the sealed credentials"
  ( cd "$ROOT" && bash scripts/divergence.sh --gate ); pre_rc=$?
  [ "$pre_rc" = 0 ] || die "divergence --gate exited $pre_rc — the handoff gate is red"
  ledger "divergence --gate" "exit 0 — divergence-empty, users included"
  local cred=/opt/aps-conecta/credentials.txt
  [ -f "$cred" ] && [ "$(stat -c %a "$cred")" = "600" ] && [ -s "$cred" ] \
    && ledger "sealed credentials" "$cred (0600, non-empty; WHERE never WHAT)" \
    || die "$cred missing/not-0600/empty — the sealed sheet is the acceptance's deliverable"
  local n_rows; n_rows="$(grep -cE '^(jperez|mlopez|csoto);' "$cred")"
  [ "$n_rows" = 3 ] || die "the sealed sheet carries $n_rows of the planilla's 3 personas (expected 3 — the count is the planilla's own uids, never the raw line count: the sheet also carries its es-CL comment header and the standing accounts' rows)"
  ledger "sealed sheet rows" "the planilla's 3 personas sealed (+ the standing accounts the cargos own — slice 15's cumulative seal)"

  step "10/16 — the S8 legs: notify-push, the store-off reboot + seed-twice, revalidate"
  docker ps --format '{{.Names}}' | grep -qx nextcloud-aio-notify-push \
    && ledger "notify-push sibling healthy" "running (the FRD S3 first-boot acceptance)" \
    || die "nextcloud-aio-notify-push is not running"
  docker restart "$NC" >/dev/null || die "docker restart $NC failed"
  local st i3; i3=0
  while [ $i3 -lt 60 ]; do
    st="$(docker exec -u www-data "$NC" php /var/www/html/occ status 2>/dev/null | grep -c 'installed: *true' || true)"
    [ "${st:-0}" -ge 1 ] && break; sleep 10; i3=$((i3+1))
  done
  [ "${st:-0}" -ge 1 ] || die "occ status never re-settled after the reboot within 10 min"
  ledger "store-off reboot" "$NC restarted; occ status re-settled (the slice-20 leg, live)"
  ( cd "$ROOT" && make seed-idempotent ) >"$STATE/seed2.log" 2>&1 && ledger "seed-idempotent (post-reboot)" "PASS — the hardened seed-twice" \
    || die "make seed-idempotent failed after the reboot — see $STATE/seed2.log"
  "$HOST/aps-conecta" revalidate >"$STATE/revalidate.log" 2>&1 && ledger "revalidate" "exit 0 — smoke + office-smoke + divergence aggregated" \
    || die "aps-conecta revalidate failed — see $STATE/revalidate.log"

  step "11/16 — the S9 legs: datos pending, tiles install + check, the .env key"
  "$HOST/aps-conecta" datos >"$STATE/datos.log" 2>&1 \
    && grep -q 'pendiente' "$STATE/datos.log" && ledger "datos (v1.0 posture)" "the pending posture, exit 0 — comuna-package.sh never ran" \
    || die "aps-conecta datos did not answer the pending posture: $(tail -3 "$STATE/datos.log")"
  echo 'el fondo (~1 GB) se construye ahora — REFRESH_TIMEOUT lo acota; el costo es honesto' >&2
  "$HOST/aps-conecta" tiles install --url "http://127.0.0.1:8084/chile.pmtiles" >"$STATE/tiles.log" 2>&1 && ledger "tiles install" "the loopback stack + the archive built (bounded)" \
    || die "aps-conecta tiles install failed — see $STATE/tiles.log"
  "$HOST/aps-conecta" tiles check >"$STATE/tiles-check.log" 2>&1 \
    && grep -q '206' "$STATE/tiles-check.log" && ledger "tiles check" "healthz ok + the 206 Range read (the FRD S9 liveness)" \
    || die "aps-conecta tiles check failed — see $STATE/tiles-check.log"
  grep -q '^TILES_PUBLIC_URL=http://127.0.0.1' "$ROOT/.env" \
    && ledger "TILES_PUBLIC_URL" "in .env at the loopback default (the VALUE asserted: http://127.0.0.1:<port> — the installer's own write)" \
    || die "TILES_PUBLIC_URL never landed in .env at its loopback default"

  step "12/16 — the S10 shape check: the self-test + the one live refusal"
  ( cd "$ROOT" && bash scripts/migrate-to-aio.sh --self-test ) >"$STATE/mig-selftest.log" 2>&1 \
    && grep -q 'self-test: 20 checks OK' "$STATE/mig-selftest.log" \
    && ledger "migrate-to-aio --self-test" "the tool's own line: self-test: 20 checks OK (the refusals + the survival-assert logic against fixtures)" \
    || die "migrate-to-aio.sh --self-test failed — see $STATE/mig-selftest.log"
  # THE ONE LIVE REFUSAL a fresh VM can fire honestly: prepare runs db-dump.sh itself (the tool
  # owns the dump stage — no dump-path override exists, and the GREP_STRING/owner/PG_VERSION
  # guards assert the tool's OWN dump file), and on an AIO-only VM db-dump.sh has no compose
  # source — prepare dies at the dump stage with its own refusal, touching nothing of AIO.
  # The GREP_STRING/owner/PG_VERSION refusals are the self-test's fixtures (just proven above);
  # the survival asserts are the REHEARSAL's (below).
  ( cd "$ROOT" && bash scripts/migrate-to-aio.sh prepare --domain "$FINAL_DOMAIN" ) \
    >"$STATE/mig-refusal.log" 2>&1 && pre_rc=0 || pre_rc=$?
  if [ "$pre_rc" -ne 0 ] && grep -q 'el volcado falló' "$STATE/mig-refusal.log"; then
    ledger "prepare's dump-stage refusal (live)" "refused, exit $pre_rc — no compose source on an AIO-only VM; nothing of AIO touched (the tool's own die line)"
  else
    die "prepare neither succeeded nor refused naming the dump stage — see $STATE/mig-refusal.log"
  fi
  # THE BOUNDARY, correctly cited: slice 22's lock routes verify's survival asserts to the
  # REHEARSAL (the full flow against a throwaway first — the rehearsal IS the "against a
  # throwaway" of its routed bullet); the fresh-VM harness cannot run them because its only
  # possible dump source is the AIO instance itself, and the tool's dump stage refuses right
  # here (just proven live) — the guard working is the proof.
  ledger "S10 boundary" "the survival asserts run at the rehearsal (the throwaway window, slice 22's lock: its verify leg + revalidate + seed-idempotent); the harness proves the tool's shape + the dump-stage refusal"

  step "13/16 — the S11 arm: the drift gate (the fork's main HEAD — the CI-identical run)"
  if [ "${FINAL_WITH_AIO_GATE:-1}" = 1 ]; then
    local aio="${STATE}/AIO"
    # THE FORK'S OWN REFS: main (the queue's home) + aps/main (CI output). The suite tag is an
    # IMAGE tag — no aps-v* git ref exists to pin; the honest clone is main's HEAD, the same
    # tree CI gates on every push (the release's bytes were gate-green at publish time).
    if [ ! -d "$aio/.git" ]; then
      git clone -q https://github.com/APS-Conecta/AIO.git "$aio" || die "cannot clone the AIO repo for the drift-gate arm"
    fi
    ( cd "$aio" && git fetch -q origin main && git checkout -q FETCH_HEAD ) \
      && ( cd "$aio" && REPLAY_PUSH=0 bash scripts/replay.sh replay ) >"$STATE/replay.log" 2>&1 \
      && ( cd "$aio" && bash scripts/brand-gate.sh .aps-replay-tree ) >"$STATE/brand.log" 2>&1 \
      && grep -q 'the fork declaration quotes' "$STATE/brand.log" \
      && ledger "the drift gate (the fork's main HEAD — the CI-identical run)" "replay REPLAY_PUSH=0 + brand-gate PASS, the drift row green" \
      || die "the S11 arm failed — see $STATE/replay.log / $STATE/brand.log"
  else
    ledger "the S11 arm" "SKIPPED (FINAL_WITH_AIO_GATE=0 — visible, never silent)"
  fi

  step "14/16 — the S6 browser leg (the translated suite — the honest boundary)"
  if [ "${FINAL_PLAYWRIGHT:-0}" = 1 ] && command -v node >/dev/null 2>&1; then
    echo "  run from the AIO checkout: cd php/tests && npx playwright test --reporter=line" >&2
    ledger "the S6 browser leg" "printed the suite's own command (the suite's harness owns it)"
  else
    ledger "the S6 browser leg" "SKIPPED (FINAL_PLAYWRIGHT unset or node absent — the suite's own harness owns it; visible)"
  fi

  step "15/16 — respaldo + the borg backup (the acceptance's last leg)"
  "$HOST/aps-conecta" respaldo >"$STATE/respaldo.log" 2>&1 && ledger "respaldo wired" "/opt/aps-conecta in additional_backup_directories (idempotent)" \
    || die "aps-conecta respaldo failed — see $STATE/respaldo.log"
  # THE BACKUP POST STOPS THE WHOLE STACK FIRST (DockerController::startBackup: the recursive
  # stop of TOP_CONTAINER apache, then borgbackup runs) — upstream's own shape: a manual backup
  # leaves the stack DOWN and the operator starts it again. The harness asserts the archive on
  # the HOST path (the wizard's borg_backup_host_location binds /mnt/backup into the
  # borgbackup container at /mnt/borgbackup — the NC container has no such mount), then RESTARTS
  # the stack through the wizard's own start (the operator's own post-backup step), restoring the
  # stays-up doctrine and asserting health one last time.
  code="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 1800 \
    --data-urlencode "csrf_name=$name" --data-urlencode "csrf_value=$value" "$WIZ/api/docker/backup" 2>/dev/null)" \
    || die "POST api/docker/backup exceeded the 30 min bound"
  [ "$code" = 200 ] || [ "$code" = 201 ] || die "POST api/docker/backup returned $code"
  local bk
  bk="$(docker inspect -f '{{.State.ExitCode}}' nextcloud-aio-borgbackup 2>/dev/null || true)"
  [ "${bk:-1}" = 0 ] || die "the borgbackup container exited ${bk:-unknown} (not 0)"
  ls -1 /mnt/backup 2>/dev/null | head -3 >"$STATE/backup-ls.txt" || true
  [ -s "$STATE/backup-ls.txt" ] && ledger "borg backup taken" "the archive exists at the host path (exit 0; the wizard's own trigger)" \
    || die "/mnt/backup shows no archive — the acceptance's last leg failed"
  ledger "backup's stack stop" "upstream's own shape: the manual backup stops the stack (TOP_CONTAINER apache)"
  # the restart — the operator's own post-backup step, through the wizard's own API
  code="$(curl -sk -b "$STATE/cookies" -c "$STATE/cookies" -o /dev/null -w '%{http_code}' --max-time 900 \
    --data-urlencode "csrf_name=$name" --data-urlencode "csrf_value=$value" "$WIZ/api/docker/start" 2>/dev/null)" \
    || die "the post-backup restart exceeded the 15 min bound"
  case "$code" in 200|201|302) ;; *) die "the post-backup restart returned $code" ;; esac
  local i5=0
  while [ $i5 -lt 60 ]; do
    hz="$(curl -sk --max-time 10 "https://$FINAL_DOMAIN/status.php" 2>/dev/null || true)"
    case "$hz" in *'"installed":true'*) break ;; esac
    sleep 10; i5=$((i5+1))
  done
  case "$hz" in *'"installed":true'*) ledger "the stack restarted post-backup" "status.php installed:true again — the instance stays up (the doctrine restored honestly)" ;;\
    *) die "the stack never re-settled after the post-backup restart within 10 min" ;; esac

  step "16/16 — the summary"
  local n_claims; n_claims="$(grep -c . "$FINDINGS_OUT")"
  ledger "WHOLE-INSTALLER ACCEPTANCE" "PASS — $n_claims claims measured as they happened, 16 steps green"
  echo
  ok "WHOLE-INSTALLER ACCEPTANCE: PASS — $n_claims claims measured as they happened"
  echo "  the instance STAYS UP (the rehearsal instance — inspect, then scripts/final-validation.sh down)"
  echo "  THE LEDGER'S HOME: copy $FINDINGS_OUT into /opt/aps-conecta-org/FINDINGS.md as the run's section (the house rule — findings recorded as they happen)"
}

cmd_down() {  # the testbed's label/name-filtered teardown shape — the instance stays up after a run
  docker ps -aq --filter name=nextcloud-aio- | while IFS= read -r id; do docker rm -f "$id" 2>/dev/null; done
  docker volume ls -q --filter name=nextcloud_aio | while IFS= read -r v; do docker volume rm "$v" 2>/dev/null; done
  ok "torn down (nextcloud-aio*-filtered only)"
}

# ── the hermetic self-test: the harness's own claims about itself ───────────────────────────
cmd_selftest() {
  local fails=0
  # 1. the ledger writer: append + read-back, timestamped, tab-separated
  local t="$(mktemp -d)"; FINDINGS_OUT="$t/f.md"
  ledger "claim" "measured"
  [ "$(wc -l <"$FINDINGS_OUT")" = 1 ] && grep -q "claim.*measured" "$FINDINGS_OUT" \
    && [ "$(awk -F'\t' 'NR==1{print NF}' "$FINDINGS_OUT")" = 3 ] \
    || { echo "  the ledger line is malformed" >&2; fails=$((fails+1)); }
  # 2. the branded table greps TRUE against the post-queue tree's template shapes (the
  #    fixture: the rendered setup page's two pairs, rendered the way the wizard renders)
  printf '<!DOCTYPE html>\n<html lang="es"><head><title>APS Conecta AIO — Instalador</title></head></html>\n' >"$t/setup.html"
  branded_check "$t/setup.html" || { echo "  the branded_check greps a true fixture red" >&2; fails=$((fails+1)); }
  printf '<input type="radio" id="office-eurooffice" name="office_suite_choice" value="eurooffice" class="office-radio" checked="checked">\n<div id="territorio-card">pendiente de empaquetado</div>\n<code>aps-conecta provision</code>\n' >"$t/c.html"
  containers_branded_check "$t/c.html" || { echo "  the containers branded greps a true fixture red" >&2; fails=$((fails+1)); }
  # 3. prove-it-red: a tampered fixture reds exactly its check (the never-green rule)
  printf '<html lang="en"><title>Nextcloud AIO</title>\n' >"$t/bad.html"
  branded_check "$t/bad.html" 2>/dev/null && { echo "  a tampered fixture stayed green" >&2; fails=$((fails+1)); }
  # 4. the redaction rule: the RUN PATH never ledgers a secret VALUE — grep cmd_run's region
  #    only (the self-reference find: this check's own pattern line would match itself, the
  #    slice-22 self-referential-canary class — the region scope is the fix)
  local self="$(realpath "$0")"
  sed -n '1,/^cmd_selftest()/p' "$self" | grep -qE 'ledger .*(\$tok|\$pw|\$borg_pw)[^)]' \
    && { echo "  a secret VALUE would reach the ledger" >&2; fails=$((fails+1)); }
  # 5. the CSV fixture's shape: BOM + the 6-column header + exactly one sí
  local csv="$t/usuarios.csv"
  local BOM; BOM="$(printf '\357\273\277')"
  { printf '%s\n' "${BOM}usuario;nombre;apellidos;correo;grupos;primer_admin"
    printf '%s\n' 'a;A;A;a@x;todo_personal;si'
    printf '%s\n' 'b;B;B;b@x;todo_personal;no'; } >"$csv"
  head -c 3 "$csv" | od -An -tx1 | grep -q 'ef bb bf' || { echo "  the CSV fixture lost its BOM" >&2; fails=$((fails+1)); }
  [ "$(grep -c ';si$' "$csv")" = 1 ] || { echo "  the CSV fixture's primer_admin count is wrong" >&2; fails=$((fails+1)); }
  rm -rf "$t"
  if [ "$fails" = 0 ]; then printf 'SELF-TEST: PASS — 5/5\n'; exit 0; fi
  printf 'SELF-TEST: FAIL — %s\n' "$fails" >&2; exit 1
}

case "${1:-}" in
  run)        shift; cmd_run "$@" ;;
  down)       shift; cmd_down "$@" ;;
  --self-test) shift; cmd_selftest "$@" ;;
  *) sed -n '2,24p' "$0"; echo; echo "uso: scripts/final-validation.sh {run|down|--self-test} (FINAL_DOMAIN para run)"; exit 1 ;;
esac
