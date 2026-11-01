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
#   --sin-respaldo  drive the wizard without the daily backup (criterion 5 will red: actualizar
#                refuses without a configured backup, by design) — the honest no-backup posture
#   --solo-chequeos  re-run only the checks against an already-installed VM
#   --continuar  run the checks even when the install step fails (a red named, not a stop)
#
# The ticket's five criteria, each asserted on what an administrator observes:
#   1. the bootstrap verified the package's signature and landed the suite at /opt/aps-conecta;
#   2. «aps-conecta estado» answers, the suite answers at https://<address>/ through the
#      installer's CA (and refuses without it), and a planilla user logs in over OCS;
#   3. every default app in apps.json is installed — own/fork apps from their own release at
#      the locked tag (tarball, hash, no signature.json), store apps enabled — the landing app
#      is IntraVox, and the two functional opens answer (notify_push, the office connector);
#   4. each optional app chosen at the command line is installed from its release, and the
#      wizard's options record still names the choice;
#   5. «aps-conecta actualizar --revisar» prints the plan and writes nothing.
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
VMA_INSTALL_ENV="${VMA_INSTALL_ENV:-}"             # extra K=V pairs for the install (a rehearsal's APS_SUITE_TAG)
VMA_RESPALDO="${VMA_RESPALDO-1}"                   # the daily backup a real clinic configures in the wizard (§11):
                                                     # 1 = "$VMA_ROOT/respaldos"; a path = that path; empty = none
                                                     # (an install without it cannot pass criterion 5 — actualizar
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
  local chosen=" $1 " id source optional detalle
  while IFS=$'\t' read -r id source optional; do
    [ -n "$id" ] || continue
    detalle=""
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
  # the two functional opens Clean boot also runs
  if occ notify_push:self-test >/dev/null 2>&1; then verdict ok "notify_push responde su self-test"
  else verdict fail "notify_push" "occ notify_push:self-test — el empuje de notificaciones"; fi
  if occ eurooffice:documentserver --check >/dev/null 2>&1; then verdict ok "la oficina responde (eurooffice --check)"
  else verdict fail "la oficina" "occ eurooffice:documentserver --check — #140/#147: la primera instalación enrojece sin su arreglo"; fi
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

# ── 5. actualizar --revisar: the plan on the table, nothing moved ───────────────────────────
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
preflight() {  # $1 = solo (1: checks only — the suite OWNS the ports, they must not be free)
  [ "$(id -u)" = 0 ] || die "corra como root (sudo) — el instalador lo exige"
  local os port busy="" gb
  os="$(bash -c '. /etc/os-release 2>/dev/null; printf "%s %s" "${NAME:-}" "${VERSION_ID:-}"')"
  printf 'VM: %s · %s · %d GB libres\n' "$os" "$(uname -m)" "$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')"
  case "$os" in *"Ubuntu 24.04"*) ;; *) printf 'AVISO: el tiquete nombra Ubuntu 24.04 — esto es «%s»; se continúa\n' "$os" ;; esac
  if [ "${1:-0}" != 1 ]; then
    for port in 8080 443 3478; do ss -tln 2>/dev/null | grep -q ":$port " && busy="$busy $port"; done
    [ -z "$busy" ] || die "puertos ocupados:$busy — la suite los necesita libres"
  fi
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
  preflight "$solo"
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
  printf '\n== Los cinco criterios del tiquete ==\n'
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
            rc="$(cat "$SHIM_STATE/install.rc" 2>/dev/null || echo 0)"
            [ "$rc" = 0 ] || exit "$rc"
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
# curl shim: --cacert must be present for https; bodies come from fixture files; any other URL answers 200
ca=""
for a in "$@"; do case "$a" in --cacert) ca=1 ;; esac; done
case "$*" in
  *status.php*|*cloud/user*) [ -n "$ca" ] || exit 60
                           cat "${SHIM_STATE}/$(case "$*" in *status.php*) echo status.body;; *) echo user.body;; esac)" 2>/dev/null
                           exit 0 ;;
  *) echo 200 ;;
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
  t "apps walk: a missing signed Talk release is a failure verdict" 0 'check_apps "$VMA_APPS" 10.0.0.9 "$VMA_WORK/ca.crt" 2>/dev/null | grep "^  ✗ app spreed — " >/dev/null'
  t "status.php: green through the CA" 0 'check_status_php 10.0.0.9 "$VMA_WORK/ca.crt"'
  t "user login: green on the OCS body" 0 'check_user_login 10.0.0.9 "$VMA_WORK/ca.crt" ana.prueba CAFE-secret'
  printf '{"ocs":{"data":{"id":"otra.persona"}}}\n' > "$SHIM_STATE/user.body"
  t "user login: red when the id is not the session's" 1 'check_user_login 10.0.0.9 "$VMA_WORK/ca.crt" ana.prueba CAFE-secret'
  printf '{"ocs":{"data":{"id":"ana.prueba"}}}\n' > "$SHIM_STATE/user.body"
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

  # Drive the real main path with a failed command and otherwise healthy checks.
  python3 - "$VMA_TREE/apps.json" "$fixtures" "$SHIM_STATE" <<'PY'
