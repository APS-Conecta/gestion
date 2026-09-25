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
  rm -rf "$tmp"
  echo "self-test: standing_uids arms OK"
}
case "${1:-}" in
  --self-test) standings_self_test; exit $? ;;
esac
