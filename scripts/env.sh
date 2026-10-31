#!/usr/bin/env bash
# Shared preamble: source this first from anything that reads .env or execs into the suite.
# Seven jobs, all load-bearing; sourced by seed.sh, divergence.sh, smoke.sh, office-smoke.sh,
# seed-idempotent.sh and (transitively) every provisioning phase.
#
# 1. cd to the repo root. .env, sites/ and provisioning/ are read by relative path, so a caller
#    started from any other directory reads the same files.
#
# 2. Read .env the way docker compose reads it, WITHOUT sourcing it. `set -a; . .env` runs every
#    value through bash expansion, so the two readers disagree about the same key: compose turns
#    `abc$$def` into `abc$def`, bash into `abc<pid>def`. That is a JWT secret which works in the
#    documentserver and fails in the connector, with office-smoke green either way. `$VAR` expands
#    the same, and `$(...)`/backticks EXECUTE on every seed.
#    So: split on the first `=`, strip one layer of quotes, undo compose's `$$`, expand nothing else.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "FAIL: cannot cd to the repo root" >&2; exit 1; }

# 3. occ + raw exec inside the running Nextcloud container — one seam, for every caller of this
#    file, and the one place that decides WHICH container (#197, R41). nc_container sets it in
#    this shell: a value from the environment or .env wins (the loader below exports it);
#    otherwise the AIO container ($AIO_NC, fixed by AIO's php/containers.json:145), so a stopped
#    stack fails loudly at require_installed. Callers call it after their first output, never at
#    source time: occ inside a pipe or $(…) is a subshell, so scripts that make dozens of occ
#    calls (seed, divergence, smoke) call nc_container once.
#    is_aio = "the AIO stack is running", the question smoke, test.sh and phases 10 and 12
#    ask. `grep -x >/dev/null`, not `-qx`: grep reads to EOF, so
#    docker never takes a SIGPIPE that a pipefail caller would read as "not running".
AIO_NC=aps-conecta-nextcloud
is_aio() { docker ps --format '{{.Names}}' 2>/dev/null | grep -x "$AIO_NC" >/dev/null; }
nc_container() { NC_CONTAINER="${NC_CONTAINER:-$AIO_NC}"; }  # always returns 0
#
#    nc_exec's contract is forced by docker exec's own grammar — options BEFORE the container,
#    command AFTER — so every docker-exec option word comes first, then `--`, then the command.
#    A missing `--` fails loudly rather than letting an option word run as the command (B-014: a
#    seam that can misparse silently is not a seam). No -T (docker exec has no such flag — no TTY
#    is its default, which is what compose's -T was buying); -i only where a caller streams stdin
#    (occ_sh's patch bytes, the vendored-tarball unpack — passed per-site in lib.sh; occ() itself
#    takes none: no caller pipes stdin into it). www-data is upstream's own console form (AIO
#    readme.md:822) — root occ trips Nextcloud's console config-owner check — and the occ path is
#    ABSOLUTE because the AIO image sets no WORKDIR, so the relative `php occ` the compose
#    transport allowed cannot resolve there.
nc_exec() {  # [docker-exec option words…] -- COMMAND [args…] — exec into the Nextcloud container
  local -a opts=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
  [ $# -gt 0 ] || { echo "FATAL: nc_exec: missing the -- that separates options from the command" >&2; return 2; }
  shift
  nc_container
  docker exec "${opts[@]}" "$NC_CONTAINER" "$@"
}
occ() { nc_exec --user www-data -- php /var/www/html/occ "$@"; }
require_store_app_integrity() {
  local app="${1:?usage: require_store_app_integrity APP}"
  # The native checker can skip an unsigned app and return zero.
  nc_exec --user www-data -- test -s "/var/www/html/custom_apps/$app/appinfo/signature.json" \
    || { echo "FAIL: $app official store signature is missing"; return 1; }
  occ integrity:check-app "$app" >/dev/null \
    || { echo "FAIL: $app official connector integrity check failed"; return 1; }
}
# docker cp takes the container name itself, so it cannot ride nc_exec; same resolution, two sites
# (lib.sh's certificate copy, phase 41's welcome tree).
nc_cp() { nc_container; docker cp "$1" "$NC_CONTAINER:$2"; }  # HOST_PATH CONTAINER_PATH

# 4. The suite's public URL, the base every gate curl rides (#163, D10: the gates curl the suite
#    the way its users reach it, from the host itself). Apache's own environment decides, never
#    .env's HTTP_PORT. The suite uses its public HTTPS name; an IP also needs the installer's CA.
SUITE_CA="${SUITE_CA:-/opt/aps-conecta/certificados/ca/aps-conecta-ca.crt}"
suite_url_resolve() {  # sets SUITE_URL, SUITE_CURL and SUITE_D10, or prints a FAIL and returns 1
  local env dom
  env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' aps-conecta-apache 2>/dev/null)" \
    || { echo "FAIL: cannot read aps-conecta-apache's environment (docker inspect) — the suite's public URL is unknown" >&2; return 1; }
  dom="$(printf '%s\n' "$env" | sed -n 's/^NC_DOMAIN=//p' | head -1)"
  SUITE_CURL=(--connect-timeout 10 --max-time 30); SUITE_D10=""
  [ -n "$dom" ] || { echo "FAIL: aps-conecta-apache carries no NC_DOMAIN — the suite's public URL is unknown" >&2; return 1; }
  SUITE_URL="https://$dom"
  # host/aps-conecta's IPV4_RE (the install by IP accepts nothing else); this file cannot source it
  if [[ $dom =~ ^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])[.]){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]; then
    [ -r "$SUITE_CA" ] \
      || { echo "FAIL: the suite answers by IP ($SUITE_URL) but its CA $SUITE_CA is not readable — run the gates as root (sudo); if root cannot read it either, sudo aps-conecta provision --reponer re-runs the certificate step" >&2; return 1; }
    SUITE_CURL+=(--cacert "$SUITE_CA")
  else
    SUITE_D10=" — D10: sudo aps-conecta red --dominio $dom --arreglar"  # a domain not answering from the host itself is D10's hairpin leg
  fi
}
suite_curl() { curl "${SUITE_CURL[@]}" "$@"; }

