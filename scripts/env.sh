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

# 3. occ inside the running nextcloud container — one definition, for every caller of this file.
occ() { docker compose exec -T --user www-data nextcloud php occ "$@"; }

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

  local still=() line key shipped
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    shipped=${line#*=}
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    # Only the keys the template deliberately leaves for a human to replace.
    case "$shipped" in *change-me*) ;; *) continue ;; esac
    [ "${!key:-}" = "$shipped" ] && still+=("$key")
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
    case "$_val" in
      \"*\") _val=${_val#\"}; _val=${_val%\"} ;;
      \'*\') _val=${_val#\'}; _val=${_val%\'} ;;
    esac
    export "$_key=${_val//\$\$/\$}"
  done < .env
  unset _line _key _val
fi
