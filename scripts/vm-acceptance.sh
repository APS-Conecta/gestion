#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The #54 acceptance, as one command on a scratch Ubuntu 24.04 VM: the REAL one-liner from a
# REAL release URL with no token, then the ticket's own checks. The rehearsal (Images + Clean
# boot by dispatch, aps/RELEASING.md §4) is the CI half of «the rehearsal is green»; this
# script is the VM half — it proves what CI cannot: the published bootstrap, fetched exactly
# the way an establishment fetches it, on a pristine machine.
#
#   sudo bash scripts/vm-acceptance.sh [--tag vX.Y.Z|latest] [--repo-url URL]
#                                      [--dominio D] [--sin-datos] [--solo-chequeos] [--continuar]
#   bash scripts/vm-acceptance.sh --self-test
#
#   --tag        the suite release to install (default: latest — resolved by redirect, no token)
#   --repo-url   where releases live (default: the public suite repo)
#   --dominio    install by domain D (its DNS must reach this VM on 443; the certificate is
#                ACME's, as upstream). Without it: install by this VM's own IPv4, with the
#                installer's own certificate.
#   --sin-datos  skip the national data masters (a small VM's disk; Clean boot's own posture)
#   --sin-respaldo  drive the wizard without the daily backup (criterion 6 will red: actualizar
#                refuses without a configured backup, by design) — the honest no-backup posture
#   --solo-chequeos  re-run only the checks against an already-installed VM
#   --continuar  run the checks even when the install step fails (a red named, not a stop)
#
# The ticket's six criteria, each asserted on what an administrator observes:
#   1. the bootstrap verified the package's signature and landed the suite at /opt/aps-conecta;
#   2. «aps-conecta estado» answers, the suite answers at https://<address>/ through the
#      installer's CA (and refuses without it), and a planilla user logs in over OCS;
#   3. every default app in apps.json is installed — own/fork apps from their own release at
#      the locked tag (tarball, hash, no signature.json), store apps enabled — the landing app
#      is IntraVox, and the two functional opens answer (notify_push, the office connector);
#   4. each optional app chosen at the command line is installed from its release, and the
#      wizard's options record still names the choice;
#   5. buscador finds a PDF (upload, index, search) — or names why it cannot: the manifest
#      carries no buscador row until #149 lands;
#   6. «aps-conecta actualizar --revisar» prints the plan and writes nothing.
#
# The seams (VMA_*) exist for the self-test: every input is a file or a command the self-test
# stubs — the same PATH-shim doctrine as host/aps-conecta's self-test: no root, no docker.
# shellcheck disable=SC2016  # the self-test's arms are single-quoted by design: t() evals them
# in this shell, where the functions and the counters live
set -uo pipefail

VMA_ROOT="${VMA_ROOT:-/opt/aps-conecta}"            # the install's home (APS_HOME)
VMA_TREE="${VMA_TREE:-$VMA_ROOT/instalador}"        # the suite tree the package laid down
VMA_REPO_URL="${VMA_REPO_URL:-https://github.com/APS-Conecta/gestion}"
VMA_TAG="${VMA_TAG:-latest}"
VMA_DOMINIO="${VMA_DOMINIO:-}"                      # empty: install by IP
VMA_SKIP_DATOS="${VMA_SKIP_DATOS:-0}"
VMA_DOCKER="${VMA_DOCKER:-docker}"
VMA_APS="${VMA_APS:-$VMA_TREE/host/aps-conecta}"   # the CLI the bootstrap prints as its next step (on PATH only after «preparar»)
VMA_CURL="${VMA_CURL:-curl}"
VMA_OCC_SHIM="${VMA_OCC_SHIM:-}"                    # set by the self-test; empty on a VM
VMA_WORK="${VMA_WORK:-$(mktemp -d /tmp/vm-acceptance.XXXXXX)}"
VMA_APPS="${VMA_APPS:-farmacia estadistica totem}"  # the optional apps the install chooses (#39–#41)
VMA_PDF_TOKEN="${VMA_PDF_TOKEN:-AZUCARMORADA54}"    # the word only the acceptance PDF carries
VMA_INSTALL_ENV="${VMA_INSTALL_ENV:-}"             # extra K=V pairs for the install (a rehearsal's APS_SUITE_TAG)
VMA_RESPALDO="${VMA_RESPALDO-1}"                   # the daily backup a real clinic configures in the wizard (§11):
                                                     # 1 = "$VMA_ROOT/respaldos"; a path = that path; empty = none
                                                     # (an install without it cannot pass criterion 6 — actualizar
                                                     # refuses without a configured backup, by design)
export VMA_ROOT VMA_TREE VMA_REPO_URL VMA_TAG VMA_DOMINIO VMA_SKIP_DATOS VMA_WORK

die() { printf 'FATAL: %s\n' "$1" >&2; exit 2; }

# occ, the way every operator script reaches it — env.sh's own resolution. The shim seam keeps
# the self-test hermetic; on a VM it is empty and the real container answers.
occ() {
  if [ -n "$VMA_OCC_SHIM" ]; then "$VMA_OCC_SHIM" "$@"; return; fi
  ( cd "$VMA_TREE" && . scripts/env.sh >/dev/null 2>&1 && occ "$@" )
}

