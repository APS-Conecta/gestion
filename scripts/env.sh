#!/usr/bin/env bash
# Shared preamble: source this first from anything that reads .env or runs `docker compose`.
# Two jobs, both load-bearing, and four callers — seed.sh, smoke.sh, office-smoke.sh, office-formats.sh.
#
# 1. cd to the repo root. Every `docker compose` call resolves compose.yaml from the process cwd, so
#    `bash scripts/smoke.sh` from anywhere else reported the containers as not running and sent the
#    operator off to restart a healthy stack.
#
# 2. Read .env the way docker compose reads it, WITHOUT sourcing it.
#    `set -a; . .env` runs every value through bash expansion. Measured against a real container:
#      .env line          compose gives the container      `. .env` gave bash
#      SECRET=abc$$def    abc$def                          abc1108252def   (the shell's PID)
#    .env.example tells you to write `$$` for a literal `$` precisely because compose eats one, so
#    following the documented advice made the two readers disagree about the same key — a JWT secret
#    that works in the documentserver and fails in the connector, with office-smoke green either way
#    because it only checks /healthcheck. `$VAR` expands the same way, and `$(...)`/backticks EXECUTE
#    on every `make seed`.
#    So: split on the first `=`, strip one layer of surrounding quotes, undo compose's `$$` escape,
#    and expand nothing else.

cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "FAIL: cannot cd to the repo root" >&2; exit 1; }

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
