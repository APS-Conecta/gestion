#!/usr/bin/env bash
# migrate-to-aio.sh — the S10 migration tool (FRD S10): the mechanized halves of a clinic's
# move from the gestion compose stack to the AIO suite. The operator's choreography —
# rehearsal-first, the window, the uninstall, the rollback — lives in docs/MIGRATION.md
# (v0.2.0's runbook, extended by this slice); this script only mechanizes:
#
#   prepare   dump + datadir + config.php + version.php into AIO's own volumes, BEFORE the
#             database container's first start (AIO's restore contract does the actual work)
#   verify    the post-restore hook: the three survivals, the B-019 office leg, the gates
#
# WHY SO FEW BYTES: everything heavy already lives somewhere with its own gate. The dump is
# v0.2.0's scripts/db-dump.sh (plain format, self-verified in a scratch postgres). The
# restore is AIO's own postgres start.sh (the GREP_STRING owner line, the PG_VERSION trigger,
# the REASSIGN). The read-only gates are slice 20's `aps-conecta revalidate`. The seed's
# idempotence is `make seed-idempotent`. This script FEEDS and ASSERTS; it never re-implements.
#
# Usage (from the gestion repo root, the compose stack running):
#   bash scripts/migrate-to-aio.sh prepare --domain clinic.example.cl
#   bash scripts/migrate-to-aio.sh verify   --domain clinic.example.cl
#   bash scripts/migrate-to-aio.sh --self-test
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# ── the stack's facts, each pinned where it can be checked ────────────────────────────────
SRC_DATA_VOL=apsconecta-gestion_nextcloud_data   # compose.yaml:11's project name + the
                                                  # nextcloud_data volume (the codetree, whose
                                                  # data/ subdir IS the datadir)
AIO_DUMP_VOL=nextcloud_aio_database_dump          # AIO's own names (backupscript.sh:32's own
AIO_DATA_VOL=nextcloud_aio_nextcloud_data        # default-set list; the postgres container
AIO_CODE_VOL=nextcloud_aio_nextcloud              # mounts the dump volume at /mnt/data)
DUMP_FILE=database-dump.sql
# postgres/start.sh:16's own line — the restore greps this to read the dump's owner; a dump
# without it dies at the database container's boot. Pre-asserted here so it dies at prepare
# time, naming the reason.
GREP_STRING='Name: oc_appconfig; Type: TABLE; Schema: public; Owner:'
DUMP_TIMEOUT="${DUMP_TIMEOUT:-1800}"              # B-015: the dump is bounded from outside
COPY_TIMEOUT="${COPY_TIMEOUT:-1800}"              # the datadir copy likewise

die() { echo "FATAL: $*" >&2; exit 1; }
ok()  { printf '✓ %s\n' "$*"; }
bad() { printf '✗ %s\n' "$1"; printf '  → %s\n' "$2"; FAIL=1; }
info(){ printf '· %s\n' "$*"; }
FAIL=0

suite_tag() {  # D12's rule, host/aps-conecta's own shape — byte-coupled copies, bump both
  if [ -n "${APS_SUITE_TAG:-}" ]; then printf '%s' "$APS_SUITE_TAG"; return; fi
  git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null && return
  echo ""
}

suite_image() {  # the baked nextcloud image (containers.json's own sibling name, retagged)
  local tag; tag="$(suite_tag)"
  [ -n "$tag" ] || die "no pude leer la etiqueta de versión (¿git tags?) — o exporte APS_SUITE_TAG"
  printf 'ghcr.io/aps-conecta/aio-nextcloud:%s' "$tag"   # (plan-local fix, Step 5: Phase 6 publishes aio-nextcloud — the design's fence carried the container name)
}