# ── the verdict table: every check runs, nothing hides behind a first red ────────────────────
CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_SKIP=0
verdict() {  # verdict STATE TITLE [DETAIL]  — STATE: ok | fail | skip
  case "$1" in
    ok)   CHECKS_OK=$((CHECKS_OK + 1));    printf '  ✓ %s\n' "$2${3:+ — $3}" ;;
    fail) CHECKS_FAIL=$((CHECKS_FAIL + 1)); printf '  ✗ %s\n' "$2${3:+ — $3}" ;;
    skip) CHECKS_SKIP=$((CHECKS_SKIP + 1)); printf '  − %s\n' "$2${3:+ — $3}" ;;
  esac
}
summarize() {
  printf '\nVeredicto: %d ✓ · %d ✗ · %d −\n' "$CHECKS_OK" "$CHECKS_FAIL" "$CHECKS_SKIP"
  [ "$CHECKS_FAIL" -eq 0 ]
}

# ── the address this VM installs by (the kernel's routed IPv4 — the installer's own probe) ───
routed_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1; }
install_address() { if [ -n "$VMA_DOMINIO" ]; then printf '%s' "$VMA_DOMINIO"; else routed_ip; fi; }

# ── 1. the bootstrap: the real one-liner, the real URL, no token ────────────────────────────
# «latest» resolves the way the app resolver does — the redirect, never the API — so the
# acceptance needs no token on a path an establishment also walks unauthenticated.
resolve_tag() {
  local t="$VMA_TAG"
  if [ "$t" = latest ]; then
    t="$("$VMA_CURL" -fsSI -o /dev/null -w '%{redirect_url}' "$VMA_REPO_URL/releases/latest" 2>/dev/null \
          | sed -n 's|.*/tag/\(v[0-9][^/?#]*\).*|\1|p')" || true
    [ -n "$t" ] || die "no se pudo resolver la última release desde $VMA_REPO_URL/releases/latest — pase --tag vX.Y.Z"
  fi
  printf '%s' "$t"
}

run_bootstrap() {  # $1 = tag — the establishment's own command, verbatim
  local url="$VMA_REPO_URL/releases/download/$1/apsconecta-$1-install.sh" out="$VMA_WORK/bootstrap.out"
  printf 'El comando del establecimiento:\n  curl -fsSL %s | sudo bash\n\n' "$url"
  # shellcheck disable=SC2024  # the operator's command stays verbatim; the caller is already root (preflight), so the shell-side redirect is ours and equivalent — and REPO_URL rides env(1) because sudo sanitizes it
  if "$VMA_CURL" -fsSL "$url" | sudo env REPO_URL="$VMA_REPO_URL" bash >"$out" 2>&1; then
    printf 'bootstrap: completo (registro: %s)\n' "$out"
    return 0
  fi
  printf 'bootstrap: FALLÓ (registro: %s)\n' "$out"
  return 1
}

# The two lines the real bootstrap prints on the verified path (install.sh's own words, so a
# wording drift here reds beside the drift, not silently). A pristine VM's first run carries no
# signify — the honest info line is the verified path too (the embedded sha256 already anchored
# the bytes; install.sh's own posture), and «preparar» installs signify for the NEXT run.
check_bootstrap() {  # $1 = tag
  local out="$VMA_WORK/bootstrap.out" tag="$1"
  { grep -qF 'firma verificada (signify, clave pública del proyecto)' "$out" 2>/dev/null \
      || grep -qF 'signify no está instalado: la suma de verificación ya probó estos bytes' "$out" 2>/dev/null; } \
    && grep -qF "Suite $tag en $VMA_ROOT/instalador (paquete verificado" "$out" 2>/dev/null
}

# ── 2. estado, the suite's answer, a staff login ─────────────────────────────────────────────
check_estado() { "$VMA_APS" estado >/dev/null 2>&1; }

check_status_php() {  # $1 = address, $2 = CA — installed:true, through the installer's CA only
  "$VMA_CURL" -fsS --cacert "$2" "https://$1/status.php" 2>/dev/null | grep -q '"installed":true'
}
check_status_refused_bare() {  # $1 = address — without the CA the peer must be refused
  local rc=0
  "$VMA_CURL" -fsS -o /dev/null "https://$1/status.php" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
}
check_user_login() {  # $1 = address, $2 = CA, $3 = uid, $4 = password — OCS, the staff surface
  printf 'user = "%s:%s"\n' "$3" "$4" \
    | "$VMA_CURL" -fsS -K - --cacert "$2" -H 'OCS-APIRequest: true' \
        "https://$1/ocs/v2.php/cloud/user?format=json" 2>/dev/null | grep -q "\"id\":\"$3\""
}
check_route_alive() {  # $1 = address, $2 = CA, $3 = path — the «it opens» probe (route answers)
  case "$("$VMA_CURL" -sS -o /dev/null -w '%{http_code}' --cacert "$2" "https://$1$3" 2>/dev/null)" in
    200|302|303|401) return 0 ;;
    *) return 1 ;;
  esac
}

# The sealed sheet's third column is the password (usuario;nombre;contraseña;primer_admin).
sealed_password() {  # $1 = uid
  sudo python3 - "$1" <<'PY'
import csv, os, sys
with open(os.path.join(os.environ.get("VMA_ROOT", "/opt/aps-conecta"), "credentials.txt"),
          encoding="utf-8") as fh:
    for row in csv.reader(fh, delimiter=";"):
        if row and row[0] == sys.argv[1]:
            print(row[2])
            break
PY
}

# ── 3+4. the apps: one walk of the manifest — the only list (ADR-0017) ──────────────────────
manifest_rows() {  # → TSV: id, source, optional(1/0) — apps.json itself, never retyped
  python3 - "$VMA_TREE/apps.json" <<'PY'
import json, sys
for r in json.load(open(sys.argv[1])):
    print(f'{r["id"]}\t{r["source"]}\t{1 if r.get("optional") else 0}')
PY
}
lock_field() {  # $1 = app, $2 = field → the lock's value, '' when the row is absent
  sudo python3 - "$1" "$2" <<'PY'
import json, os, sys
try:
    row = json.load(open(os.path.join(os.environ.get("VMA_ROOT", "/opt/aps-conecta"),
                                      "apps.lock.json")))["apps"].get(sys.argv[1], {})
except OSError:
    row = {}
print(row.get(sys.argv[2], ""))
PY
}