# 5. The clinic this stack serves, for the callers that need one — seed.sh, comuna-package.sh and
#    divergence.sh. A function, not a check at source time: smoke.sh, office-smoke.sh and
#    seed-idempotent.sh source this file too and must keep working on a checkout that has no
#    clinic yet.
require_site() {
  [ -n "${SITE:-}" ] || {
    echo "FATAL: SITE is unset — .env must name the establishment this stack serves." >&2
    echo "       No establishment ships with this repo; pick yours from the DEIS register:" >&2
    echo "         scripts/deis.py                              # search, then pick a number" >&2
    echo "       then set SITE=<slug> in .env. README step 3 walks it." >&2
    return 1
  }
  [ -f "sites/$SITE/site.sh" ] || {
    echo "FATAL: no sites/$SITE/site.sh — write it with:" >&2
    echo "         scripts/deis.py <tipo> <comuna>              # find the DEIS code" >&2
    echo "         scripts/deis.py <codigo> --new $SITE" >&2
    echo "       Any primary-care establishment in the register works, not only a CESFAM." >&2
    return 1
  }
}

# 6. Refuse to provision a clinic with the secrets this repository publishes.
#    The Provisionador generates the fixture password when .env has none, so a placeholder only
#    survives a hand-copy of the template. The result is a CESFAM whose standing accounts start
#    with a password anyone who can read this repo can read.
#
#    Read out of .env.example rather than listed here: the template is what defines a placeholder,
#    so one that gets reworded does not quietly stop being one, and a secret added there is covered
#    on the day it is added. A function for the same reason require_site is one — the read-only
#    callers of this file must keep working on a checkout that has no .env at all.
require_real_secrets() {
  [ -f .env.example ] || {
    echo "FATAL: no .env.example — cannot tell a real secret from the one this repo ships." >&2
    return 1
  }

  local still=() line key
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    # The MARKER decides, not equality with the template's bytes. Comparing them meant two
    # dotenv readers that disagreed: the loader below strips quotes and undoes `$$`, both
    # conventions .env.example already uses, so a placeholder gaining either would leave
    # `still` empty and a clinic installed with a published secret. It failed OPEN.
    case "${!key:-}" in *change-me*) still+=("$key") ;; esac
  done < .env.example

  [ ${#still[@]} -eq 0 ] || {
    echo "FATAL: .env still holds the placeholder .env.example ships for: ${still[*]}" >&2
    echo "       Those values are published in this repository, so anyone who can read it can" >&2
    echo "       read them. A clinic must not be installed with them." >&2
    echo "       Delete those lines from .env and run the install again: the Provisionador" >&2
    echo "       generates the fixture password when .env has none." >&2
    return 1
  }
}

