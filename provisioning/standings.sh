#!/usr/bin/env bash
# provisioning/standings.sh — THE standing-account uid derivation (org L5-11).
#
# Phase 50 creates one account per POSITION; the roster (usuarios.csv) must refuse uids that
# collide with them; divergence declares them; provisionador reserves them. That derivation
# used to live in three hand-kept copies (50-users.sh's loops, divergence.sh's re-derivation,
# provisionador.py's standing_uids()) that could only drift apart silently — the divergence
# copy was documented to "fail loud" on drift, which on a clinic is a report nobody reads.
# One home now: both bash readers source THIS file; provisionador delegates to it.
#
# Expected environment (both are seed.sh globals; phase 50 sees them through the subshell):
#   SITE_TEAMS  — "id|display" entries; every `sector-X` contributes `jefe.X`
#   SITE_ROLES  — "id|display|category" entries (optional); every cat-jefaturas `role-X`
#                 contributes X with `-` → `.`
# plus the four positions every CESFAM has. NOT the wizard's `admin` — that account is the
# installer's, not a phase-50 position; divergence and provisionador add it on their own.
standing_uids() {
  printf '%s\n' director subdirector jefe.farmacia jefe.some
  local entry id uid category
  for entry in "${SITE_TEAMS[@]}"; do
    id="${entry%%|*}"
    case "$id" in sector-*) printf 'jefe.%s\n' "${id#sector-}" ;; esac
  done
  declare -p SITE_ROLES >/dev/null 2>&1 || SITE_ROLES=()
  for entry in "${SITE_ROLES[@]}"; do
    id="${entry%%|*}"; category="${entry##*|}"
    [ "$category" = cat-jefaturas ] || continue
    uid="${id#role-}"; printf '%s\n' "${uid//-/.}"
  done
}

# The cargo account's first password (a8). The Provisionador seals one per account into
# credentials.txt with the planilla's and passes them as STANDING_PASSWORDS="uid:pw uid:pw …" (hex,
# no spaces). `make install` without it — the compose lab, Clean boot — passes none, and every
# account takes FIXTURE_USER_PASSWORD. A list that lacks a uid is refused: the derivations drifted.
standing_password() {  # UID
  local kv
  if [ -z "${STANDING_PASSWORDS:-}" ]; then printf '%s' "$FIXTURE_USER_PASSWORD"; return 0; fi
  for kv in $STANDING_PASSWORDS; do
    [ "${kv%%:*}" = "$1" ] && { printf '%s' "${kv#*:}"; return 0; }
  done
  echo "FATAL: la cuenta de cargo $1 no tiene contraseña sellada — vuelva a cargar la planilla" >&2
  return 1
}

# --self-test (org L5-11's parity gate, hermetic): a fixture site exercises every derivation
# branch, and the output is asserted exactly — a changed derivation changes this list, and
# any consumer that re-derives by hand drifts from it visibly.
standings_self_test() {
  local tmp; tmp="$(mktemp -d)" || return 1
  SITE_TEAMS=("sector-norte| Norte" "sector-sur|Sur" "atencion|Atención")
  SITE_ROLES=("role-jefe-sar|Jefe/a SAR|cat-jefaturas" "role-tens|TENS|cat-clinico")
  local got want
  got="$(standing_uids | sort)"
  want="$(printf '%s\n' director jefe.farmacia jefe.norte jefe.sar jefe.some jefe.sur subdirector | sort)"
  if [ "$got" != "$want" ]; then
    echo "self-test FAIL: derivation changed — got:" >&2
    printf '%s\n' "$got" >&2
    echo "want:" >&2; printf '%s\n' "$want" >&2
    rm -rf "$tmp"; return 1
  fi
  # the empty site: four fixed positions, nothing else
  SITE_TEAMS=(); SITE_ROLES=()
  got="$(standing_uids | sort)"
  want="$(printf '%s\n' director jefe.farmacia jefe.some subdirector | sort)"
  [ "$got" = "$want" ] || { echo "self-test FAIL: empty-site arm" >&2; return 1; }
  # standing_password: the sealed one; the shared one only without a list; a gap refused
  got="$(STANDING_PASSWORDS="director:aa11 jefe.some:bb22" standing_password jefe.some)"
  [ "$got" = bb22 ] || { echo "self-test FAIL: the sealed password was not the one returned" >&2; return 1; }
  got="$(STANDING_PASSWORDS="" FIXTURE_USER_PASSWORD=ff00 standing_password director)"
  [ "$got" = ff00 ] || { echo "self-test FAIL: no list did not fall back to FIXTURE_USER_PASSWORD" >&2; return 1; }
  got="$(STANDING_PASSWORDS="director:aa11" FIXTURE_USER_PASSWORD=ff00 standing_password subdirector 2>&1)" \
    && { echo "self-test FAIL: a uid missing from the list was answered" >&2; return 1; }
  case "$got" in *"subdirector no tiene contraseña sellada"*) ;;
    *) echo "self-test FAIL: the refusal does not name the account: $got" >&2; return 1 ;; esac
  rm -rf "$tmp"
  echo "self-test: standing_uids arms OK"
}
case "${1:-}" in
  --self-test) standings_self_test; exit $? ;;
esac