# The release five (assert-release-app's own bar, restated here because the acceptance runs on
# the VM, where the composite action's checkout does not exist). Prints its reason, returns 1.
check_release_app() {  # $1 = app id
  local app="$1"
  local tag version sha got store="$VMA_ROOT/apps/$app"
  tag="$(lock_field "$app" tag)"
  [ -n "$tag" ] || { printf 'la cerradura no nombra a %s' "$app"; return 1; }
  version="$(lock_field "$app" version)"; sha="$(lock_field "$app" sha256)"
  [ "${tag#v}" = "$version" ] || { printf 'etiqueta %s y versión %s discrepan en la cerradura' "$tag" "$version"; return 1; }
  got="$(occ config:app:get "$app" installed_version 2>/dev/null)"
  [ "$got" = "$version" ] || { printf 'la instancia corre %s %s, la cerradura nombra %s' "$app" "${got:-<nada>}" "$version"; return 1; }
  sudo test -f "$store/$tag.tar.gz" || { printf 'el paquete %s no está en el almacén' "$app"; return 1; }
  echo "$sha  $store/$tag.tar.gz" | sudo sha256sum --check - >/dev/null 2>&1 \
    || { printf 'el paquete de %s no son los bytes de la cerradura' "$app"; return 1; }
  if "$VMA_DOCKER" exec --user www-data aps-conecta-nextcloud \
       test -e "/var/www/html/custom_apps/$app/appinfo/signature.json" 2>/dev/null; then
    printf '%s lleva appinfo/signature.json — una release nunca lo lleva' "$app"; return 1
  fi
}

# The store rows: enabled, at a version, and never a lock row (the lock is the release channel's).
check_store_app() {  # $1 = app id
  local app="$1" enabled
  enabled="$(occ config:app:get "$app" enabled 2>/dev/null)"
  [ "$enabled" = yes ] || { printf '%s no está habilitada (%s)' "$app" "${enabled:-<nada>}"; return 1; }
  [ -n "$(occ config:app:get "$app" installed_version 2>/dev/null)" ] \
    || { printf '%s no reporta versión instalada' "$app"; return 1; }
  [ -z "$(lock_field "$app" tag)" ] || { printf 'la cerradura nombra a %s — una app de tienda nunca la ocupa' "$app"; return 1; }
}

check_apps() {  # $1 = the chosen optional ids, $2 = address, $3 = CA — one verdict per manifest row
  local chosen=" $1 " id source optional detalle talk=0
  # Talk is the wizard's switch, not the manifest's: the record gates spreed (#145, ADR-0020) —
  # a silent install is Talk-off, so the fork's release resolves nothing and its ABSENCE is the
  # contract (total: no lock row, no version, no directory), exactly as Clean boot asserts it.
  sudo grep -q "talk=1" "$VMA_ROOT/aio/opciones" 2>/dev/null && talk=1
  while IFS=$'\t' read -r id source optional; do
    [ -n "$id" ] || continue
    detalle=""
    if [ "$id" = spreed ] && [ "$talk" = 0 ]; then
      if [ -z "$(lock_field spreed tag)" ] \
         && [ -z "$(occ config:app:get spreed installed_version 2>/dev/null)" ] \
         && ! "$VMA_DOCKER" exec --user www-data aps-conecta-nextcloud \
              test -e /var/www/html/custom_apps/spreed 2>/dev/null; then
        verdict ok "Talk apagado: spreed totalmente ausente" "el registro del asistente lo apagó y nada lo instaló (ADR-0020)"
      else
        verdict fail "Talk apagado exige ausencia total de spreed" "hay fila, versión o directorio — cat $VMA_ROOT/aio/opciones"
      fi
      continue
    fi
    if [ "$source" = store ]; then
      detalle="$(check_store_app "$id" || true)"
    elif [ "$optional" = 0 ] || case "$chosen" in *" $id "*) true ;; *) false ;; esac; then
      detalle="$(check_release_app "$id" || true)"
    else
      continue   # an optional row nobody chose: absent is the contract, asserted by Clean boot
    fi
    if [ -z "$detalle" ]; then
      verdict ok "app $id instalada de su canal"
    else
      verdict fail "app $id" "$detalle"
    fi
  done < <(manifest_rows)
  # the landing app is IntraVox's alone (ADR-0010)
  if [ "$(occ config:system:get defaultapp 2>/dev/null)" = intravox ]; then
    verdict ok "IntraVox es la app de aterrizaje"
  else
    verdict fail "la app de aterrizaje" "es «$(occ config:system:get defaultapp 2>/dev/null || echo '?')», no intravox (ADR-0010)"
  fi
  # the two functional opens Clean boot also runs, plus the desktop's route probe
  if occ notify_push:self-test >/dev/null 2>&1; then verdict ok "notify_push responde su self-test"
  else verdict fail "notify_push" "occ notify_push:self-test — el empuje de notificaciones"; fi
  if occ eurooffice:documentserver --check >/dev/null 2>&1; then verdict ok "la oficina responde (eurooffice --check)"
  else verdict fail "la oficina" "occ eurooffice:documentserver --check — #140/#147: la primera instalación enrojece sin su arreglo"; fi
  if check_route_alive "$2" "$3" /index.php/apps/desktop_workspace/; then verdict ok "el escritorio abre"
  else verdict fail "el escritorio" "/index.php/apps/desktop_workspace/ no contestó 200/302/401"; fi
}