read_domain() {  # sets DOMAIN from --domain (the wizard asked for the same one)
  DOMAIN="${DOMAIN:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) [ -n "${2:-}" ] || die "--domain necesita el dominio que eligió en el asistente"; DOMAIN="$2"; shift 2 ;;
      *) die "opción no reconocida: $1 (uso: prepare|verify --domain <dominio>)" ;;
    esac
  done
  [ -n "$DOMAIN" ] || die "falta --domain (el mismo dominio que eligió en el asistente de AIO)"
  case "$DOMAIN" in
    */*) die "el dominio no lleva ruta: use solo el host (ej.: clinic.example.cl)" ;;
  esac
}

# ── prepare: feed AIO's restore contract ──────────────────────────────────────────────────

cmd_prepare() {  # --domain D — idempotent per stage; every stage refuses loud, never silent
  read_domain "$@"
  local tmp; tmp="$(mktemp -d)" || die "no pude crear el directorio de trabajo"

  # 1. the dump — v0.2.0's own artifact, consumed (its self-verification is its own gate)
  [ -f "$ROOT/scripts/db-dump.sh" ] \
    || die "falta scripts/db-dump.sh — es un artefacto de v0.2.0 (Phase 0); aterrice v0.2.0 primero"
  info "volcando la base (scripts/db-dump.sh — se verifica solo contra un postgres de prueba)"
  if ! timeout "$DUMP_TIMEOUT" bash "$ROOT/scripts/db-dump.sh"; then
    die "el volcado falló — el detalle llega arriba; no se tocó nada de AIO"
  fi
  [ -s "$ROOT/$DUMP_FILE" ] || die "db-dump.sh no dejó $DUMP_FILE en la raíz del repo"

  # 2. the GREP_STRING pre-assert (postgres/start.sh:108's own check, hoisted here)
  grep -qa "$GREP_STRING" "$ROOT/$DUMP_FILE" \
    || die "el volcado no trae la línea del dueño que el restaurador de AIO busca — ¿fue un formato distinto de texto plano?"
  local owner
  owner="$(grep -a "$GREP_STRING" "$ROOT/$DUMP_FILE" | head -1 | grep -oP 'Owner:.*$' | sed 's|Owner:||; s|[[:space:]]||g')"
  [ "$owner" = "oc_nextcloud" ] \
    && die "el dueño del volcado ES oc_nextcloud — el restaurador de AIO lo rechaza (start.sh:108); no debería ocurrir con un volcado de gestion"
  ok "dueño del volcado: $owner (≠ oc_nextcloud — pasa el control del restaurador; AIO hará REASSIGN a oc_nextcloud)"

  # 3. the already-initialized refusal — the silent-green guard
  # the PG_VERSION check needs the DATABASE volume — created only by AIO's compose (or by a
  # throwaway's earlier run). If it exists AND holds PG_VERSION, a prepare now would silently
  # leave the running instance under the new one (the restore only fires on PG_VERSION-absent).
  # Named volumes are created on demand by the copies below — exactly the v0.2.0 fence's own
  # sequencing: the tool populates them BEFORE AIO's compose runs, and compose adopts them.
  if docker volume inspect nextcloud_aio_database >/dev/null 2>&1; then
    if docker run --rm -v nextcloud_aio_database:/d:ro alpine test -f /d/PG_VERSION; then
      die "nextcloud_aio_database ya está inicializada (PG_VERSION presente) — el restaurador de AIO NUNCA dispararía ahora; este comando es solo para el primer arranque"
    fi
    info "nextcloud_aio_database existe sin PG_VERSION — el restaurador disparará en el primer arranque"
  else
    info "nextcloud_aio_database aún no existe — el restaurador disparará en el primer arranque"
  fi

  # 4. the dump into the dump volume (the volume the postgres container mounts at /mnt/data)
  if ! timeout "$COPY_TIMEOUT" docker run --rm \
      -v "$ROOT/$DUMP_FILE":/src/"$DUMP_FILE":ro -v "$AIO_DUMP_VOL":/dst alpine \
      cp /src/"$DUMP_FILE" /dst/; then
    die "no pude copiar el volcado al volumen $AIO_DUMP_VOL"
  fi
  ok "volcado en $AIO_DUMP_VOL/$DUMP_FILE (el restaurador de AIO lo lee en su primer arranque)"

  # 5. the datadir — cp -a so EVERY dotfile rides; the two markers beside it
  info "copiando el directorio de datos (dotfiles incluidos — .ncdata es el marcador)"
  if ! timeout "$COPY_TIMEOUT" docker run --rm \
      -v "$SRC_DATA_VOL":/src:ro -v "$AIO_DATA_VOL":/dst alpine \
      sh -c 'cp -a /src/data/. /dst/ && touch /dst/skip.update /dst/fingerprint.update'; then
    die "la copia del directorio de datos falló (¿corre la pila de gestion?)"
  fi
  # the marker pair with AIO's own disjunction (backupscript.sh:95-96): .ncdata OR .ocdata
  if ! docker run --rm -v "$AIO_DATA_VOL":/d:ro alpine sh -c 'test -f /d/.ncdata || test -f /d/.ocdata'; then
    die "el directorio de datos copiado no trae .ncdata (ni .ocdata) — la copia perdió los dotfiles; NO arranque AIO así"
  fi
  ok "directorio de datos en $AIO_DATA_VOL + los marcadores skip.update y fingerprint.update (los mismos que escribe el restaurador propio de AIO)"

  # 6. config.php — carried from the live codetree, rewritten to the AIO form
  docker run --rm -v "$SRC_DATA_VOL":/src:ro -v "$tmp":/dst alpine \
    cp /src/config/config.php /dst/config.php \
    || die "no pude leer config.php de la pila de gestion (¿corre?)"
  rewrite_config "$tmp/config.php" "$DOMAIN"
  if ! timeout "$COPY_TIMEOUT" docker run --rm \
      -v "$tmp/config.php":/src/config.php:ro -v "$AIO_CODE_VOL":/dst alpine \
      sh -c 'mkdir -p /dst/config && cp /src/config.php /dst/config/config.php'; then
    die "no pude escribir config.php en el volumen $AIO_CODE_VOL"
  fi
  ok "config.php reescrito en $AIO_CODE_VOL/config/config.php (las claves que ningún template de AIO cubre)"

  # 7. version.php — from the SUITE image. THE LOAD-BEARING PLACEMENT: the entrypoint reads
  #    /var/www/html/version.php to decide fresh-vs-existing (entrypoint.sh:131-140); without
  #    it the first boot runs occ maintenance:install into the restored database and muere
  #    con install.failed. AIO's own borg restore carries the whole codetree volume, which is
  #    why its restore never hits the gap — the hand-built volumes replicate the two files.
  local img; img="$(suite_image)"
  info "extrayendo version.php de $img (la imagen que el asistente descargará igual)"
  if ! docker run --rm --entrypoint cat "$img" /usr/src/nextcloud/version.php > "$tmp/version.php" 2>/dev/null \
     || [ ! -s "$tmp/version.php" ]; then
    die "no pude leer /usr/src/nextcloud/version.php desde $img — ¿está publicada esa etiqueta?"
  fi
  if ! timeout "$COPY_TIMEOUT" docker run --rm \
      -v "$tmp/version.php":/src/version.php:ro -v "$AIO_CODE_VOL":/dst alpine \
      cp /src/version.php /dst/version.php; then
    die "no pude escribir version.php en el volumen $AIO_CODE_VOL"
  fi
  ok "version.php en $AIO_CODE_VOL/version.php (el primer arranque verá una instancia EXISTENTE, no una instalación)"

  rm -rf "$tmp"
  echo
  echo "PREPARACIÓN: ✓ — los volúmenes de AIO traen el volcado, los datos, config.php y version.php."
  info "siga docs/MIGRATION.md desde el asistente: el uninstall es §3 (irreversible), el wizard §4 — y DESMARQUE la casilla de actualización automática del respaldo diario"
}

rewrite_config() {  # FILE DOMAIN — the rewrite set; every key NO template owns (redis/APCu/
  # apps/smtp belong to AIO's config/*.php, which load after config.php and override).
  # The seds follow start.sh:38-40's own proven line shapes. Key names read off the REAL
  # config (dbuser/dbpassword/dbname — NOT the AIO sed's 'db_name', which the real file
  # never carries).
  local f="$1" domain="$2"
  sed -i \
    -e "s|^  'dbhost'.*|  'dbhost' => 'nextcloud-aio-database',|" \
    -e "s|^  'dbuser'.*|  'dbuser' => 'oc_nextcloud',|" \
    -e "s|^  'dbpassword'.*|  'dbpassword' => 'lo-reecribe-el-arranque-de-aio',|" \
    -e "s|^  'dbname'.*|  'dbname' => 'nextcloud_database',|" \
    -e "s|^  'datadirectory'.*|  'datadirectory' => '/mnt/ncdata',|" \
    -e "s|^  'overwriteprotocol'.*|  'overwriteprotocol' => 'https',|" \
    -e "s|^  'overwrite.cli.url'.*|  'overwrite.cli.url' => 'https://$domain',|" \
    -e "s|^    'host'.*|    'host' => 'nextcloud-aio-redis',|" \
    "$f"
  # the redis password DIES: AIO's redis is passwordless and redis.config.php only overrides
  # the key when the env provides one — a carried password would AUTH-fail every cache hit.
  sed -i "/^    'password'.*=>.*$/d" "$f"
  # trusted_domains: the WHOLE array block replaced, asserted exactly once (python3 —
  # gestion's own one-liner precedent, comuna-package.sh's fence; a sed c\ quoting dance
  # is how a rewrite ends up unparseable at 3 a.m.). The regex carries the real dumper's
  # trailing space after => — read off the live config, measured.
  python3 - "$f" "$domain" <<'PYBLOCK'
import re, sys
f, domain = sys.argv[1], sys.argv[2]
t = open(f, encoding="utf-8").read()
block = "  'trusted_domains' => \n  array (\n    0 => '%s',\n  ),\n" % domain
t, n = re.subn(r"  'trusted_domains' => *\n  array \(.*?\n  \),\n", block, t, count=1, flags=re.S)
if n != 1:
    sys.exit("the trusted_domains block was not found exactly once — the config shape moved")
open(f, "w", encoding="utf-8").write(t)
PYBLOCK
}

# ── verify: the post-restore hook ─────────────────────────────────────────────────────────

cmd_verify() {  # --domain D — runs AFTER the first boot settled; read-only, aggregate exit
  read_domain "$@"
  local NC=nextcloud-aio-nextcloud DB=nextcloud-aio-database

  # the survivals (the runbook's own three, made mechanical)
  local v
  v="$(docker exec "$NC" php /var/www/html/occ config:app:get eurooffice enabled 2>/dev/null || true)"
  if [ "$v" = "yes" ]; then
    ok "eurooffice habilitado (el peligro del primer arranque — entrypoint.sh:885-893, el DS lento lo deshabilita; un reinicio lo re-habilita)"
  else
    bad "eurooffice NO está habilitado" "reinicie los contenedores (el arranque lo re-habilita cuando el DS ya responde) y vuelva a ejecutar este comando"
  fi
  v="$(docker exec "$DB" psql -U oc_nextcloud -d nextcloud_database -Atc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || true)"
  case "$v" in
    ''|*[!0-9]*) bad "no pude contar las tablas de nextcloud_database" "¿terminó el primer arranque? revise «docker logs nextcloud-aio-database»" ;;
    0|1|2|3|4|5) bad "solo $v tablas — la restauración no disparó" "el volcado debía estar en el volumen ANTES del primer arranque de la base; revise «docker logs $DB» buscando «Restoring from database dump»" ;;
    *) ok "la base restaurada trae $v tablas" ;;
  esac
  if docker exec "$NC" sh -c 'test -f /mnt/ncdata/.ncdata || test -f /mnt/ncdata/.ocdata'; then
    ok "el directorio de datos montó con su marcador (.ncdata/.ocdata)"
  else
    bad "el directorio de datos no montó" "reinstale desde el asistente con los volúmenes preparados (docs/MIGRATION.md §2)"
  fi

  # the B-019 leg: the config SHAPE a script can assert (B-019's own lesson — reachability
  # from another machine is the human leg, printed below, never gated from here)
  v="$(docker exec "$NC" php /var/www/html/occ config:app:get eurooffice DocumentServerUrl 2>/dev/null || true)"
  if [ "$v" = "https://$DOMAIN/eurooffice" ]; then
    ok "DocumentServerUrl = https://$DOMAIN/eurooffice (la forma pública — B-019 cerrado)"
  else
    bad "DocumentServerUrl es «$v» — no es la forma pública del dominio" "el arranque de AIO debía reescribirla; reinicie los contenedores y vuelva a comprobar"
  fi
  v="$(docker exec "$NC" php /var/www/html/occ config:system:get overwriteprotocol 2>/dev/null || true)"
  [ "$v" = "https" ] && ok "overwriteprotocol https (el esquema coincide — el contenido mixto de B-019)" \
                       || bad "overwriteprotocol es «$v»" "el reescrito de config.php lo dejaba en https; revise a mano"
  echo
  info "PRUEBA HUMANA (B-019, imposible de automatizar desde el servidor): abra un documento desde OTRO equipo de la red"

  # the gates: slice 20's own read-only sweep + the seed's idempotence on the migrated host
  echo
  if [ -f "$ROOT/.env" ] && grep -q '^SITE=' "$ROOT/.env"; then
    if bash "$ROOT/host/aps-conecta" revalidate; then :; else FAIL=1; fi
    if make -C "$ROOT" seed-idempotent; then :; else FAIL=1; fi
  else
    info "sin .env/SITE aún: ejecute «aps-conecta provision» (el flujo completo) y re-ejecute verify para las compuertas"
  fi

  if [ "$FAIL" -gt 0 ]; then
    echo "VERIFICACIÓN: ✗ — corrija lo marcado arriba"
    return 1
  fi
  echo "VERIFICACIÓN: ✓ — la instancia migrada pasó las tres supervivencias, la pierna B-019 y las compuertas"
}

# ── self-test — the behavioral-stub pattern (test.sh:157-216's own doctrine): a docker ──
# shim keyed on argv shapes, volume names mapped into a fixture tree, every plant reverted.

selftest() {
  local n=0 tshim tmp FIX ROOT_BAK="$ROOT" DOMAIN_BAK="${DOMAIN:-}"
  tmp="$(mktemp -d)"; tshim="$tmp/bin"; FIX="$tmp/fix"
  mkdir -p "$tshim" "$FIX/vol" "$FIX/repo/scripts" "$FIX/vol/$AIO_CODE_VOL/config"

  check() { local name="$1" cond="$2"; n=$((n + 1))
    if eval "$cond"; then :; else echo "  FAIL: $name" >&2; FAILED=$((FAILED + 1)); fi; }
  FAILED=0

  # the fixture world: a gestion-shaped config (the REAL key names, anonymized values — the
  # live config's own line shapes, measured), a fixture dump with the GREP_STRING owner line,
  # a stub db-dump.sh (v0.2.0's artifact stands in for its Phase-0 original, named for what
  # it is), a fixture datadir with .ncdata, a fixture version.php
  ROOT="$FIX/repo"
  cat > "$ROOT/config-fixture.php" <<'PHPEOF'
<?php
$CONFIG = array (
  'memcache.distributed' => '\OC\Memcache\Redis',
  'memcache.locking' => '\OC\Memcache\Redis',
  'redis' => 
  array (
    'host' => 'redis',
    'password' => 'secreto-viejo',
    'port' => 6379,
  ),
  'passwordsalt' => 'x',
  'secret' => 'instancia-secreto',
  'trusted_domains' => 
  array (
    0 => 'localhost',
    1 => 'viejo.dominio.cl',
  ),
  'datadirectory' => '/var/www/html/data',
  'version' => '34.0.4.1',
  'overwrite.cli.url' => 'http://localhost:8080',
  'instanceid' => 'x',
  'dbname' => 'apsconecta',
  'dbhost' => 'db',
  'dbtableprefix' => 'oc_',
  'dbuser' => 'apsconecta',
  'dbpassword' => 'postgres-clave-vieja',
  'installed' => true,
  'overwriteprotocol' => '',
);
PHPEOF
  printf '%s\n' "--" "-- Dumped by pg_dump" "--" "Name: oc_appconfig; Type: TABLE; Schema: public; Owner: apsconecta" \
    > "$ROOT/$DUMP_FILE"
  printf '#!/usr/bin/env bash\necho "db-dump stub ok"\n' > "$ROOT/scripts/db-dump.sh"
  chmod +x "$ROOT/scripts/db-dump.sh"
  mkdir -p "$FIX/vol/$SRC_DATA_VOL/data" "$FIX/vol/$SRC_DATA_VOL/config"
  printf 'PMTiles' > "$FIX/vol/$SRC_DATA_VOL/data/.ncdata"
  cp "$ROOT/config-fixture.php" "$FIX/vol/$SRC_DATA_VOL/config/config.php"
  printf 'fixture-htaccess' > "$FIX/vol/$SRC_DATA_VOL/data/.htaccess"
  mkdir -p "$FIX/suite"
  printf '<?php\n$OC_Version = array(34,0,4,1);\n' > "$FIX/suite/version.php"

  # the docker shim — the #143 behavioral pattern: argv-shape keyed, with a real -v
  # parser so bind mounts (the tool's tmp files) and named volumes (the fixture's vol tree)
  # both resolve. Named volumes map to $FIX/vol/<name> — docker creates them on demand and
  # the fixture adopts them, exactly like compose adopts pre-created named volumes.
  cat > "$tshim/docker" <<'DSHIM'
#!/usr/bin/env bash
FIX="${MIG_FIX:?}"
declare -A CT2L
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-v" ]; then
    spec="${args[$((i+1))]}"
    left="${spec%%:*}"; right="${spec#*:}"
    case "$left" in
      */*) lp="$left" ;;
      *)  lp="$FIX/vol/$left" ;;
    esac
    CT2L["${right%:ro}"]="$lp"
  fi
