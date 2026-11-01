#!/usr/bin/env bash
# install.sh — the clinic's one-line entry (FRD S1: one signed tarball per suite tag + a
# one-line bootstrap that unpacks, verifies sha256, starts the wizard).
#
#   curl -fsSL "$REPO_URL/releases/latest/download/apsconecta-install.sh" | sudo --preserve-env=HTTPS_PROXY,HTTP_PROXY,NO_PROXY,https_proxy,http_proxy,no_proxy bash
#
# TRUST (the cargo-dist/Astral model, astral.sh/uv/install.sh): the one-liner's anchor is the
# STABLE-NAME latest URL + TLS, and the tag pin travels INSIDE the bytes — this script embeds
# BUNDLE_TAG and the package's expected sha256, set by the release job (scripts/package-release.sh)
# when it cuts the asset (the versioned twin apsconecta-<tag>-install.sh ships beside the alias
# for tag-pinned installs and audits, aps/RELEASING.md §6). The signature is
# verified NOW when the host already carries `signify` (before anything unpacks — the minted
# key is the constant below), and later by `aps-conecta preflight` on fresh hosts, once
# `preparar` installs signify-openbsd (Ubuntu universe / Debian main): a fresh host needs no
# crypto tool to be safe — it needs the bytes to match the number this tag-anchored script
# carries. The pubkey is embedded below,
# committed at installer.pub, and printed by the wizard; aps/RELEASING.md owns the key story.
#
# `main(){}` wraps everything (Docker's get.docker.com guard): a truncated download is a syntax
# error, never a half-executed installer. Code/comments English; the operator's lines es-CL
# (the house register rule — this file talks to the person at the console).
#
# The COMMITTED form refuses: TARBALL_SHA256 ships empty and only the release asset, its two
# constants filled by the release job, executes — BUNDLE_TAG's discipline, and a placeholder is
# a bug, not a state (the VENDOR sha256 precedent).
#
# shellcheck disable=SC2016,SC2034  # the self-test's check arms and shim sources are
#                             single-quoted on purpose (check() evals them later, so their $VARs
#                             are data), and the arms' rc/out locals read only inside those eval'd
#                             strings — invisible to static use-tracking (SIGNIFY_PUBKEY below is
#                             the one non-test case: a cross-file constant package-release.sh reads)
set -euo pipefail

BUNDLE_TAG="v0.6.0"             # the release commit sets this beside aps/CHANGELOG's dated entry
TARBALL_SHA256=""               # ← the release job fills this; empty = the committed form, refuse
# shellcheck disable=SC2034  # a cross-file constant: package-release.sh reads it back when filling
                              # the asset, and preflight/wizard print it — never dereferenced here
SIGNIFY_PUBKEY="RWTLqv+WUjHCKc4S0crtk33Otcda2exszJdn6BBvGPmZEcTbVRrVn9kK"  # installer.pub's base64 line — both readers flip together (aps/RELEASING.md §1)
APS_HOME="${APS_HOME:-/opt/aps-conecta}"
REPO_URL="${REPO_URL:-https://github.com/APS-Conecta/gestion}"
DEST="$APS_HOME/instalador"     # the bundle home (an old gestion clone beside it is inert: no path reads it)
PAQUETE="$APS_HOME/paquete"     # the kept package: preflight re-verifies sha+firma offline
KEEP_PACKAGE="${KEEP_PACKAGE:-1}"  # 0 (rehearsal) frees the disk right after unpacking

