#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
# The built set's one-tree assert — the Images workflow's manifest job runs this before the
# announce (#76). Every build job resolves build-ref itself at checkout, so a ref that moved
# mid-run would announce a set built from mixed trees; this reds the announce first.
#
# THE LIST IS needs. The manifest job already lists every build in its needs array (outputs
# resolve only for direct dependencies — B-014), and the workflow hands this script the whole
# needs context as one JSON document, so the assert walks THAT one list: a new build (#45's
# buscador) is one job that exports sha plus one needs entry — no clause, no variable here.
# The contract a build job owes: an id starting with build- and an outputs.sha naming the
# commit it checked out.
#
# Every red is the one message (unchanged since the clause era, the count excepted — the list
# owns the count now): a build that resolved empty reds, and so does a list that lost its
# builds — never a green for the wrong reason (B-014's lesson).
#
# Usage:
#   scripts/lockstep.sh                the assert (from the manifest job's step)
#   scripts/lockstep.sh --self-test    the hermetic self-test (jq over fixture needs documents — no network)
#
# Env: NEEDS_JSON (the workflow's toJSON(needs) document), BUILD_REF (the ref the message names).
set -uo pipefail

die() { echo "FATAL: $*" >&2; exit 1; }

fail_msg() { # N REF — the one message, single-sourced: the red prints these bytes, the self-test pins them
  printf "FAIL: the %s builds checked out different commits of '%s' — the ref moved mid-run; re-run the pipeline" "$1" "$2"
}