done
case "$*" in
  *"volume inspect nextcloud_aio_database"*) [ -f "$FIX/db-exists" ] && exit 0; exit 1 ;;
  *"test -f /d/PG_VERSION"*) [ -f "$FIX/pgversion" ] && exit 0; exit 1 ;;
  *"cp /src/database-dump.sql /dst/"*)
    mkdir -p "${CT2L[/dst]}"; cp "${CT2L[/src/database-dump.sql]}" "${CT2L[/dst]}/"; exit 0 ;;
  *"cp -a /src/data/. /dst/"*)
    mkdir -p "${CT2L[/dst]}"; cp -a "${CT2L[/src]}/data/." "${CT2L[/dst]}/"
    touch "${CT2L[/dst]}/skip.update" "${CT2L[/dst]}/fingerprint.update"; exit 0 ;;
  *"test -f /d/.ncdata"*)
    test -f "${CT2L[/d]}/.ncdata" || test -f "${CT2L[/d]}/.ocdata" ;;
  *"cp /src/config/config.php /dst/config.php"*)
    cp "${CT2L[/src]}/config/config.php" "${CT2L[/dst]}/config.php"; exit 0 ;;
  *"mkdir -p /dst/config"*)
    mkdir -p "${CT2L[/dst]}/config"; cp "${CT2L[/src/config.php]}" "${CT2L[/dst]}/config/config.php"; exit 0 ;;
  *"cp /src/version.php /dst/version.php"*)
    mkdir -p "${CT2L[/dst]}"; cp "${CT2L[/src/version.php]}" "${CT2L[/dst]}/version.php"; exit 0 ;;
  *"/usr/src/nextcloud/version.php"*) cat "$FIX/suite/version.php"; exit 0 ;;
  *"config:app:get eurooffice enabled"*) echo "${MIG_EO_ENABLED:-yes}"; exit 0 ;;
  *"config:app:get eurooffice DocumentServerUrl"*) echo "${MIG_DSU:-https://clinic.example.cl/eurooffice}"; exit 0 ;;
  *"config:app:get "*) echo "APP-NS-UNKNOWN: $*"; exit 1 ;;
  *"SELECT count(*)"*) echo "${MIG_TABLES:-188}"; exit 0 ;;
  *"/mnt/ncdata/.ncdata"*) test -f "$FIX/vol/nextcloud_aio_nextcloud_data/.ncdata"; exit $? ;;
  *"overwriteprotocol"*) echo "${MIG_PROTO:-https}"; exit 0 ;;
  *) exit 0 ;;