# org L5-05 round-trip gate, in the repo's --self-test idiom (comuna
# precedents). Every arm hermetic: (1) a fixture .env whose tricky-but-legal values load
# exactly as the loader intends (comment strip, quoted hashes, $$ undo); (2) the container
# arms — section 3's answer, fabricated with a stub docker (#197), and require_installed's
# message; (3) the suite URL arms (#163); (4) a multi-line quoted value is REFUSED loudly
# instead of silently loading its first half. The fixture IS the scratch root's .env because
# the loader reads ./.env relative to its own root.
env_self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)" || return 1
  local fx="$tmp/.env"
  cat > "$fx" <<'FIX'
PLAIN=apsconecta
# a whole-line comment
UNQUOTED_WITH_COMMENT=some-value # and a trailing one
DOUBLE_QUOTED_HASH="value # stays"
SINGLE_QUOTED_HASH='other # stays'
DOLLAR_DOUBLED=abc$$def
FIX
  mkdir -p "$tmp/scripts"
  cp "${BASH_SOURCE[0]}" "$tmp/scripts/env.sh"
  ( cd "$tmp" && . ./scripts/env.sh 2>/dev/null
    [ "${PLAIN:-}" = apsconecta ] && [ "${UNQUOTED_WITH_COMMENT:-}" = some-value ] \
      && [ "${DOUBLE_QUOTED_HASH:-}" = 'value # stays' ] && [ "${SINGLE_QUOTED_HASH:-}" = 'other # stays' ] \
      && [ "${DOLLAR_DOUBLED:-}" = 'abc$def' ]
  ) || { echo "self-test FAIL: loader arm — the loader misparsed the fixture" >&2; rc=1; }
  # the container arms (#197): which container occ talks to is decided in this file alone. A stub
  # docker logs every call and answers `ps` with $STUB_NAMES, so each posture is fabricated without
  # a daemon — AIO up, nothing up, an empty .env key, and a .env value that must win. Each arm
  # asserts that sourcing alone ran no docker.
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/docker" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_CALLS"
[ "$1" = ps ] && printf '%s\n' $STUB_NAMES
if [ "$1" = inspect ]; then [ "${STUB_ENV:-absent}" = absent ] && exit 1; printf '%b\n' "$STUB_ENV"; fi
exit 0
STUB
  chmod +x "$tmp/bin/docker"
  nc_arm() {  # WANT_NAME WANT_IS_AIO(1|0) ENV_LINE [RUNNING_NAME…]
    local want="$1" aio="$2" line="$3"; shift 3
    printf '%s\n' "$line" > "$fx"; : > "$tmp/calls"
    ( unset NC_CONTAINER; export PATH="$tmp/bin:$PATH" STUB_NAMES="$*" STUB_CALLS="$tmp/calls"
      cd "$tmp" && . ./scripts/env.sh 2>/dev/null
      [ ! -s "$tmp/calls" ] || exit 1
      nc_container
      [ "${NC_CONTAINER:-}" = "$want" ] || exit 1
      if is_aio; then [ "$aio" = 1 ]; else [ "$aio" = 0 ]; fi || exit 1
    ) || { echo "self-test FAIL: container arm — want $want (is_aio=$aio) for '${line:-no .env value}' with [${*:-nothing}] running" >&2; rc=1; }
  }
  nc_arm aps-conecta-nextcloud 1 '' aps-conecta-nextcloud
  nc_arm aps-conecta-nextcloud 0 ''
  nc_arm aps-conecta-nextcloud 1 'NC_CONTAINER=' aps-conecta-nextcloud
  nc_arm custom-nc 1 'NC_CONTAINER=custom-nc' aps-conecta-nextcloud
  # ...and its failure names the cause (lib.sh's require_installed, the one place that dies on it):
  # a configured name that is not the running AIO container is called out.
  mkdir -p "$tmp/provisioning"
  cp "$(dirname -- "${BASH_SOURCE[0]}")/../provisioning/lib.sh" "$tmp/provisioning/lib.sh"
  ri_arm() {  # WANT_TEXT NOT_TEXT ENV_LINE [RUNNING_NAME…]
    local want="$1" not="$2" line="$3" out; shift 3
    printf '%s\n' "$line" > "$fx"
    out="$( unset NC_CONTAINER; export PATH="$tmp/bin:$PATH" STUB_NAMES="$*" STUB_CALLS="$tmp/calls"
      cd "$tmp" && . ./scripts/env.sh 2>/dev/null && . ./provisioning/lib.sh && require_installed 2>&1 )"
    case "$out" in *"$want"*) case "$out" in *"$not"*) false ;; esac ;; *) false ;; esac \
      || { echo "self-test FAIL: require_installed arm — want «$want», not «$not» for '${line:-no .env value}' with [${*:-nothing}] running" >&2; rc=1; }
  }
  ri_arm 'NC_CONTAINER=custom-nc (environment or .env) overrides it' 'reachable in aps-conecta-nextcloud.' 'NC_CONTAINER=custom-nc' aps-conecta-nextcloud
  ri_arm 'reachable in aps-conecta-nextcloud.' 'overrides it' ''
  # the suite URL arms (#163): the gates' base URL is apache's own posture, never .env's HTTP_PORT —
  # the fixture carries one in every arm. A stub inspect answers apache's env
  # ($STUB_ENV, "absent" = no container); sourcing alone runs no docker; the CA rides only an IP.
  su_arm() {  # WANT(url, or the FAIL text) CACERT(yes|no|fail) STUB_ENV CA_FILE(1|0)
    local want="$1" ca="$2" envs="$3" out
    printf 'HTTP_PORT=8180\n' > "$fx"; : > "$tmp/calls"; rm -f "$tmp/ca.crt"; [ "$4" = 0 ] || : > "$tmp/ca.crt"
    out="$( export PATH="$tmp/bin:$PATH" STUB_ENV="$envs" STUB_CALLS="$tmp/calls" SUITE_CA="$tmp/ca.crt"
      cd "$tmp" && . ./scripts/env.sh 2>/dev/null
      [ ! -s "$tmp/calls" ] || exit 1
      if [ "$ca" = fail ]; then suite_url_resolve 2>&1 && exit 1; exit 0; fi
      suite_url_resolve || exit 1
      case " ${SUITE_CURL[*]} " in *" --cacert $tmp/ca.crt "*) c=yes ;; *) c=no ;; esac
      printf '%s %s' "$SUITE_URL" "$c" )" \
      && case "$ca" in fail) [[ $out == *"$want"* ]] ;; *) [ "$out" = "$want $ca" ] ;; esac \
      || { echo "self-test FAIL: suite URL arm — want «$want» (cacert $ca) for [$envs], got «$out»" >&2; rc=1; }
  }
  su_arm https://203.0.113.10 yes 'APACHE_PORT=443\nNC_DOMAIN=203.0.113.10' 1
  su_arm https://clinica.example no 'APACHE_PORT=443\nNC_DOMAIN=clinica.example' 1
  su_arm https://clinica.example no 'NC_DOMAIN=clinica.example' 1
  su_arm "its CA $tmp/ca.crt is not readable" fail 'APACHE_PORT=443\nNC_DOMAIN=203.0.113.10' 0
  su_arm 'carries no NC_DOMAIN' fail 'APACHE_PORT=443' 1
  su_arm https://clinica.example no 'APACHE_PORT=\nNC_DOMAIN=clinica.example' 1
  su_arm 'carries no NC_DOMAIN' fail 'APACHE_PORT=443\nNC_DOMAIN=' 1
  su_arm "cannot read aps-conecta-apache's environment" fail absent 1
  # the multi-line refusal arm: a quoted value split across lines must fail the whole load
  printf 'BROKEN_MULTI="first half of a value\n' > "$fx"
  printf 'still inside the quote"\nX=1\n' >> "$fx"
  ( cd "$tmp" && . ./scripts/env.sh >/dev/null 2>&1 ) \
    && { echo "self-test FAIL: multi-line arm — the loader accepted a split quoted value" >&2; rc=1; }
  rm -rf "$tmp"
  [ "$rc" = 0 ] && echo "self-test: env.sh loader arms OK"
  return "$rc"
}
# Only when EXECUTED directly: a caller that needs the seams sources this file BEFORE
# its own --self-test dispatch, and a sourced case sees the caller's $1 — unguarded, env's
# arms answered for a caller and hollowed its detector arm to silent green (round-1 catch).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --self-test) env_self_test; exit $? ;;
  esac