usage() {
  cat >&2 <<'EOF'
usage: scripts/lockstep.sh [--self-test]
Env: NEEDS_JSON (the workflow's toJSON(needs)), BUILD_REF (the ref the FAIL message names)
EOF
}

lockstep() { # NEEDS_JSON BUILD_REF — every build-* entry must report the same non-empty sha
  local doc="$1" ref="$2" rows n first job sha bad
  rows="$(printf '%s' "$doc" | jq -r '
    to_entries
    | map(select(.key | startswith("build-")))
    | sort_by(.key)[]
    | "\(.key) \(.value.outputs.sha // "")"
  ')" || die "NEEDS_JSON is not a JSON document"
  n=0
  [ -z "$rows" ] || n=$(( $(printf '%s\n' "$rows" | wc -l) ))
  red() { fail_msg "$n" "$ref" >&2; exit 1; }
  [ "$n" -gt 0 ] || red
  first=""; bad=0
  while read -r job sha; do
    echo "built from: ${job} ${sha:-<empty>}"
    [ -n "$sha" ] || bad=1
    if [ -n "$first" ]; then [ "$sha" = "$first" ] || bad=1; else first="$sha"; fi
  done <<<"$rows"
  [ "$bad" -eq 0 ] || red
  echo "one tree: ${first} across ${n} builds"
}

selftest() { # jq over fixture needs documents — the manifest job's real shape, no network
  local n=0 failed=0 out rc
  local s1="0123456789abcdef0123456789abcdef01234567" s2="fedcba9876543210fedcba9876543210fedcba98"
  # the manifest job's needs, the real shape: retag carries retag-source, matrix and boot-smoke
  # no outputs at all — the walk must ignore every non-build entry and its outputs. Every
  # fixture is assembled with jq itself (never string surgery): valid by construction.
  local base four four_diff four_empty five five_diff none
  base='{"retag":{"result":"success","outputs":{"retag-source":"ours:v0.4.0"}},"matrix":{"result":"success","outputs":{}},"boot-smoke":{"result":"success","outputs":{}}}'
  builds_doc() { # BASE then JOB:SHA pairs — each build-* needs entry folded onto the document
    local d="$1" p job sha
    shift
    for p in "$@"; do
      job="${p%%:*}"; sha="${p#*:}"   # an empty SHA (JOB:) folds an entry with no outputs at all
      d="$(printf '%s' "$d" | jq -c --arg k "$job" --arg s "$sha" \
          '. + {($k): {result: "success", outputs: (if $s == "" then {} else {sha: $s} end)}}')"
    done
    printf '%s' "$d"
  }
  four="$(builds_doc "$base" "build-aio-apache:$s1" "build-aio-nextcloud:$s1" "build-aio-postgresql:$s1" "build-all-in-one:$s1")"
  four_diff="$(builds_doc "$base" "build-aio-apache:$s1" "build-aio-nextcloud:$s2" "build-aio-postgresql:$s1" "build-all-in-one:$s1")"
  four_empty="$(builds_doc "$base" "build-aio-apache:" "build-aio-nextcloud:$s1" "build-aio-postgresql:$s1" "build-all-in-one:$s1")"
  five="$(builds_doc "$four" "build-buscador:$s1")"   # #45's shape: one more needs entry, nothing else
  five_diff="$(builds_doc "$four" "build-buscador:$s2")"
  none="$base"

  pass()  { n=$((n+1)); printf '  ok:   %s\n' "$1"; }
  flunk() { n=$((n+1)); failed=$((failed+1)); printf '  FAIL: %s\n' "$1" >&2; }
  case_run() { out="$(lockstep "$1" "$2" 2>&1)"; rc=$?; }                 # subshell: the red's exit is caught, not the self-test's
  assert_rc()    { if [ "$rc" = "$1" ]; then pass "$2"; else flunk "$2 (rc=$rc, want $1; out: ${out:0:200})"; fi; }
  assert_line()  { if printf '%s\n' "$out" | grep -qxF "$1"; then pass "$2"; else flunk "$2 (missing line: $1)"; fi; }
  assert_count() { local c; c="$(printf '%s\n' "$out" | grep -cF "$2")"; if [ "$c" = "$1" ]; then pass "$3"; else flunk "$3 ($c lines, want $1)"; fi; }

  # the four of today, one tree — green, every build's commit on its own line
  case_run "$four" main
  assert_rc 0 "four builds, one tree: green"
  assert_count 4 "built from: " "four builds: each build's commit printed"
  assert_line "one tree: $s1 across 4 builds" "four builds: the one tree named"
  # one build resolved a different commit — red with the one message, every build still printed
  case_run "$four_diff" main
  assert_rc 1 "four builds, one differs: red"
  assert_line "$(fail_msg 4 main)" "the red's message is the one message (count from the list)"
  assert_count 4 "built from: " "the red still prints every build's commit"
  # a build that resolved empty (a null/missing sha) — red, never '' == '' green (B-014)
  case_run "$four_empty" main
  assert_rc 1 "a build with no sha: red (B-014)"
  assert_line "built from: build-aio-apache <empty>" "the empty build is printed as <empty>"
  assert_line "$(fail_msg 4 main)" "the empty build reds with the one message"
  # the list lost its builds — red, not a vacuous green (B-014)
  case_run "$none" main
  assert_rc 1 "no build in the list: red (B-014)"
  assert_line "$(fail_msg 0 main)" "the lost list reds with the one message"
  # #45's shape — one more needs entry IS the whole change: five builds, no clause anywhere
  case_run "$five" v0.5.0
  assert_rc 0 "five builds (#45's shape), one tree: green, list-driven"
  assert_count 5 "built from: " "five builds: each build's commit printed"
  assert_line "one tree: $s1 across 5 builds" "five builds: the one tree named"
  case_run "$five_diff" v0.5.0
  assert_rc 1 "five builds, one differs: red, the count from the list"
  assert_line "$(fail_msg 5 v0.5.0)" "the red names five — no 'four' left to go stale"
  # a needs document that is not JSON — the guard's own parse failure is a loud red, never silent
  case_run "not json" main
  assert_rc 1 "a non-JSON needs document: red"

  echo "self-test: $n checks OK"
  [ "$failed" -eq 0 ] || { echo "self-test: $failed FAILED" >&2; exit 1; }
}

case "${1:-}" in
  --self-test) selftest ;;
  "")
    if [ -z "${NEEDS_JSON:-}" ] || [ -z "${BUILD_REF:-}" ]; then
      usage
      die "NEEDS_JSON (toJSON(needs)) and BUILD_REF are required"
    fi
    lockstep "$NEEDS_JSON" "$BUILD_REF" ;;
  *) usage; exit 2 ;;
esac