check_optional_record() {  # $1 = the chosen ids — the wizard's record must name each choice
  local id record="$VMA_ROOT/aio/opciones"
  sudo test -f "$record" 2>/dev/null || { verdict fail "el registro de opciones" "no existe: $record"; return; }
  for id in $1; do
    if sudo grep -q "$id=1" "$record" 2>/dev/null; then
      verdict ok "opcional elegida: $id" "el registro del asistente la nombra"
    else
      verdict fail "opcional elegida: $id" "el registro no la nombra — cat $record"
    fi
  done
}

# ── 5. buscador finds a PDF — or names the reason it cannot ─────────────────────────────────
check_buscador() {  # $1 = address, $2 = CA, $3 = uid, $4 = password
  if ! manifest_rows | cut -f1 | grep -qx buscador_documental; then
    verdict fail "buscador encuentra un PDF" \
      "el manifiesto no lleva fila de buscador — llega con #149 (verificar y terminar); hoy la suite no instala buscador"
    return 1
  fi
  # The app is in the manifest: the whole flow — a PDF only this run knows, uploaded as staff,
  # indexed, then found through the app's own search API (the session user's, never another's).
  local pdf="$VMA_WORK/protocolo.pdf" ap tries
  python3 - "$pdf" "$VMA_PDF_TOKEN" <<'PY'
import sys
path, token = sys.argv[1], sys.argv[2]
content = f"protocolo {token}".encode()
objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length " + str(len(content) + 42).encode() + b" >>\nstream\nBT /F1 24 Tf 72 720 Td ("
        + content + b") Tj ET\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out = bytearray(b"%PDF-1.4\n")
offs = []
for i, o in enumerate(objs, 1):
    offs.append(len(out))
    out += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
xref = len(out)
out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
for off in offs:
    out += f"{off:010d} 00000 n \n".encode()
out += (f"trailer << /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref {xref}\n%%EOF").encode()
open(path, "wb").write(bytes(out))
PY
  ap="$(printf 'user = "%s:%s"\n' "$3" "$4" \
        | "$VMA_CURL" -fsS -K - --cacert "$2" -H 'OCS-APIRequest: true' \
            "https://$1/ocs/v2.php/core/getapppassword" 2>/dev/null \
        | sed -n 's/.*<apppassword>\(.*\)<\/apppassword>.*/\1/p')"
  [ -n "$ap" ] || { verdict fail "buscador encuentra un PDF" "no se pudo obtener una contraseña de app para la subida"; return 1; }
  "$VMA_CURL" -fsS -u "$3:$ap" --cacert "$2" \
    -T "$pdf" "https://$1/remote.php/dav/files/$3/protocolo-$VMA_PDF_TOKEN.pdf" \
    || { verdict fail "buscador encuentra un PDF" "la subida WebDAV del PDF falló"; return 1; }
  for tries in $(seq 36); do   # the worker indexes on its own cadence: bounded at six minutes
    if "$VMA_CURL" -fsS -u "$3:$ap" --cacert "$2" -H 'Content-Type: application/json' \
         -d "{\"query\":\"$VMA_PDF_TOKEN\"}" "https://$1/index.php/apps/buscador_documental/search" 2>/dev/null \
         | grep -q '"status":"ok"'; then
      verdict ok "buscador encuentra un PDF" "el término $VMA_PDF_TOKEN contestó con resultados"
      return 0
    fi
    sleep 10
  done
  verdict fail "buscador encuentra un PDF" \
    "el término $VMA_PDF_TOKEN no apareció en $((tries * 10)) segundos — ¿indexando? (admin/overview), ¿ámbito sembrado? (#138)"
}

# ── 6. actualizar --revisar: the plan on the table, nothing moved ───────────────────────────
check_actualizar_revisar() {
  local lock="$VMA_ROOT/apps.lock.json" out rc=0 antes paquetes
  antes="$(sudo sha256sum "$lock" 2>/dev/null | cut -d' ' -f1)"
  paquetes="$(sudo find "$VMA_ROOT/apps" -name '*.tar.gz' -printf '%p %T@\n' 2>/dev/null | sort)"
  out="$(sudo "$VMA_APS" actualizar --revisar 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { verdict fail "actualizar --revisar corre" "salió $rc: $(printf '%s' "$out" | tail -1)"; return 1; }
  case "$out" in
    *"Plan de actualización"*"modo --revisar: nada se escribe ni se cambia"*) ;;
    *) verdict fail "actualizar --revisar corre" "no imprimió el plan ni la línea de --revisar"; return 1 ;;
  esac
  [ "$(sudo sha256sum "$lock" 2>/dev/null | cut -d' ' -f1)" = "$antes" ] \
    || { verdict fail "actualizar --revisar corre" "reescribió la cerradura — una revisión no es un efecto"; return 1; }
  [ "$(sudo find "$VMA_ROOT/apps" -name '*.tar.gz' -printf '%p %T@\n' 2>/dev/null | sort)" = "$paquetes" ] \
    || { verdict fail "actualizar --revisar corre" "tocó los paquetes almacenados"; return 1; }
  verdict ok "actualizar --revisar corre" "el plan, y nada escrito"
}