import hashlib, json, pathlib, sys
manifest, root, state = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
lock = {"nextcloud": "34.0.5", "apps": {}}
for app in json.loads(manifest.read_text()):
    app_id = app["id"]
    (state / f"occ.{app_id}.installed_version").write_text("1.2.0\n")
    (state / f"occ.{app_id}.enabled").write_text("yes\n")
    if app["source"] != "store":
        package = root / "apps" / app_id / "v1.2.0.tar.gz"
        package.parent.mkdir(parents=True, exist_ok=True)
        package.write_bytes(b"verified fixture package\n")
        lock["apps"][app_id] = {"source": app["source"], "tag": "v1.2.0", "version": "1.2.0",
                                "sha256": hashlib.sha256(package.read_bytes()).hexdigest()}
(root / "apps.lock.json").write_text(json.dumps(lock))
PY
  printf 'farmacia=1\nestadistica=1\ntotem=1\n' > "$fixtures/aio/opciones"
  printf 'fixture CA\n' > "$fixtures/certificados/ca/aps-conecta-ca.crt"
  printf 'Plan de actualización (modo --revisar: nada se escribe ni se cambia)\n' > "$SHIM_STATE/revisar.out"
  printf '#!/bin/sh\nexit 0\n' > "$VMA_TREE/scripts/cleanboot-site.sh"
  cat > "$SHIM_STATE/bootstrap.sh" <<'SH'
#!/bin/sh
printf 'firma verificada (signify, clave pública del proyecto)\n'
printf 'Suite v1.0.0 en %s/instalador (paquete verificado en %s/paquete)\n' "$VMA_ROOT" "$VMA_ROOT"
exit 0
SH
  cp "$shims/curl" "$SHIM_STATE/healthy-curl"
  cat > "$shims/curl" <<'SH'
#!/bin/sh
case "$*" in
  */releases/download/*-install.sh*) cat "$SHIM_STATE/bootstrap.sh" ;;
  *) exec "$SHIM_STATE/healthy-curl" "$@" ;;
esac
SH
  printf '#!/bin/sh\nprintf "Filesystem 1G-blocks Used Available Use%% Mounted on\\nfixture 40G 10G 30G 25%% /\\n"\n' > "$shims/df"
  printf '#!/bin/sh\necho 0\n' > "$shims/id"
  printf '#!/bin/sh\necho "1.1.1.1 dev eth0 src 10.0.0.9"\n' > "$shims/ip"
  printf '#!/bin/sh\nexit 0\n' > "$shims/ss"
  chmod +x "$shims"/* "$SHIM_STATE/healthy-curl"
  printf '7\n' > "$SHIM_STATE/install.rc"
  local main_rc=0
  ( CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_SKIP=0; main --tag v1.0.0 --continuar ) > "$SHIM_STATE/main.out" 2>&1 || main_rc=$?
  t "main: a failed installation stays red when later checks pass" 0 \
    '[ "$main_rc" = 1 ] && grep -q "✗ la instalación silenciosa" "$SHIM_STATE/main.out" && grep -q "^Veredicto:" "$SHIM_STATE/main.out"'
  printf '0\n' > "$SHIM_STATE/install.rc"

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
  # (criterion 5's precondition — actualizar refuses without one, by design #46), the chosen
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