die()  { echo "✗ $*" >&2; exit 1; }
ok()   { printf '✓ %s\n' "$*"; }
info() { printf '· %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 \
           || die "falta $1 en este servidor: instálelo (sudo apt-get install -y $1) y vuelva a ejecutar el instalador"; }

main() {
  [ "$(id -u)" = 0 ] || die "el instalador necesita permisos de administrador: use sudo --preserve-env=HTTPS_PROXY,HTTP_PROXY,NO_PROXY,https_proxy,http_proxy,no_proxy bash después de curl"
  need curl; need tar; need sha256sum

  [ -n "$TARBALL_SHA256" ] \
    || die "este archivo es la copia del repositorio (sin la suma del paquete): descargue el instalador de la versión $BUNDLE_TAG — $REPO_URL/releases"

  local tag pkg base found tmp mint verifier
  tag="$BUNDLE_TAG"
  base="$REPO_URL/releases/download/$tag"
  pkg="$PAQUETE/apsconecta-$tag.tar.gz"
  mkdir -p "$PAQUETE" || die "no pude crear $PAQUETE"

  # an existing bundle: continue from it — the CLI re-enters any step, never a second copy
  if [ -d "$DEST/host" ]; then
    found="$(head -1 "$DEST/VERSION" 2>/dev/null || true)"
    if [ "$found" = "$tag" ]; then
      ok "la suite $tag ya está en $DEST — continúe: sudo bash $DEST/host/aps-conecta install"
      return 0
    fi
    die "ya existe una instalación en $DEST (versión ${found:-desconocida}), distinta de $tag — no se modifica: una actualización es deliberada (aps/INSTALLER.md §10); continúe desde esa copia con «sudo bash $DEST/host/aps-conecta install»"
  fi
  [ ! -e "$DEST" ] || die "$DEST ya existe y no es una copia de la suite — muévalo (sudo mv $DEST $DEST.anterior) y vuelva a ejecutar"

  # download → verify (inside the pipe, before anything unpacks) → unpack atomically → hand over.
  # A cached package that still hashes right is reused — a re-run of the one-liner re-downloads
  # nothing (the channel opens only when the bytes are wrong or absent).
  if [ ! -f "$pkg" ] || ! echo "$TARBALL_SHA256  $pkg" | sha256sum --check --status; then
    info "descargando el paquete $tag (unos minutos)"
    curl -fSL --retry 2 -o "$pkg" "$base/apsconecta-$tag.tar.gz" \
      || die "no pude descargar el paquete $tag — revise la red: $base"
  fi
  echo "$TARBALL_SHA256  $pkg" | sha256sum --check --status \
    || die "el paquete descargado no coincide con su suma de verificación — no se instala nada; vuelva a ejecutar el instalador"
  # belt and braces (the two-readers rule, env.sh's lesson): the release's own SHA256SUMS must
  # carry the SAME number this script embeds — a drifted asset and a drifted script cannot both
  # pass; and the .minisig is kept beside them for preflight's signify verification later.
  curl -fsSL -o "$PAQUETE/SHA256SUMS" "$base/SHA256SUMS" \
    || die "no pude descargar SHA256SUMS — revise la red: $base"
  grep -qx "$TARBALL_SHA256  apsconecta-$tag.tar.gz" "$PAQUETE/SHA256SUMS" \
    || die "SHA256SUMS de la versión no coincide con la suma de este instalador — la versión está inconsistente; repórtelo"
  curl -fsSL -o "$PAQUETE/SHA256SUMS.minisig" "$base/SHA256SUMS.minisig" \
    || die "no pude descargar la firma — revise la red: $base"

  # A host that already carries signify verifies the signature BEFORE anything unpacks —
  # the minted pubkey file is the constant above (the same key installer.pub commits and the
  # release job proves in CI; two readers, one key). A fresh host skips it honestly: the
  # sha256 above already anchored the bytes to this tag-anchored script, and the suite's
  # «preparar» installs signify-openbsd so preflight verifies the kept package from the next
  # run on. A bad signature installs nothing — stronger than the sha, not weaker.
  verifier="$(command -v signify-openbsd || command -v signify || true)"
  if [ -n "$verifier" ]; then
    mint="$PAQUETE/.installer.pub"
    printf 'untrusted comment: APS Conecta instalador release key\n%s\n' "$SIGNIFY_PUBKEY" > "$mint"
    if ( cd "$PAQUETE" && "$verifier" -V -p "$mint" -m SHA256SUMS -x SHA256SUMS.minisig ) >/dev/null 2>&1; then
      ok "firma verificada (signify, clave pública del proyecto)"
    else
      rm -f "$mint"
      die "la firma del paquete no verifica contra la clave de este instalador — no se instala nada; descargue el instalador de nuevo: $REPO_URL/releases"
    fi
    rm -f "$mint"
  else
    info "signify no está instalado: la suma de verificación ya probó estos bytes; el paso «preparar» instala signify-openbsd y la firma del paquete guardado se verifica desde la próxima corrida"
  fi

  # the package root carries instalador/ (package-release.sh's assembly contract); the unpack
  # is atomic: a failed run never clobbers, and nothing half-unpacked becomes
  # the bundle — VERSION is asserted == the tag before the mv promotes the tree
  tmp="$(mktemp -d "$APS_HOME/.instalador.XXXXXX")" || die "no pude crear el directorio de trabajo"
  if ! tar -xzf "$pkg" -C "$tmp"; then
    rm -rf "$tmp"; die "el paquete no se pudo desempacar — vuelva a ejecutar el instalador (un paquete dañado nunca se instala)"
  fi
  [ -f "$tmp/instalador/host/aps-conecta" ] \
    || { rm -rf "$tmp"; die "el paquete no trae la suite (falta instalador/host/aps-conecta) — repórtelo"; }
  [ "$(head -1 "$tmp/instalador/VERSION" 2>/dev/null)" = "$tag" ] \
    || { rm -rf "$tmp"; die "la versión dentro del paquete no es $tag — la versión está inconsistente; repórtelo"; }
  # Inspect the old installation state before promotion can hide a missing bundle.
  if ! APS_HOME="$APS_HOME" bash "$tmp/instalador/host/aps-conecta" guard-existing-installation; then
    rm -rf "$tmp"
    die "la revisión de la instalación existente detuvo el arranque; conserve sus contenedores y datos y corrija lo indicado arriba"
  fi
  if ! APS_HOME="$APS_HOME" bash "$tmp/instalador/host/aps-conecta" proxy-save; then
    rm -rf "$tmp"; die "no pude guardar la configuración del proxy — no se instala la suite"
  fi
  ( umask 022 && mv "$tmp/instalador" "$DEST" ) \
    || { rm -rf "$tmp"; die "no pude instalar la suite en $DEST"; }
  rm -rf "$tmp"
  [ "$KEEP_PACKAGE" = 1 ] || rm -f "$pkg" "$PAQUETE/SHA256SUMS" "$PAQUETE/SHA256SUMS.minisig"
  ok "Suite $tag en $DEST (paquete verificado en $PAQUETE)"
  ok "Continúe con: sudo bash $DEST/host/aps-conecta install"
}

# ── self-test — PATH shims and fixture bytes only: no network, no root state, no /opt writes ──
# The arms prove the real arms of main() — run in command-substitution subshells so a prefix
# assignment never outlives its arm (the CLI's own control-knob lesson, aps-conecta:2396-2398)
# and a failing main dies inside the subshell, never the test run (|| rc=$? keeps errexit out
# of the verdict).
selftest() {
  local n=0 tmp tshim out rc pkgsha source_root
  source_root="$(cd "${1:-$(dirname "$0")}" && pwd)"
  tmp="$(mktemp -d)"; tshim="$tmp/bin"; mkdir -p "$tshim"
  check() { n=$((n + 1)); if eval "$2"; then :; else echo "  FAIL: $1" >&2; FAILED=$((FAILED + 1)); fi; }
  FAILED=0
  export PATH="$tshim:/usr/sbin:/usr/bin:/bin"
  # the restricted bin: main() now probes for signify opportunistically, and a host that
  # carries the real one must never leak into an arm (package-release's own self-test asks
  # for it installed; run_main routes every main() call through this PATH, and the arms
  # control signify solely by the shim's presence on $tshim)
  imin="$tmp/imin"; mkdir -p "$imin"
  for c in bash env cp mkdir rm mv mktemp tar gzip sha256sum head cut cat sed grep dirname readlink; do
    ln -sf "$(command -v "$c")" "$imin/$c"
  done

  # id answers root by default (install needs it); an arm plays non-root with ID_U
  printf '#!/usr/bin/env bash\ncase "$1" in -u) echo "${ID_U:-0}" ;; esac\n' > "$tshim/id"; chmod +x "$tshim/id"

  # the fixture package: instalador/{VERSION,host/aps-conecta} — the assembly contract
  mkdir -p "$tmp/fx/instalador/host"
  printf 'v9.8.7\n' > "$tmp/fx/instalador/VERSION"
  printf '#!/usr/bin/env bash\necho suite-ok\n' > "$tmp/fx/instalador/host/aps-conecta"
  tar -czf "$tmp/fx/fixture.tar.gz" -C "$tmp/fx" instalador
  pkgsha="$(sha256sum "$tmp/fx/fixture.tar.gz" | cut -d' ' -f1)"
  printf '%s  apsconecta-v9.8.7.tar.gz\n' "$pkgsha" > "$tmp/fx/SHA256SUMS"

  # curl serves the three release assets from the fixture (never the network)
  cat > "$tshim/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
last=""; dest=""
for a in "$@"; do [ "$last" = "-o" ] && dest="$a"; last="$a"; done
case "$*" in
  *apsconecta-v9.8.7.tar.gz*)  [ -n "$dest" ] && cp "$FIXDIR/fixture.tar.gz" "$dest" ;;
  *SHA256SUMS.minisig*)        [ -n "$dest" ] && printf 'firma-fixture\n' > "$dest" ;;
  *SHA256SUMS*)                [ -n "$dest" ] && cp "$FIXDIR/SHA256SUMS" "$dest" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$tshim/curl"

  run_main() {  # HOME TAG SHA — main in a subshell against the fixture world (DEST/PAQUETE
    # ride the env too: main reads the globals the file computes at load time, so the
    # per-arm APS_HOME reaches them only as the same call-time bindings main sees)
    rc=0; out="$( APS_HOME="$1" DEST="$1/instalador" PAQUETE="$1/paquete" \
                  REPO_URL="https://fixture.invalid" KEEP_PACKAGE=1 \
                  PATH="$tshim:$imin" CURL_LOG="$tmp/curl.log" FIXDIR="$tmp/fx" \
                  SIG_LOG="$tmp/sig.log" SIG_RC="$tmp/sig.rc" \
                  BUNDLE_TAG="$2" TARBALL_SHA256="$3" main 2>&1 )" || rc=$?
  }

  : > "$tmp/curl.log"
  run_main "$tmp/h0" v9.8.7 ""
  check "committed form: refuses without the sha, naming the release page, touching nothing" \
    '[ "$rc" -ne 0 ] && case "$out" in *"la copia del repositorio"*"releases"*) ;; *) false;; esac && [ ! -e "$tmp/h0/instalador" ]'

  run_main "$tmp/h1" v9.8.7 "$pkgsha"
  check "round trip: verified, unpacked to instalador/, VERSION asserted, package kept, handover line" \
    '[ "$rc" -eq 0 ] && [ "$(head -1 "$tmp/h1/instalador/VERSION")" = v9.8.7 ] \
      && [ -f "$tmp/h1/instalador/host/aps-conecta" ] \
      && [ -f "$tmp/h1/paquete/apsconecta-v9.8.7.tar.gz" ] \
      && [ -f "$tmp/h1/paquete/SHA256SUMS.minisig" ] \
      && case "$out" in *"✓ Suite v9.8.7 en $tmp/h1/instalador"*"sudo bash $tmp/h1/instalador/host/aps-conecta install"*) ;; *) false;; esac'

  : > "$tmp/curl.log"
  run_main "$tmp/h1" v9.8.7 "$pkgsha"
  check "re-run: same tag already installed — continues, opens no channel" \
    '[ "$rc" -eq 0 ] && [ ! -s "$tmp/curl.log" ] && case "$out" in *"ya está en $tmp/h1/instalador"*) ;; *) false;; esac'

  cat > "$tshim/signify" <<'EOF'