# ── the run: preflight → bootstrap → install → checks ───────────────────────────────────────
preflight() {
  [ "$(id -u)" = 0 ] || die "corra como root (sudo) — el instalador lo exige"
  local os port busy="" gb
  os="$(bash -c '. /etc/os-release 2>/dev/null; printf "%s %s" "${NAME:-}" "${VERSION_ID:-}"')"
  printf 'VM: %s · %s · %d GB libres\n' "$os" "$(uname -m)" "$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')"
  case "$os" in *"Ubuntu 24.04"*) ;; *) printf 'AVISO: el tiquete nombra Ubuntu 24.04 — esto es «%s»; se continúa\n' "$os" ;; esac
  for port in 8080 443 3478; do ss -tln 2>/dev/null | grep -q ":$port " && busy="$busy $port"; done
  [ -z "$busy" ] || die "puertos ocupados:$busy — la suite los necesita libres"
  gb="$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')"
  [ "${gb:-0}" -ge 20 ] || die "disco: ${gb:-?} GB libres, el mínimo del instalador son 20"
}

silent_install() {  # $1 = site.sh, $2 = usuarios.csv — the operator's own silent command
  local flags=() app out rc=0 envs=(MIN_DISK_GB=2)
  for app in $VMA_APPS; do flags+=(--app "$app"); done
  [ "$VMA_SKIP_DATOS" = 1 ] && envs+=(APS_SKIP_DATOS=1)
  # shellcheck disable=SC2206  # K=V words, by contract — the rehearsal's APS_SUITE_TAG rides here
  envs+=($VMA_INSTALL_ENV)
  # the wizard's daily backup — the step a clinic also walks (INSTALLER §4): without it there is
  # no backup scope, and actualizar refuses by design (its precondition, #46)
  local respaldo="$VMA_RESPALDO"
  [ "$respaldo" = 1 ] && respaldo="$VMA_ROOT/respaldos"
  [ -n "$respaldo" ] && flags+=(--respaldo "$respaldo")
  out="$VMA_WORK/install.out"
  # shellcheck disable=SC2024  # preflight guarantees root; the redirect is ours, on purpose
  sudo env "PATH=$PATH" "${envs[@]}" "$VMA_APS" install \
    --sitio "$1" --planilla "$2" "${flags[@]}" </dev/null >"$out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { printf 'install: FALLÓ (salió %s — registro: %s)\n' "$rc" "$out"; return 1; }
  grep -q '^INSTALACIÓN: ✓' "$out" || { printf 'install: no imprimió «INSTALACIÓN: ✓» (registro: %s)\n' "$out"; return 1; }
  printf 'install: INSTALACIÓN: ✓ (registro: %s)\n' "$out"
}

main() {
  local tag="$VMA_TAG" addr ca="$VMA_WORK/ca.crt" solo=0 continuar=0 pw
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) VMA_TAG="${2:?falta la etiqueta}"; shift 2 ;;
      --repo-url) VMA_REPO_URL="${2:?falta la URL}"; shift 2 ;;
      --dominio) VMA_DOMINIO="${2:?falta el dominio}"; shift 2 ;;
      --sin-datos) VMA_SKIP_DATOS=1; shift ;;
      --sin-respaldo) VMA_RESPALDO=""; shift ;;
      --solo-chequeos) solo=1; shift ;;
      --continuar) continuar=1; shift ;;
      --self-test) if self_test; then exit 0; else exit 1; fi ;;
      *) die "opción desconocida: $1" ;;
    esac
  done
  preflight
  tag="$(resolve_tag)"
  addr="$(install_address)"
  [ -n "$addr" ] || die "no se pudo determinar la dirección de esta VM (¿red?)"
  printf 'Aceptación: suite %s desde %s · por %s\n\n' "$tag" "$VMA_REPO_URL" "${VMA_DOMINIO:+dominio }${VMA_DOMINIO:-IP}"
  if [ "$solo" = 0 ]; then
    run_bootstrap "$tag" || { [ "$continuar" = 1 ] || exit 1; }
    bash "$VMA_TREE/scripts/cleanboot-site.sh" "$addr" "$VMA_WORK" \
      || die "no se pudo generar el sitio y la planilla de prueba"
    silent_install "$VMA_WORK/site.sh" "$VMA_WORK/usuarios.csv" || { [ "$continuar" = 1 ] || exit 1; }
  fi
  sudo install -m 0644 "$VMA_ROOT/certificados/ca/aps-conecta-ca.crt" "$ca" 2>/dev/null \
    || die "no se pudo copiar la CA del instalador ($VMA_ROOT/certificados/ca/)"
  printf '\n== Los seis criterios del tiquete ==\n'
  if check_bootstrap "$tag"; then verdict ok "curl | sudo bash" "firma verificada, suite $tag en $VMA_ROOT/instalador"
  else verdict fail "curl | sudo bash" "el registro no muestra el camino verificado ($VMA_WORK/bootstrap.out)"; fi
  if check_estado; then verdict ok "aps-conecta estado" "responde sin sudo"
  else verdict fail "aps-conecta estado" "contestó distinto de cero"; fi
  if check_status_php "$addr" "$ca"; then verdict ok "la suite responde" "https://$addr/status.php instalada, con la CA del instalador"
  else verdict fail "la suite responde" "https://$addr/status.php no contestó instalada con la CA"; fi
  if check_status_refused_bare "$addr"; then verdict ok "solo con la CA" "sin ella, https://$addr se rehúsa"
  else verdict fail "solo con la CA" "sin la CA la suite no se rehusó — postura de certificado"; fi
  pw="$(sealed_password ana.prueba)"
  if [ -n "$pw" ] && check_user_login "$addr" "$ca" ana.prueba "$pw"; then
    verdict ok "el personal entra" "ana.prueba, por OCS, con su contraseña sellada"
  else
    verdict fail "el personal entra" "ana.prueba no pudo entrar por OCS"
  fi
  check_apps "$VMA_APPS" "$addr" "$ca"
  check_optional_record "$VMA_APPS"
  check_buscador "$addr" "$ca" ana.prueba "${pw:-}"
  check_actualizar_revisar
  printf '\nRegistro completo: %s\n' "$VMA_WORK"
  summarize
}

