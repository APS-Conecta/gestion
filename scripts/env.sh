#!/usr/bin/env bash
# Shared preamble: source this first from anything that reads .env or runs `docker compose`.
# Its callers here are the Makefile (fix-mount-perms), wait-ready.sh and test.sh's secrets gate.
# The installer (instalador) carries its own, newer copy for its provisioning; this one is the
# dev stack's. Four jobs remain, all load-bearing.
#
# 1. cd to the repo root. Every `docker compose` call resolves compose.yaml from the process cwd, so
#    `bash scripts/wait-ready.sh` from anywhere else reported the containers as not running and sent
#    the operator off to restart a healthy stack.
#
# 2. Read .env the way docker compose reads it, WITHOUT sourcing it. `set -a; . .env` runs every
#    value through bash expansion, so the two readers disagree about the same key: compose turns
#    `abc$$def` into `abc$def`, bash into `abc<pid>def`. That is a JWT secret which works in the
#    documentserver and fails in the connector, with the office check green either way. `$VAR` expands
#    the same, and `$(...)`/backticks EXECUTE on every run.
#    So: split on the first `=`, strip one layer of quotes, undo compose's `$$`, expand nothing else.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "FAIL: cannot cd to the repo root" >&2; exit 1; }

# 3. occ + raw exec inside the running Nextcloud container — one seam, for every caller of this
#    file, and the one place that decides WHICH container (#197, R41). nc_container resolves it on
#    first use and caches it in this shell: a value from the environment or .env wins (the loader
#    below exports it); otherwise docker answers — the AIO container when it runs ($AIO_NC, fixed
#    by AIO's php/containers.json:145), the compose one when only it runs (compose.yaml's `name:`
#    pins apsconecta-gestion-nextcloud-1), else $AIO_NC, the production posture, so a stopped
#    stack fails loudly at require_installed. Both up: AIO wins, so a checkout that serves the
#    compose lab beside a running AIO testbed sets NC_CONTAINER in its .env.
#    Lazy, never at source time: a docker ps here would run before every sourcer's first line — a
#    hung daemon would then stall every sourcer's first line — and for
#    callers that never touch the container. Not exported: a caller may source this file before
#    `make up` starts a compose stack, and an exported pre-bring-up answer would pin every child
#    (wait-ready) to the wrong container; every reader sources this file, so each process
#    asks for itself (`export -n` also covers an empty NC_CONTAINER= line the loader exported).
#    The cache is this shell's: occ inside a pipe or $(…) is a subshell, so scripts that make
#    dozens of occ calls call nc_container once after their first output.
#    is_aio = "the AIO stack is running". `grep -x >/dev/null`, not `-qx`: grep reads to EOF, so
#    docker never takes a SIGPIPE that a pipefail caller would read as "not running".
AIO_NC=aps-conecta-nextcloud
is_aio() { docker ps --format '{{.Names}}' 2>/dev/null | grep -x "$AIO_NC" >/dev/null; }
nc_container() {  # sets NC_CONTAINER once per shell; always returns 0
  [ -n "${NC_CONTAINER:-}" ] && return 0
  if ! is_aio && docker ps --format '{{.Names}}' 2>/dev/null | grep -x apsconecta-gestion-nextcloud-1 >/dev/null; then
    NC_CONTAINER=apsconecta-gestion-nextcloud-1
  else
    NC_CONTAINER=$AIO_NC
  fi
  export -n NC_CONTAINER
}
#
#    nc_exec's contract is forced by docker exec's own grammar — options BEFORE the container,
#    command AFTER — so every docker-exec option word comes first, then `--`, then the command.
#    A missing `--` fails loudly rather than letting an option word run as the command (B-014: a
#    seam that can misparse silently is not a seam). No -T (docker exec has no such flag — no TTY
#    is its default, which is what compose's -T was buying); -i only where a caller streams stdin
#    (a caller streaming a patch or a tarball, passed per-site; occ() itself
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
# 4. Refuse to provision a clinic with the secrets this repository publishes.
#    env-init.sh generates all four from /dev/urandom, so a placeholder only survives a hand-copy
#    of the template — which is what somebody does
#    when `make setup` refuses because .env already exists. The result is a CESFAM whose admin
#    password is readable by anyone who can read this repo.
#
#    Read out of .env.example rather than listed here: the template is what defines a placeholder,
#    so one that gets reworded does not quietly stop being one, and a secret added there is covered
#    on the day it is added. A function, not a check at source time — the read-only
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