esac
DSHIM
  chmod +x "$tshim/docker"
  export PATH="$tshim:/usr/sbin:/usr/bin:/bin"
  export MIG_FIX="$FIX"

  # ── prepare end to end ──
  printf 'v0.2.0-fixture' > "$FIX/tagfile"; APS_SUITE_TAG=v0.2.0-fixture
  cmd_prepare --domain clinic.example.cl >/tmp/mig-p.txt 2>&1; local rc=$?
  check "prepare: green end to end over the stub world" \
    '[ "$rc" -eq 0 ] && case "$(cat /tmp/mig-p.txt)" in *"PREPARACIÓN: ✓"*) ;; *) false;; esac'
  check "prepare: the dump landed in the dump volume" \
    'grep -q "Owner: apsconecta" "$FIX/vol/nextcloud_aio_database_dump/database-dump.sql"'
  check "prepare: the datadir landed with the dotfiles AND both markers" \
    '[ -f "$FIX/vol/nextcloud_aio_nextcloud_data/.ncdata" ] \
     && [ -f "$FIX/vol/nextcloud_aio_nextcloud_data/.htaccess" ] \
     && [ -f "$FIX/vol/nextcloud_aio_nextcloud_data/skip.update" ] \
     && [ -f "$FIX/vol/nextcloud_aio_nextcloud_data/fingerprint.update" ]'
  local cfg="$FIX/vol/nextcloud_aio_nextcloud/config/config.php" ver="$FIX/vol/nextcloud_aio_nextcloud/version.php"
  check "prepare: config.php landed rewritten + version.php beside it (the codetree half)" \
    '[ -s "$cfg" ] && [ -s "$ver" ] && grep -q "OC_Version" "$ver"'
  check "rewrite: dbhost/dbuser/dbname → the AIO triple" \
    'grep -q "^  .dbhost. => .nextcloud-aio-database.,$" "$cfg" \
     && grep -q "^  .dbuser. => .oc_nextcloud.,$" "$cfg" \
     && grep -q "^  .dbname. => .nextcloud_database.,$" "$cfg"'
  check "rewrite: the old dbpassword never rides (the placeholder; the boot rewrites the real one)" \
    'grep -q "lo-reecribe-el-arranque-de-aio" "$cfg" && ! grep -q "postgres-clave-vieja" "$cfg"'
  check "rewrite: datadirectory → /mnt/ncdata, overwriteprotocol https, overwrite.cli.url public" \
    'grep -q "^  .datadirectory. => ./mnt/ncdata.,$" "$cfg" \
     && grep -q "^  .overwriteprotocol. => .https.,$" "$cfg" \
     && grep -q "^  .overwrite.cli.url. => .https://clinic.example.cl.,$" "$cfg"'
  check "rewrite: the redis host re-pointed and the redis password DELETED (AIO's redis is passwordless)" \
    'grep -q "^    .host. => .nextcloud-aio-redis.,$" "$cfg" && ! grep -q secreto-viejo "$cfg"'
  check "rewrite: trusted_domains replaced whole — the stale gestion domain is GONE, the new one in" \
    'grep -q "^    0 => .clinic.example.cl.,$" "$cfg" && ! grep -q viejo.dominio.cl "$cfg"'
  check "rewrite: the instance secret RIDES (a data migration preserves identities)" \
    'grep -q "instancia-secreto" "$cfg"'

  # ── the refusal arms (B-014: each names its reason) ──
  # the refusal arms run cmd_prepare in a command substitution: die() EXITS the process,
  # so a direct call would kill the whole selftest at the first refusal (the de-risk's own
  # find — the first draft died exactly there, mid-run, after the rewrite checks); the $()
  # subshell is the catch boundary, the slice-21 datos arms' own pattern.
  touch "$FIX/db-exists" "$FIX/pgversion"
  local rout; rout="$(cmd_prepare --domain clinic.example.cl 2>&1)"; rc=$?; printf '%s' "$rout" > /tmp/mig-r.txt
  check "refuse: an already-initialized AIO database (PG_VERSION) never re-prepares silently" \
    '[ "$rc" -ne 0 ] && case "$(cat /tmp/mig-r.txt)" in *"PG_VERSION presente"*) ;; *) false;; esac'
  rm -f "$FIX/db-exists" "$FIX/pgversion"   # revert (flip-then-revert)
  # the oc_nextcloud-owner dump → AIO's own refusal hoisted to prepare time
  printf '%s\n' "Name: oc_appconfig; Type: TABLE; Schema: public; Owner: oc_nextcloud" > "$ROOT/$DUMP_FILE"
  rout="$(cmd_prepare --domain clinic.example.cl 2>&1)"; rc=$?; printf '%s' "$rout" > /tmp/mig-o.txt
  check "refuse: a dump whose owner IS oc_nextcloud (the restore contract's own check, hoisted)" \
    '[ "$rc" -ne 0 ] && case "$(cat /tmp/mig-o.txt)" in *"rechaza"*) ;; *) false;; esac'
  printf '%s\n' "Name: oc_appconfig; Type: TABLE; Schema: public; Owner: apsconecta" > "$ROOT/$DUMP_FILE"
  # a dump without the GREP_STRING line
  printf '%s\n' "-- formato custom sin la línea" > "$ROOT/$DUMP_FILE"
  rout="$(cmd_prepare --domain clinic.example.cl 2>&1)"; rc=$?; printf '%s' "$rout" > /tmp/mig-g.txt
  check "refuse: a dump without the owner line dies at PREPARE, not at the database boot" \
    '[ "$rc" -ne 0 ] && case "$(cat /tmp/mig-g.txt)" in *"la línea del dueño"*) ;; *) false;; esac'
  printf '%s\n' "Name: oc_appconfig; Type: TABLE; Schema: public; Owner: apsconecta" > "$ROOT/$DUMP_FILE"

  # ── verify end to end + the B-019 arms ──
  DOMAIN=clinic.example.cl cmd_verify >/tmp/mig-v.txt 2>&1; rc=$?
  check "verify: green over the planted world (the survivals + B-019 + the gates skipped honestly)" \
    '[ "$rc" -eq 0 ] && grep -q "VERIFICACIÓN: ✓" /tmp/mig-v.txt && grep -q "PRUEBA HUMANA" /tmp/mig-v.txt'
  MIG_DSU="http://localhost:9980/" DOMAIN=clinic.example.cl cmd_verify >/tmp/mig-b.txt 2>&1; rc=$?
  check "verify: a loopback DocumentServerUrl reds the B-019 leg (B-019's own failure mode)" \
    '[ "$rc" -ne 0 ] && case "$(cat /tmp/mig-b.txt)" in *"no es la forma pública"*) ;; *) false;; esac'
  MIG_DSU="https://clinic.example.cl/eurooffice" MIG_PROTO="http" DOMAIN=clinic.example.cl cmd_verify >/tmp/mig-b2.txt 2>&1; rc=$?
  check "verify: a wrong overwriteprotocol reds the scheme leg (mixed content)" \
    '[ "$rc" -ne 0 ]'
  MIG_EO_ENABLED="no" DOMAIN=clinic.example.cl cmd_verify >/tmp/mig-e.txt 2>&1; rc=$?
  check "verify: a disabled eurooffice reds with the restart recovery named" \
    '[ "$rc" -ne 0 ] && case "$(cat /tmp/mig-e.txt)" in *"reinicie los contenedores"*) ;; *) false;; esac'
  MIG_TABLES="4" DOMAIN=clinic.example.cl cmd_verify >/tmp/mig-t.txt 2>&1; rc=$?
  check "verify: a near-empty table count reds naming the restore that never fired" \
    '[ "$rc" -ne 0 ] && case "$(cat /tmp/mig-t.txt)" in *"la restauración no disparó"*) ;; *) false;; esac'

  # the app-id canary (R1's find): the connector's namespace is eurooffice in every locked
  # surface — the entrypoint writes config:app:set eurooffice DocumentServerUrl
  # (entrypoint.sh:916), gestion's own smoke.sh:244 and 14-office.sh:17 read/write the same —
  # while a richdocuments read is a NEVER-GREEN verify leg (the R1 violation: the first draft
  # read the wrong app id, and the shim's substring keying was blind to it, so 19/19 green hid
  # the bug). The shim now keys the app id and answers APP-NS-UNKNOWN for any other read.
  check "verify: the connector read is the eurooffice form (the positive canary — the file
     cannot grep its own lesson-prose for the poison shape without matching its own check
     string, so the positive form + the shim's APP-NS-UNKNOWN guard are the pair)" \
    'grep -q "config:app:get eurooffice DocumentServerUrl" "$(readlink -f "$0")"'

  # the gates leg: with .env+SITE planted, revalidate + seed-idempotent are CALLED
  printf 'SITE=114302\n' > "$ROOT/.env"
  mkdir -p "$ROOT/host"
  printf '#!/usr/bin/env bash\necho "revalidate stub PASS"\n' > "$ROOT/host/aps-conecta"; chmod +x "$ROOT/host/aps-conecta"
  printf 'seed-idempotent:\n\t@echo "seed-idempotent stub PASS"\n' > "$ROOT/Makefile"
  local mk_out; mk_out="$(DOMAIN=clinic.example.cl cmd_verify 2>&1)"; rc=$?
  check "verify: the gates leg fires revalidate + seed-idempotent when .env/SITE exist" \
    'printf "%s" "$mk_out" | grep -q "revalidate stub PASS" && printf "%s" "$mk_out" | grep -q "seed-idempotent stub PASS"'

  ROOT="$ROOT_BAK"; DOMAIN="${DOMAIN_BAK:-}"; unset APS_SUITE_TAG MIG_FIX 2>/dev/null || true
  rm -rf "$tmp"
  echo
  echo "self-test: $n checks OK"
  [ "$FAILED" -eq 0 ] || { echo "self-test: $FAILED FAILED" >&2; exit 1; }
  return 0
}

# ── dispatch ──────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
  prepare)     shift; cmd_prepare "$@" ;;
  verify)      shift; cmd_verify "$@" ;;
  --self-test) selftest ;;
  *) sed -n '2,17p' "$0"; echo; echo "uso: migrate-to-aio.sh {prepare --domain <dominio>|verify --domain <dominio>|--self-test}" ;;
esac