# ── the self-test: hermetic — PATH shims, fixtures in a tmp APS_HOME, no root, no docker ────
# The arms pin the classification, not the plumbing: each check function must say ✓ on a
# healthy fixture and ✗ on a named defect, the way the org's own self-tests do.
self_test() {
  local tmp shims fixtures t ok_n=0 fail_n=0
  tmp="$(mktemp -d)"; shims="$tmp/shims"; fixtures="$tmp/aps"
  mkdir -p "$shims" "$fixtures/instalador/scripts" "$fixtures/apps/territorio" "$fixtures/aio" "$fixtures/certificados/ca"
  trap 'rm -rf "$tmp"' RETURN

  # the shims: sudo runs as-is, docker/aps-conecta/curl answer from fixture files, occ reads
  # key/value files — every check function reaches its world through VMA_* and PATH only
  printf '#!/usr/bin/env bash\nexec "$@"\n' > "$shims/sudo"
  cat > "$shims/aps-conecta" <<'SH'
#!/usr/bin/env bash
# estado: the verdict file answers; actualizar --revisar: the fixture's script decides;
# install: records its args and answers the ✓ line the harness greps
case "$1" in
  estado) exit "$(cat "$SHIM_STATE/estado.rc" 2>/dev/null || echo 0)" ;;
  install) printf '%s\n' "$@" > "$SHIM_STATE/install.args"
            printf 'INSTALACIÓN: ✓ — (shim)\n'; exit 0 ;;
  actualizar) if [ -x "$SHIM_STATE/revisar.hook" ]; then "$SHIM_STATE/revisar.hook"; fi
              cat "$SHIM_STATE/revisar.out" 2>/dev/null
              exit "$(cat "$SHIM_STATE/revisar.rc" 2>/dev/null || echo 0)" ;;
esac
exit 1
SH
  cat > "$shims/occ-shim" <<'SH'
#!/usr/bin/env bash
# occ-shim — answers config queries from occ.<app>.<key> files (app empty for system:get)
# occ grammar: config:app:get <app> <key> | config:system:get <key> | anything else → empty, 0
app=""; key=""
case "$1" in
  config:app:get) app="$2"; key="$3" ;;
  config:system:get) key="$2" ;;
esac
f="$SHIM_STATE/occ.$app.$key"
[ -f "$f" ] && cat "$f"
exit 0
SH
  cat > "$shims/curl" <<'SH'
#!/usr/bin/env bash
# curl shim: --cacert must be present for https; bodies and codes come from fixture files
ca=""
for a in "$@"; do case "$a" in --cacert) ca=1 ;; esac; done
case "$*" in
  *status.php*|*cloud/user*) [ -n "$ca" ] || exit 60
                           cat "${SHIM_STATE}/$(case "$*" in *status.php*) echo status.body;; *) echo user.body;; esac)" 2>/dev/null
                           exit 0 ;;
  *) cat "${SHIM_STATE}/curl.code" 2>/dev/null || echo 200 ;;
esac
SH
  cat > "$shims/docker" <<'SH'