fi

if [ -f .env ]; then

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    _key=${_line%%=*}
    _val=${_line#*=}
    # Ignore anything that is not a plain shell name, rather than trying to export it.
    case "$_key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    # org L5-05: compose strips an UNQUOTED trailing comment (`KEY=v # note` loads v), so the
    # loader must too or the two readers disagree about the same file — the exact divergence
    # this file exists to prevent. Quoted values keep their hashes: compose reads the quotes.
    _unquoted=1
    case "$_val" in
      \"*\") _unquoted=0; _val=${_val#\"}; _val=${_val%\"} ;;
      \'*\') _unquoted=0; _val=${_val#\'}; _val=${_val%\'} ;;
    esac
    if [ "$_unquoted" = 1 ]; then
      # the compose rule: `#` starts a comment only after whitespace, so a URL with a bare
      # fragment survives while `v # note` loads v.
      _val="${_val%%[[:space:]]#*}"
    fi
    # A quote character left in an UNQUOTED value means the value was split across lines
    # (compose cannot read that file either) or a stray quote rode along: refuse loudly
    # instead of loading a prefix the rest of the repo would treat as the whole secret.
    # No legal unquoted value in this repo's dialect carries a quote (.env.example is the
    # corpus — org L5-05).
    case "$_val" in
      *[\"\']*) printf 'FATAL: .env %s: quote in an unquoted value — a multi-line quoted value (compose cannot read it either) or a stray quote. Fix the line.\n' "$_key" >&2; exit 1 ;;
    esac
    export "$_key=${_val//\$\$/\$}"
  done < .env
  unset _line _key _val
fi

# 7. The engine's storage root, as staff will see it in Files (ADR-0016, IntraVox review L0-02).
#    Phase 41 tells the engine the name (`occ config:app:set intravox groupfolder_name`) BEFORE
#    `intravox:setup` creates the mount, then looks the mount up by it; divergence.sh declares it.
#    After the loader, so .env (or the environment) can override it for a clinic that renamed by
#    hand or keeps the engine's default; the default is the org's choice.
IV_MOUNT="${IV_MOUNT:-Intranet}"
