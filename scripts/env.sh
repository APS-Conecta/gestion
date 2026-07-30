#!/usr/bin/env bash
# Shared preamble: source this first from anything that reads .env or runs `docker compose`.
# Three jobs, all load-bearing, and five callers — seed.sh, smoke.sh, office-smoke.sh,
# seed-idempotent.sh and (transitively) every provisioning phase.
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

# 3. occ inside the running nextcloud container. Lives here because every caller of this file
#    needs it and each used to spell the same 8-word docker invocation out again — six copies,
#    one of which (smoke.sh) ignored its own variable two lines after defining it.
occ() { docker compose exec -T --user www-data nextcloud php occ "$@"; }

if [ -f .env ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    _key=${_line%%=*}
    _val=${_line#*=}
    # Ignore anything that is not a plain shell name, rather than trying to export it.
    case "$_key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    case "$_val" in
      \"*\") _val=${_val#\"}; _val=${_val%\"} ;;
      \'*\') _val=${_val#\'}; _val=${_val%\'} ;;
    esac
    export "$_key=${_val//\$\$/\$}"
  done < .env
  unset _line _key _val
fi