#!/usr/bin/env bash
# docker shim: only the signature.json probe and exec are asked; the fixture answers
[ -f "$SHIM_STATE/signature.json" ] && exit 0
exit 1
SH
  chmod +x "$shims"/*

  export SHIM_STATE="$tmp/state"; mkdir -p "$SHIM_STATE"
  local saved_path="$PATH" saved_root="$VMA_ROOT" saved_tree="$VMA_TREE"
  PATH="$shims:$PATH"
  VMA_ROOT="$fixtures"; VMA_TREE="$fixtures/instalador"
  VMA_OCC_SHIM="$shims/occ-shim"; VMA_DOCKER="$shims/docker"
  VMA_APS="$shims/aps-conecta"; VMA_CURL="$shims/curl"
  VMA_WORK="$tmp/work"; mkdir -p "$VMA_WORK"

  # the healthy corpus: the real manifest, a lock row whose tarball is real bytes, every occ
  # answer a default+chosen install produces, both bootstrap markers, the CA, the sealed sheet
  cp "$(dirname "${BASH_SOURCE[0]}")/../apps.json" "$VMA_TREE/apps.json" 2>/dev/null \
    || cp "$(pwd)/apps.json" "$VMA_TREE/apps.json"
  printf 'los bytes del paquete, verificados\n' > "$fixtures/apps/territorio/v1.2.0.tar.gz"
  local sha; sha="$(sha256sum "$fixtures/apps/territorio/v1.2.0.tar.gz" | cut -d' ' -f1)"
  python3 - "$sha" <<'PY'
import json, os, sys
root = os.environ["VMA_ROOT"]
lock = {"nextcloud": "34.0.5", "apps": {
    "territorio": {"source": "own", "tag": "v1.2.0", "version": "1.2.0", "sha256": sys.argv[1]},
    "farmacia": {"source": "own", "tag": "v0.9.0", "version": "0.9.0", "sha256": sys.argv[1]}}}
json.dump(lock, open(f"{root}/apps.lock.json", "w"), indent=2)
os.makedirs(f"{root}/apps/farmacia", exist_ok=True)
open(f"{root}/apps/farmacia/v0.9.0.tar.gz", "w").write("los bytes del paquete, verificados\n")
PY
  printf 'ana.prueba;Ana;CAFE-secret;si\n' > "$fixtures/credentials.txt"
  printf 'territorio=1\nfarmacia=1\ntalk=0\n' > "$fixtures/aio/opciones"
  printf -- '---\nfirma verificada (signify, clave pública del proyecto)\nSuite v1.0.0 en %s/instalador (paquete verificado en %s/paquete)\n' \
    "$fixtures" "$fixtures" > "$VMA_WORK/bootstrap.out"
  printf '{"installed":true}\n' > "$SHIM_STATE/status.body"
  printf '{"ocs":{"data":{"id":"ana.prueba"}}}\n' > "$SHIM_STATE/user.body"
  printf 'yes\n' > "$SHIM_STATE/occ.calendar.enabled"
  printf '5.0.0\n' > "$SHIM_STATE/occ.calendar.installed_version"
  printf '1.2.0\n' > "$SHIM_STATE/occ.territorio.installed_version"
  printf '0.9.0\n' > "$SHIM_STATE/occ.farmacia.installed_version"
  printf 'intravox\n' > "$SHIM_STATE/occ..defaultapp"

  t() {  # t NAME WANT 'EXPRESSION' — the expression is eval'd IN THIS SHELL, single-quoted,
    # so the arms see the functions and the counters (the house's own self-test idiom)
    local name="$1" want="$2" rc=0
    eval "$3" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$want" ]; then ok_n=$((ok_n + 1)); printf '  ok:   %s\n' "$name"
    else fail_n=$((fail_n + 1)); printf '  FAIL: %s (want %s, got %s)\n' "$name" "$want" "$rc"; fi
  }

  echo "== vm-acceptance self-test =="
  t "bootstrap: green on both markers" 0 'check_bootstrap v1.0.0'
  # a pristine VM's first run: no signify, the honest info line, the same verified path
  cp "$VMA_WORK/bootstrap.out" "$VMA_WORK/bootstrap.out.bak"
  sed -i 's/firma verificada (signify, clave pública del proyecto)/signify no está instalado: la suma de verificación ya probó estos bytes/' "$VMA_WORK/bootstrap.out"
  t "bootstrap: green on the signify-absent honest line" 0 'check_bootstrap v1.0.0'
  mv "$VMA_WORK/bootstrap.out.bak" "$VMA_WORK/bootstrap.out"
  sed -i 's/firma verificada/la firma no llegó/' "$VMA_WORK/bootstrap.out"
  t "bootstrap: red when the marker drifted" 1 'check_bootstrap v1.0.0'
  sed -i 's/la firma no llegó/firma verificada/' "$VMA_WORK/bootstrap.out"
  t "bootstrap: red on the wrong tag" 1 'check_bootstrap v9.9.9'
  t "release five: green on the healthy row" 0 'check_release_app territorio'
  printf '1.1.0\n' > "$SHIM_STATE/occ.territorio.installed_version"
  t "release five: red when the instance runs another version" 1 'check_release_app territorio'
  printf '1.2.0\n' > "$SHIM_STATE/occ.territorio.installed_version"
  rm "$fixtures/apps/territorio/v1.2.0.tar.gz"
  t "release five: red when the tarball is gone" 1 'check_release_app territorio'
  printf 'bytes distintos\n' > "$fixtures/apps/territorio/v1.2.0.tar.gz"
  t "release five: red when the bytes are not the locked ones" 1 'check_release_app territorio'
  rm "$fixtures/apps/territorio/v1.2.0.tar.gz"
  printf 'los bytes del paquete, verificados\n' > "$fixtures/apps/territorio/v1.2.0.tar.gz"
  touch "$SHIM_STATE/signature.json"
  t "release five: red when signature.json rides the app" 1 'check_release_app territorio'
  rm "$SHIM_STATE/signature.json"
  t "store app: green enabled with a version" 0 'check_store_app calendar'
  printf 'no\n' > "$SHIM_STATE/occ.calendar.enabled"
  t "store app: red when disabled" 1 'check_store_app calendar'
  printf 'yes\n' > "$SHIM_STATE/occ.calendar.enabled"
  t "manifest: the walk reads every row" 0 '[ "$(manifest_rows | wc -l)" -ge 12 ]'
  t "manifest: every row answers its source" 0 'manifest_rows | grep -qxP "\w+\t(own|fork|store)\t[01]" || false'
  # Talk off (the record the silent install writes): spreed's absence is the contract — and a
  # lock row for it reds, the way Clean boot's IP job asserts the same posture
  t "apps walk: Talk-off absence is a green verdict" 0 'check_apps "$VMA_APPS" 10.0.0.9 "$VMA_WORK/ca.crt" 2>/dev/null | grep "Talk apagado: spreed totalmente ausente" >/dev/null'
  python3 - <<'PY'
import json, os
p = os.path.join(os.environ["VMA_ROOT"], "apps.lock.json")
d = json.load(open(p))
d["apps"]["spreed"] = {"source": "fork", "tag": "v21.0.0", "version": "21.0.0", "sha256": "x"}
json.dump(d, open(p, "w"), indent=2)
PY
  t "apps walk: a spreed lock row with Talk off reds" 0 'check_apps "$VMA_APPS" 10.0.0.9 "$VMA_WORK/ca.crt" 2>/dev/null | grep "Talk apagado exige ausencia total de spreed" >/dev/null'
  python3 - <<'PY'
import json, os
p = os.path.join(os.environ["VMA_ROOT"], "apps.lock.json")
d = json.load(open(p))
del d["apps"]["spreed"]
json.dump(d, open(p, "w"), indent=2)
PY
  t "status.php: green through the CA" 0 'check_status_php 10.0.0.9 "$VMA_WORK/ca.crt"'
  t "user login: green on the OCS body" 0 'check_user_login 10.0.0.9 "$VMA_WORK/ca.crt" ana.prueba CAFE-secret'
  printf '{"ocs":{"data":{"id":"otra.persona"}}}\n' > "$SHIM_STATE/user.body"
  t "user login: red when the id is not the session's" 1 'check_user_login 10.0.0.9 "$VMA_WORK/ca.crt" ana.prueba CAFE-secret'
  printf '{"ocs":{"data":{"id":"ana.prueba"}}}\n' > "$SHIM_STATE/user.body"
  t "route alive: 200 answers alive" 0 'check_route_alive 10.0.0.9 "$VMA_WORK/ca.crt" /x'
  printf '502\n' > "$SHIM_STATE/curl.code"
  t "route alive: a 502 is not alive" 1 'check_route_alive 10.0.0.9 "$VMA_WORK/ca.crt" /x'
  printf '200\n' > "$SHIM_STATE/curl.code"
  t "estado: green when the CLI answers 0" 0 'check_estado'
  printf '1\n' > "$SHIM_STATE/estado.rc"
  t "estado: red when the CLI answers 1" 1 'check_estado'
  printf '0\n' > "$SHIM_STATE/estado.rc"

  # actualizar --revisar: the plan, nothing written — and the three named defects
  printf 'Plan de actualización (modo --revisar: nada se escribe ni se cambia)\nterritorio v1.2.0 (sin cambios)\n' \
    > "$SHIM_STATE/revisar.out"; printf '0\n' > "$SHIM_STATE/revisar.rc"
  CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_SKIP=0
  check_actualizar_revisar >/dev/null
  t "revisar: ok verdict on the plan that writes nothing" 0 '[ "$CHECKS_OK" = 1 ] && [ "$CHECKS_FAIL" = 0 ]'
  printf '1\n' > "$SHIM_STATE/revisar.rc"
  CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_SKIP=0
  check_actualizar_revisar >/dev/null
  t "revisar: red verdict when the command fails" 0 '[ "$CHECKS_FAIL" = 1 ]'
  printf '0\n' > "$SHIM_STATE/revisar.rc"
  printf 'el plan no se imprimió\n' > "$SHIM_STATE/revisar.out"
  CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_SKIP=0
  check_actualizar_revisar >/dev/null
  t "revisar: red verdict without the plan lines" 0 '[ "$CHECKS_FAIL" = 1 ]'
  printf 'Plan de actualización (modo --revisar: nada se escribe ni se cambia)\n' > "$SHIM_STATE/revisar.out"
  cat > "$SHIM_STATE/revisar.hook" <<'HOOK'
#!/usr/bin/env bash
printf 'reescrita\n' > "$VMA_ROOT/apps.lock.json"
HOOK
  chmod +x "$SHIM_STATE/revisar.hook"
  CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_SKIP=0
  check_actualizar_revisar >/dev/null
  t "revisar: red verdict when the lock moved" 0 '[ "$CHECKS_FAIL" = 1 ]'
  rm "$SHIM_STATE/revisar.hook"

  # buscador: the manifest carries no row today — the verdict names #149, never a silent skip
  CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_SKIP=0
  check_buscador 10.0.0.9 "$VMA_WORK/ca.crt" ana.prueba CAFE-secret >/dev/null
  t "buscador: the absent row is a red naming #149" 0 '[ "$CHECKS_FAIL" = 1 ]'

  # resolve_tag: the redirect resolves, the failure dies — both without the API
  cat > "$shims/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "https://example.org/releases/tag/v0.9.9"
SH
  chmod +x "$shims/curl"
  t "resolve_tag: latest resolves by redirect" 0 '[ "$(resolve_tag)" = v0.9.9 ]'
  printf '#!/usr/bin/env bash\nexit 22\n' > "$shims/curl"; chmod +x "$shims/curl"
  # a subshell: resolve_tag's die exits the probe, never this shell
  t "resolve_tag: an unreachable redirect dies, naming --tag" 2 '( VMA_TAG=latest resolve_tag )'

  # the silent install drives the wizard the way a clinic does: the daily backup configured
  # (criterion 6's precondition — actualizar refuses without one, by design #46), the chosen
  # optional apps as --app pairs, and --sin-respaldo honestly leaving it out
  t "install: drives the wizard with the daily backup configured" 0 \
    'silent_install "$SHIM_STATE/site.sh" "$SHIM_STATE/usuarios.csv" >/dev/null 2>&1 && grep -qx -- "--respaldo" "$SHIM_STATE/install.args" && grep -qx "$VMA_ROOT/respaldos" "$SHIM_STATE/install.args"'
  t "install: the chosen optionals ride their own --app pairs" 0 \
    'grep -c -- "--app" "$SHIM_STATE/install.args" | grep -qx 3'
  local saved_respaldo="$VMA_RESPALDO"
  VMA_RESPALDO=""
  t "install: --sin-respaldo leaves the wizard without a backup" 0 \
    'silent_install "$SHIM_STATE/site.sh" "$SHIM_STATE/usuarios.csv" >/dev/null 2>&1 && ! grep -q -- "--respaldo" "$SHIM_STATE/install.args"'
  VMA_RESPALDO="$saved_respaldo"

  PATH="$saved_path"; VMA_ROOT="$saved_root"; VMA_TREE="$saved_tree"
  printf 'self-test: %d ok, %d fail\n' "$ok_n" "$fail_n"
  [ "$fail_n" -eq 0 ]
}

main "$@"