#!/usr/bin/env bash
printf 'cwd=%s %s
' "$(pwd)" "$*" >> "$SIG_LOG"
[ "$2" = -p ] && printf 'pub2=%s
' "$(sed -n 2p "$3")" >> "$SIG_LOG"
exit "$(cat "$SIG_RC" 2>/dev/null || echo 0)"
EOF
  chmod +x "$tshim/signify"
  : > "$tmp/sig.log"; echo 0 > "$tmp/sig.rc"
  run_main "$tmp/h6" v9.8.7 "$pkgsha"
  check "signature: a host with signify verifies before unpacking — the minted two-line key (the script's own constant), cwd at the package, and the ok line" \
    '[ "$rc" -eq 0 ] && [ -f "$tmp/h6/instalador/host/aps-conecta" ] \
     && grep -q "^cwd=$tmp/h6/paquete -V -p $tmp/h6/paquete/.installer.pub -m SHA256SUMS -x SHA256SUMS.minisig$" "$tmp/sig.log" \
     && grep -q "^pub2=$(sed -n "s/^SIGNIFY_PUBKEY=\"\([^\"]*\)\".*/\1/p" "$0" | head -1)$" "$tmp/sig.log" \
     && case "$out" in *"✓ firma verificada (signify, clave pública del proyecto)"*) ;; *) false;; esac \
     && [ ! -e "$tmp/h6/paquete/.installer.pub" ]'
  cp "$tshim/signify" "$tshim/signify-openbsd"
  printf '#!/usr/bin/env bash\nexit 73\n' > "$tshim/signify"
  run_main "$tmp/h6-openbsd" v9.8.7 "$pkgsha"
  check "signature: the OpenBSD verifier takes precedence over an unrelated signify executable (#141)" \
    '[ "$rc" -eq 0 ] && [ -f "$tmp/h6-openbsd/instalador/host/aps-conecta" ] \
     && case "$out" in *"✓ firma verificada"*) ;; *) false;; esac'
  rm -f "$tshim/signify"
  run_main "$tmp/h6-openbsd-only" v9.8.7 "$pkgsha"
  check "signature: the package-specific executable verifies without a generic bridge (#141)" \
    '[ "$rc" -eq 0 ] && case "$out" in *"✓ firma verificada"*) ;; *) false;; esac'
  mv "$tshim/signify-openbsd" "$tshim/signify"
  echo 1 > "$tmp/sig.rc"
  run_main "$tmp/h7" v9.8.7 "$pkgsha"
  check "signature: a signature that does not verify installs NOTHING — the refusal names the release page" \
    '[ "$rc" -ne 0 ] && [ ! -e "$tmp/h7/instalador" ] \
     && case "$out" in *"✗ la firma del paquete no verifica contra la clave de este instalador"*"https://fixture.invalid/releases"*) ;; *) false;; esac'
  rm -f "$tshim/signify"
  run_main "$tmp/h8" v9.8.7 "$pkgsha"
  check "signature: a host without signify takes the honest info — the sha already anchored the bytes, the install goes on" \
    '[ "$rc" -eq 0 ] && [ -f "$tmp/h8/instalador/host/aps-conecta" ] \
     && case "$out" in *"· signify no está instalado"*"signify-openbsd"*) ;; *) false;; esac'
  run_main "$tmp/h1" v9.9.9 "$pkgsha"
  check "other version: refused and left untouched (VERSION is the version now, no git)" \
    '[ "$rc" -ne 0 ] && [ "$(head -1 "$tmp/h1/instalador/VERSION")" = v9.8.7 ] \
      && case "$out" in *"distinta de v9.9.9"*"no se modifica"*) ;; *) false;; esac'

  rc=0; out="$( ID_U=1000 APS_HOME="$tmp/h2" REPO_URL="https://fixture.invalid" \
                CURL_LOG="$tmp/curl.log" FIXDIR="$tmp/fx" \
                BUNDLE_TAG=v9.8.7 TARBALL_SHA256="$pkgsha" main 2>&1 )" || rc=$?
  check "without sudo it refuses before anything runs" \
    '[ "$rc" -ne 0 ] && case "$out" in *"permisos de administrador"*) ;; *) false;; esac && [ ! -e "$tmp/h2" ]'

  printf 'x' >> "$tmp/fx/fixture.tar.gz"
  run_main "$tmp/h3" v9.8.7 "$pkgsha"
  check "sha mismatch: installs nothing, says so" \
    '[ "$rc" -ne 0 ] && [ ! -e "$tmp/h3/instalador" ] && case "$out" in *"no coincide con su suma de verificación"*) ;; *) false;; esac'
  truncate -s -1 "$tmp/fx/fixture.tar.gz"   # revert (flip-then-revert)

  printf '0000000000000000000000000000000000000000000000000000000000000000  apsconecta-v9.8.7.tar.gz\n' > "$tmp/fx/SHA256SUMS"
  run_main "$tmp/h4" v9.8.7 "$pkgsha"
  check "SUMS parity: a drifted SHA256SUMS reds — two readers must agree" \
    '[ "$rc" -ne 0 ] && case "$out" in *"inconsistente"*) ;; *) false;; esac && [ ! -e "$tmp/h4/instalador" ]'
  printf '%s  apsconecta-v9.8.7.tar.gz\n' "$pkgsha" > "$tmp/fx/SHA256SUMS"   # revert

  mkdir -p "$tmp/h5/instalador/restos"
  run_main "$tmp/h5" v9.8.7 "$pkgsha"
  check "non-suite DEST: the move hint, never a download" \
    '[ "$rc" -ne 0 ] && case "$out" in *"sudo mv $tmp/h5/instalador"*) ;; *) false;; esac && case "$out" in *"revise la red"*) false;; *) true;; esac'

  check "truncation guard: main \"\$@\" is the file's last line (a half download cannot half-run)" \
    '[ "$(tail -1 "$0")" = "main \"\$@\"" ]'
  check "pubkey shape: installer.pub is two lines and its key line is a real signify key's shape (base64, 42 bytes, no padding)" \
    '[ "$(wc -l < "$source_root/installer.pub")" = 2 ] && sed -n 2p "$source_root/installer.pub" | grep -qE "^RW[A-Za-z0-9+/]{54}$"'

  cp "$source_root/host/aps-conecta" "$tmp/fx/instalador/host/aps-conecta"
  tar -czf "$tmp/fx/fixture.tar.gz" -C "$tmp/fx" instalador
  pkgsha="$(sha256sum "$tmp/fx/fixture.tar.gz" | cut -d' ' -f1)"
  printf '%s  apsconecta-v9.8.7.tar.gz\n' "$pkgsha" > "$tmp/fx/SHA256SUMS"
  cat > "$tshim/docker" <<'SH'
#!/usr/bin/env bash
if [ "$1" = ps ]; then echo nextcloud-aio-mastercontainer; fi
SH
  chmod +x "$tshim/docker"
  run_main "$tmp/orphan" v9.8.7 "$pkgsha"
  check "orphan: the real staged host guard refuses before bootstrap can create a valid-looking installation folder" \
    '[ "$rc" -ne 0 ] && [ ! -e "$tmp/orphan/instalador" ] && case "$out" in *"instalación incompleta"*) ;; *) false;; esac'

  if [ -z "${1:-}" ]; then
    cp "$0" "$tmp/install.sh"
    check "standalone: generated asset runs the same tests using the verified source fixtures" \
      'bash "$tmp/install.sh" --self-test "$source_root" >/dev/null 2>&1'
  fi

  rm -rf "$tmp"
  echo
  echo "self-test: $n checks OK"
  [ "$FAILED" -eq 0 ] || { echo "self-test: $FAILED FAILED" >&2; exit 1; }
  return 0
}

if [ "${1:-}" = "--self-test" ]; then selftest "${2:-}"; exit $?; fi
main "$@"
