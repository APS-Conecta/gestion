#!/usr/bin/env bash
# Shared preamble: source this first from anything that reads .env or runs `docker compose`.
# Four jobs, all load-bearing; sourced by install.sh, seed.sh, divergence.sh, smoke.sh,
# office-smoke.sh, seed-idempotent.sh, wait-ready.sh and (transitively) every provisioning phase.
#
# 1. cd to the repo root. Every `docker compose` call resolves compose.yaml from the process cwd, so
#    `bash scripts/smoke.sh` from anywhere else reported the containers as not running and sent the
#    operator off to restart a healthy stack.
#
# 2. Read .env the way docker compose reads it, WITHOUT sourcing it. `set -a; . .env` runs every
#    value through bash expansion, so the two readers disagree about the same key: compose turns
#    `abc$$def` into `abc$def`, bash into `abc<pid>def`. That is a JWT secret which works in the
#    documentserver and fails in the connector, with office-smoke green either way. `$VAR` expands
#    the same, and `$(...)`/backticks EXECUTE on every `make seed`.
#    So: split on the first `=`, strip one layer of quotes, undo compose's `$$`, expand nothing else.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "FAIL: cannot cd to the repo root" >&2; exit 1; }

# 3. occ + raw exec inside the running Nextcloud container — one seam, for every caller of this
#    file. THE D5 SEAM (docker-exec port): the transport is `docker exec` against the AIO nextcloud
#    container, whose name is env-overridable — default nextcloud-aio-nextcloud (fixed by AIO's
#    php/containers.json:145). A compose dev stack or the pre-AIO live stack points NC_CONTAINER at
#    its own compose container (compose.yaml's `name:` pins ours: apsconecta-gestion-nextcloud-1;
#    set it in .env — the loader below exports it like any other key) until S10 migrates the stack.
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
  docker exec "${opts[@]}" "${NC_CONTAINER:-nextcloud-aio-nextcloud}" "$@"
}
occ() { nc_exec --user www-data -- php /var/www/html/occ "$@"; }

# 4. The clinic this stack serves, for the callers that need one — seed.sh, install.sh and
#    divergence.sh. A function, not a check at source time: smoke.sh, office-smoke.sh,
#    seed-idempotent.sh and wait-ready.sh source this file too and must keep working on a checkout
#    that has no clinic yet.
require_site() {
  [ -n "${SITE:-}" ] || {
    echo "FATAL: SITE is unset — .env must name the establishment this stack serves." >&2
    echo "       No establishment ships with this repo; pick yours from the DEIS register:" >&2
    echo "         scripts/deis.py                              # search, then pick a number" >&2
    echo "       then set SITE=<slug> in .env. README step 3 walks it." >&2
    echo "       No .env yet? run: make setup" >&2
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

# 5. Refuse to provision a clinic with the secrets this repository publishes.
#    env-init.sh generates all four from /dev/urandom, so a placeholder only survives a hand-copy
#    of the template — which is exactly what README step 2 used to ask for, and what somebody does
#    when `make setup` refuses because .env already exists. The result is a CESFAM whose admin
#    password is readable by anyone who can read this repo.
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
    echo "         rm .env && make setup     # generates every secret from /dev/urandom" >&2
    echo "       Only do that on a stack that has not been installed yet — .env is the one copy" >&2
    echo "       of the secrets a running instance was installed with." >&2
    return 1
  }
}

# org L5-05 round-trip gate, in the repo's --self-test idiom (db-dump/uninstall/comuna
# precedents). Three arms, all hermetic: (1) a fixture .env whose tricky-but-legal values
# load exactly as the loader intends (comment strip, quoted hashes, $$ undo); (2) compose
# parity over the same fixture — `docker compose --env-file config` resolves values the way
# the runtime reader does, so parity is asserted, not assumed; (3) a multi-line quoted value
# is REFUSED loudly instead of silently loading its first half. The fixture IS the scratch
# root's .env because the loader reads ./.env relative to its own root — the scratch copy
# makes both readers see the same bytes.
env_self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)" || return 1
  local fx="$tmp/.env"
  # every ${VAR:?} compose demands, placeholders — `config` resolves without starting
  # anything, and the fixture only has to be PARSEABLE by both readers the same way
  cat > "$fx" <<'FIX'
POSTGRES_DB=apsconecta
POSTGRES_USER=apsconecta
POSTGRES_PASSWORD=fixture-not-a-real-secret
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=fixture-not-a-real-secret
NEXTCLOUD_TRUSTED_DOMAINS=localhost
OFFICE_JWT_SECRET=fixture-not-a-real-secret
HTTP_PORT=8180
OFFICE_PORT=9980
TILES_PORT=8084
# a whole-line comment
UNQUOTED_WITH_COMMENT=some-value # and a trailing one
DOUBLE_QUOTED_HASH="value # stays"
SINGLE_QUOTED_HASH='other # stays'
DOLLAR_DOUBLED=abc$$def
FIX
  mkdir -p "$tmp/scripts"
  cp "${BASH_SOURCE[0]}" "$tmp/scripts/env.sh"
  ( cd "$tmp" && . ./scripts/env.sh 2>/dev/null
    [ "${POSTGRES_DB:-}" = apsconecta ] && [ "${UNQUOTED_WITH_COMMENT:-}" = some-value ] \
      && [ "${DOUBLE_QUOTED_HASH:-}" = 'value # stays' ] && [ "${SINGLE_QUOTED_HASH:-}" = 'other # stays' ] \
      && [ "${DOLLAR_DOUBLED:-}" = 'abc$def' ]
  ) || { echo "self-test FAIL: loader arm — the loader misparsed the fixture" >&2; rc=1; }
  # the compose-parity arm: needs only the docker CLI (config resolves; nothing starts).
  # POSTGRES_DB is observable in services.db.environment — the key the fixture shares with
  # the real compose file, so both readers are compared on the SAME variable.
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
     && [ -f "$(dirname -- "${BASH_SOURCE[0]}")/../compose.yaml" ]; then
    local got
    got="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && docker compose --env-file "$fx" -f compose.yaml config --format json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["db"]["environment"].get("POSTGRES_DB",""))' 2>/dev/null || true)"
    [ "$got" = "apsconecta" ] || { echo "self-test FAIL: compose-parity arm — compose resolved POSTGRES_DB as '$got'" >&2; rc=1; }
  else
    echo "self-test note: docker/compose absent — parity arm skipped on this box"
  fi
  # the multi-line refusal arm: a quoted value split across lines must fail the whole load
  printf 'BROKEN_MULTI="first half of a value\n' > "$fx"
  printf 'still inside the quote"\nX=1\n' >> "$fx"
  ( cd "$tmp" && . ./scripts/env.sh >/dev/null 2>&1 ) \
    && { echo "self-test FAIL: multi-line arm — the loader accepted a split quoted value" >&2; rc=1; }
  rm -rf "$tmp"
  [ "$rc" = 0 ] && echo "self-test: env.sh loader arms OK"
  return "$rc"
}
# Only when EXECUTED directly: db-dump.sh (and any future caller) sources this file BEFORE
# its own --self-test dispatch, and a sourced case sees the caller's $1 — unguarded, env's
# arms answered for db-dump and hollowed its detector arm to silent green (round-1 catch).
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
