#!/usr/bin/env bash
# S4's replay engine — the patch queue's whole lifecycle, everything the Replay workflow
# (.github/workflows/replay.yml) rides:
#
#   parity    main mirrors upstream byte-for-byte outside the fork-infra allowlist (D6)
#   sync      merge upstream/main into main — the mirror tracks upstream's release cadence
#   replay    the queue: three-outcome rule per patch, into a worktree, force-push aps/main
#   validate  upstream's own validators (codespell, docker-lint, json-validator) against a tree
#
# WHY PARITY IS TWO DIFFS, NOT ONE EXCLUDE LIST. The naive form — diff upstream..main excluding
# the allowlist — goes silent-green the day upstream ships a file at an allowlisted path: its
# side of the diff gets excluded too. The collision-safe form asserts both directions instead:
#   (a) --diff-filter=MD is EMPTY: no upstream file is modified or missing on main — with NO
#       excludes, so an upstream file landing on an allowlisted path reads as a modification
#       and fails LOUDLY (a human renames our file or restructures; never a silent exclusion);
#   (b) --diff-filter=A ⊆ allowlist: everything main adds beyond upstream is fork-infra.
# The allowlist is the D6 amendment recorded with images.yml, extended when instalador
# absorbed the fork (gestion's host bundle, wizard and release chain moved here): images.yml,
# replay.yml, release.yml, ci.yml, cleanboot.yml (the last three pre-listed so their landings
# never break parity — BUGS.md's own precedent), .codespellrc (slice 11's forced extension —
# see allowlisted()'s comment), scripts/, patches/, BUGS.md, host/, provisioning/, aps/,
# install.sh, VERSION, installer.pub — and readme.md is the ONE declared modification (slice
# 23): the fork declaration rides main's landing page under the strip-and-compare exception in cmd_parity — see DECLARED_MOD's comment; the (b) half is untouched, so upstream ever deleting readme.md turns main's copy into a rogue addition a human reconciles.
# Prefix entries are safe BECAUSE (a) still catches upstream adding anything
# under them as a missing file.
#
# WHY THE QUEUE REPLAYS FROM THE UPSTREAM TIP, NEVER FROM aps/main. aps/main is force-pushed CI
# output — replaying onto it would let one run's leftovers answer for the next. Every run
# rebuilds the whole tree from upstream's tip + the queue, so the three-outcome rule (ADR-0002,
# lifted to the fork) reads cleanly per patch: forward-dry-run applies; reverse-dry-run means
# upstream adopted the change (skip, and consider dropping the patch — the log says so);
# neither means upstream moved out from under it — abort, naming the patch (a red run IS the
# drift signal, never a reason to force anything; the bar is ≤6 weeks behind upstream). git
# apply is the tool on purpose: no fuzzy context, ever — a patch that only applies with fuzz
# is a patch that rots (the slice-4 ratification's strictness-is-a-feature rule). Patches are
# generated with git diff (a/ b/ prefixes) — that is the queue's file format.
#
# THE COVERAGE RULE, enforced before anything moves: every patch in the queue must be named by
# a row in scripts/brand-gate.sh or scripts/acquisition-gate.sh. A patch without a row changes
# the shipped tree with nothing measuring the change — unaudited (the gestion#170 lesson: a
# detector that stopped detecting looks like a quiet week). The same contract is what keeps CI
# green while the queue fills: rows FIRE only for queued patches, so the empty queue of slice
# 7 is an honest green, and every patch slice (8-13) lights its rows the moment it lands.
#
# Script patches (*.sh in the queue) are the generated channel: 010 will call
# scripts/retag.sh sed — ONE rule, never a hand-edited containers.json. They run with cwd =
# the worktree and APS_TOOLS_ROOT pointing at this checkout (the worktree carries NO
# fork-infra — it is upstream + patches, nothing else), and they are idempotent by contract:
# their own verify is the outcome (retag.sh sed dies if any upstream ref survives).
#
# Env (all overridable — the whole engine is offline-testable against scratch remotes, the
# slice-6 design-time de-risk pattern): REPLAY_UPSTREAM_REMOTE (upstream), REPLAY_UPSTREAM_URL
# (https://github.com/nextcloud/all-in-one.git), REPLAY_FORK_REMOTE (origin), REPLAY_APS_BRANCH
# (aps/main), REPLAY_TREE (.aps-replay-tree), REPLAY_PUSH (1; "0" = prove without publishing —
# the PR arm: parity, coverage, three-outcome, validators and gates all run, aps/main is never
# touched).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP="${REPLAY_UPSTREAM_REMOTE:-upstream}"
UP_URL="${REPLAY_UPSTREAM_URL:-https://github.com/nextcloud/all-in-one.git}"
FORK="${REPLAY_FORK_REMOTE:-origin}"
APS_BRANCH="${REPLAY_APS_BRANCH:-aps/main}"
WT="${REPLAY_TREE:-$REPO_ROOT/.aps-replay-tree}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# (org L7-6) The PAT used to ride an https://x-access-token:PAT@… URL passed as git-push
# argv — visible in `ps` output and covered only by git's version-dependent transport-error
# redaction. It now answers git's own credential prompt through GIT_ASKPASS: the helper is
# secret-free (it expands the environment at prompt time), lives in the trap-cleaned TMPD,
# and only ever speaks when git actually asks for credentials — which is only ever a push to
# the private fork (fetching public upstream never prompts).
if [ -n "${APS_BOT_PAT:-}" ]; then
  ASKPASS="$TMPD/git-askpass"
  cat >"$ASKPASS" <<'HELPER'
#!/bin/sh
# git calls this once per credential prompt, prompt text as its only argument — Username first, then Password.
case "$1" in *Username*) printf 'x-access-token\n' ;; *) printf '%s\n' "$APS_BOT_PAT" ;; esac
HELPER
  chmod 700 "$ASKPASS"
  export GIT_ASKPASS="$ASKPASS"
fi

# (org L7-2) The frozen wizard-string baseline: the upstream commit 060's sweep was last
# proven against. The drift report diffs the swept files between this sha and the current
# upstream tip — every added line is upstream content the queue never absorbed, the exact
# blind spot of the sentinel design (a NEW English string in a swept file passes every arm
# green). Non-gating by accepted resolution: it reports and annotates, never fails the run.
# Re-freeze with 'scripts/replay.sh drift-freeze' whenever 060 is regenerated.
WIZARD_BASELINE="$REPO_ROOT/scripts/wizard-drift-baseline"

die() { echo "FATAL: $*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }
usage() {
  cat >&2 <<'EOF'
usage: scripts/replay.sh <command>
  parity            main mirrors upstream byte-for-byte outside the fork-infra allowlist
  sync              merge upstream/main into main (local; the workflow pushes)
  replay            the queue: three-outcome apply into a worktree, force-push aps/main
  validate TREE     upstream validators (codespell, docker-lint, json-validator) against TREE
  drift-report      wizard-string drift report (org L7-2, non-gating): the swept files at the
                    upstream tip vs the frozen baseline — new content the 060 queue never
                    absorbed; operator-visible English among it means regenerate 060
  drift-freeze      re-freeze the wizard-string baseline at the current upstream tip
EOF
}

# The fork-infra allowlist (the D6 amendment, extended with instalador's absorption): paths
# upstream does not ship. Exact entries where upstream has neighbors (.github/workflows/
# carries 30 upstream files — only our five names are allowed), prefix entries where upstream
# has nothing (scripts/, patches/, host/, provisioning/, aps/ — safe because parity's (a) half
# still catches upstream ever adding anything under them).
# .codespellrc (slice 11's forced extension): patch 060's es-CL sweep puts correct Spanish
# words (momento, comando, ...) into the shipped tree AND into patches/*.patch's bytes on
# main — upstream's own codespell workflow fires on both surfaces and flags the same 16
# correct words, so the ignore-list config must exist on main (this allowlist entry) and in
# the replayed tree (patch 060 carries a byte-identical copy; main's copy must match it —
# the coverage-rule + codespell-green checks are the operational proof).
# THE ONE DECLARED MODIFICATION (slice 23): readme.md carries the fork declaration block on
# main — D2's landing-page surface (the repo a visitor lands on must declare the fork; aps/main
# is force-pushed CI output and no image ships a readme; the pure-patch vehicle would leave
# the landing page undeclared). It is the single upstream file main deliberately modifies, and
# the exception is SCOPED, not blanket: it holds only while main's copy minus the marker-
# delimited block strips back to byte-identical upstream bytes — enforced in cmd_parity below.
DECLARED_MOD="readme.md"
strip_declaration() {  # FILE — the marker-delimited fork declaration, deleted (the parity form)
  sed '/^<!-- aps-fork-declaration-start -->$/,/^<!-- aps-fork-declaration-end -->$/d' "$@"
}

# (P45, landing flow) patch 090's queue is the first to modify .github/workflows/**, and the
# GITHUB_TOKEN can NEVER push workflow files — the aps/main force-push (and any sync push whose
# merge carries upstream workflow changes) needs a PAT. The PAT rides GIT_ASKPASS (org L7-6,
# see the setup block above) — pushes below name the plain remote; when git needs credentials,
# the askpass helper supplies x-access-token/PAT without the token ever reaching a URL or argv.
allowlisted() {  # PATH
  case "$1" in
    .github/workflows/images.yml|.github/workflows/replay.yml|.github/workflows/release.yml|.github/workflows/ci.yml|.github/workflows/cleanboot.yml|.codespellrc|BUGS.md) return 0 ;;
    scripts/*|patches/*|host/*|provisioning/*|aps/*) return 0 ;;
    install.sh|VERSION|installer.pub) return 0 ;;
    *) return 1 ;;
  esac
}

fetch_upstream() {
  git remote get-url "$UP" >/dev/null 2>&1 || git remote add "$UP" "$UP_URL"
  git fetch "$UP" main || die "cannot fetch $UP main — is $UP_URL reachable?"
}

cmd_parity() {
  fetch_upstream
  local base f modified added rogue n
  base="$UP/main"
  # --no-renames on BOTH diffs, load-bearing: git detects renames by default and reports a
  # byte-identical fork-side `git mv` as a single R status — which BOTH diff-filter arms
  # exclude, so parity would go green while an upstream file silently went missing at its
  # path (the slice-7 verifier's find). Rename detection OFF forces the honest D+A pair:
  # the D dies here (the file went missing), the A dies on the allowlist check if rogue.
    # (a) upstream's files are never modified or missing on main — ONE scoped exception (slice 23)
  modified="$(git diff --name-only --diff-filter=MD --no-renames "$base" HEAD)"
  if [ -n "$modified" ]; then
    rest="$(grep -vxF "$DECLARED_MOD" <<<"$modified" || true)"
    if [ -n "$rest" ]; then
      echo "PARITY: *** FAIL *** — upstream files modified or missing on main:" >&2
      while IFS= read -r f; do [ -n "$f" ] && printf '  %s\n' "$f" >&2; done <<< "$rest"
      echo "  every change to mirrored files moves as a numbered patch (the one rule) — move this edit into patches/" >&2
      exit 1
    fi
    # the exception's own proof: main's readme.md minus the declaration block is byte-identical
    # to upstream's. pipefail makes a missing HEAD file die here; cmp makes a hand-edit below
    # the block die; a mangled marker pair leaves the block's bytes in and dies the same way.
    git show "HEAD:$DECLARED_MOD" | strip_declaration /dev/stdin >"$TMPD/readme.stripped" \
      || die "PARITY: *** FAIL *** — $DECLARED_MOD is missing on main (the declaration's own file)"
    git show "$base:$DECLARED_MOD" >"$TMPD/readme.upstream"
    cmp -s "$TMPD/readme.stripped" "$TMPD/readme.upstream" \
      || die "PARITY: *** FAIL *** — readme.md carries changes beyond the fork declaration block — every other change to mirrored files moves as a numbered patch (the one rule)"
  fi
  # (b) main's additions are fork-infra, nothing else
  added="$(git diff --name-only --diff-filter=A --no-renames "$base" HEAD)"
  rogue=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    allowlisted "$f" || rogue="${rogue}${f}
"
  done <<< "$added"
  if [ -n "$rogue" ]; then
    echo "PARITY: *** FAIL *** — files on main that upstream does not ship and the allowlist does not name:" >&2
    while IFS= read -r f; do [ -n "$f" ] && printf '  %s\n' "$f" >&2; done <<< "$rogue"
    exit 1
  fi
  n=0
  while IFS= read -r f; do [ -n "$f" ] && n=$((n+1)); done <<< "$added"
  echo "PARITY: PASS — upstream mirrored byte-for-byte; fork-infra: ${n} allowlisted path(s)"
}

cmd_sync() {
  fetch_upstream
  [ "$(git branch --show-current)" = "main" ] \
    || die "sync runs on main (on '$(git branch --show-current 2>/dev/null || echo detached)') — main is the mirror this command moves"
  if git merge-base --is-ancestor "$UP/main" HEAD 2>/dev/null; then
    say "mirror current — upstream is already contained in main"
    return 0
  fi
  # Identity rides the merge itself (cmd_replay's own idiom for its commit): the runner image
  # ships NO default git identity ("Committer identity unknown", red 2026-09-24/25 runs), and
  # an env-level config would leak the choice into every other git call this script makes.
  git -c user.name="aps-sync" -c user.email="sync@aps-conecta.invalid" merge --no-edit "$UP/main" \
    || die "merge failed — upstream touched a fork-infra path, or histories diverged; resolve by hand and NEVER force main (the loud path is the correct one)"
  say "mirror synced: upstream merged into main — push it (the workflow does; locally: git push $FORK main)"
}

cmd_replay() {
  fetch_upstream
  local base p id n=0
  base="$(git rev-parse "$UP/main")"
  # The queue, lexically sorted — three-digit prefixes order themselves: 010 < 020 < ... < 051 < ... < 080
  local patches=()
  shopt -s nullglob
  for p in "$REPO_ROOT"/patches/*; do patches+=("$p"); done
  shopt -u nullglob

  # Coverage before anything moves: a queued patch with no gate row is unaudited
  for p in "${patches[@]}"; do
    id="$(basename "$p")"; id="${id%%-*}"
    grep -q "^row $id " "$REPO_ROOT/scripts/brand-gate.sh" "$REPO_ROOT/scripts/acquisition-gate.sh" 2>/dev/null \
      || die "patch $(basename "$p") declares no gate row — add 'row $id …' to scripts/brand-gate.sh or scripts/acquisition-gate.sh (a patch that changes the shipped tree unmeasured is unaudited)"
  done

  # The worktree: upstream tip + the queue, rebuilt from scratch on every run
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  git worktree add --detach "$WT" "$base" >/dev/null \
    || die "cannot create the replay worktree at $WT"

  for p in "${patches[@]}"; do
    case "$p" in
      *.patch)
        if git -C "$WT" apply --check "$p" 2>/dev/null; then
          git -C "$WT" apply "$p" \
            || die "patch $(basename "$p") failed mid-apply (it checked clean — nothing else writes this worktree)"
          say "  applied $(basename "$p")"
        elif git -C "$WT" apply --check --reverse "$p" 2>/dev/null; then
          say "  already applied: $(basename "$p") — upstream adopted this change; consider dropping the patch"
          # (org L7-4) "already applied" was a log line in a scheduled-run log nobody reads —
          # scheduled-run logs are not an alerting surface. The annotation puts every skip on
          # the run's face in the Actions UI and carries the queue-hygiene rule itself: two
          # consecutive scheduled-run skips must end in the patch being dropped or re-justified
          # in its header. The consecutive count stays a maintainer's eyeball count on the
          # daily annotations on purpose — a cross-run mechanical ledger would need state
          # committed to the mirror, heavy machinery for a hygiene signal the tree stays
          # correct without.
          echo "::warning::patch $(basename "$p") is already applied by upstream — drop it, or re-justify keeping it in the patch header (queue hygiene: two consecutive scheduled-run skips must end in drop-or-rejustify; org L7-4)"
        else
          die "patch $(basename "$p") no longer applies — upstream moved; regenerate it (ADR-0002's abort outcome; the drift bar is ≤6 weeks)"
        fi ;;
      *.sh)
        ( cd "$WT" && APS_TOOLS_ROOT="$REPO_ROOT" bash "$p" ) \
          || die "script patch $(basename "$p") failed — its own verify is the outcome; fix the generator, never the tree"
        say "  applied $(basename "$p") (script — idempotent by contract)" ;;
      *)
        die "patch $(basename "$p") is neither .patch nor .sh — the queue holds exactly these two kinds" ;;
    esac
    n=$((n+1))
  done

  if [ "${REPLAY_PUSH:-1}" = "0" ]; then
    say "REPLAY_PUSH=0 — proving without publishing (the PR arm): aps/main untouched"
    echo "REPLAY: ${n} patch(es) proven over upstream ${base:0:12} — worktree kept at $WT for validate/gates"
    return 0
  fi

  # One replay commit on top of upstream — aps/main is force-pushed CI output by design (D6)
  git -C "$WT" add -A
  if git -C "$WT" diff --cached --quiet; then
    say "queue produced no tree changes — aps/main = upstream ${base:0:12}"
    git push --force "$FORK" "$base:refs/heads/$APS_BRANCH" \
      || die "cannot push aps/main (upstream tip) to $FORK — check contents: write"
  else
    git -C "$WT" -c user.name="aps-replay" -c user.email="replay@aps-conecta.invalid" \
      commit -q -m "aps: replay ${n} patch(es) over upstream ${base:0:12}"
    # -C "$WT": HEAD is the WORKTREE's replay commit — a bare push would run in this checkout's
    # cwd and publish MAIN's tip instead (the de-risk caught exactly this). The base push above
    # is sha-based and cwd-independent; this one names a ref, so it must run in the worktree.
    git -C "$WT" push --force "$FORK" "HEAD:refs/heads/$APS_BRANCH" \
      || die "cannot force-push aps/main to $FORK — aps/main is CI output; main itself is never forced"
  fi
  echo "REPLAY: ${n} patch(es) over upstream ${base:0:12} -> $APS_BRANCH (worktree kept at $WT for validate/gates)"
}

cmd_validate() {
  local tree="${1:?validate needs TREE (e.g. .aps-replay-tree)}"
  [ -d "$tree" ] || die "no tree at '$tree'"
  local f venv
  venv="$TMPD/venv"
  python3 -m venv "$venv" || die "cannot create the validator venv (PEP 668 — everything installs in here, never the system python)"
  "$venv/bin/pip" install --quiet codespell json-spec || die "cannot install codespell+json-spec"

  echo "== codespell (upstream's own flags — the es-CL strings of patch 060 ride this gate too) =="
  "$venv/bin/codespell" --check-filenames --check-hidden "$tree" \
    || { echo "VALIDATE: codespell FAIL — a misspelling entered via a patch (upstream's own tree passes this)" >&2; exit 1; }

  echo "== docker-lint (hadolint, upstream's own ignores — patches 020/030 edit this Dockerfile) =="
  timeout 60 wget -q https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64 -O "$TMPD/hadolint" \
    || die "cannot download hadolint (bounded 60s)"
  chmod +x "$TMPD/hadolint"
  : > "$TMPD/hadolint.log"
  while IFS= read -r f; do
    "$TMPD/hadolint" "$f" --ignore DL3018 --ignore DL3041 --ignore DL3066 | tee -a "$TMPD/hadolint.log"
  done < <(find "$tree/Containers" -name "*Dockerfile")
  if [ -s "$TMPD/hadolint.log" ]; then
    echo "VALIDATE: docker-lint FAIL — hadolint findings above (upstream's own tree passes this)" >&2
    exit 1
  fi

  echo "== json-validator (json-spec, upstream's exact commands — 010 edits containers.json) =="
  if ! "$venv/bin/json" validate --schema-file="$tree/php/containers-schema.json" --document-file="$tree/php/containers.json"; then
    echo "VALIDATE: json FAIL — containers.json no longer validates against upstream's schema" >&2
    exit 1
  fi
  : > "$TMPD/json-validator.log"
  while IFS= read -r f; do
    "$venv/bin/json" validate --schema-file="$tree/php/containers-schema.json" --document-file="$f" 2>&1 | tee -a "$TMPD/json-validator.log"
  done < <(find "$tree/community-containers" -name "*.json")
  if grep -q "document does not validate with schema.\|invalid JSONFile" "$TMPD/json-validator.log"; then
    echo "VALIDATE: json FAIL — a community-containers file does not validate" >&2
    exit 1
  fi
  echo "VALIDATE: PASS — codespell, docker-lint, json-validator green against $tree (twig-lint rides the workflow's PHP step)"
}

cmd_drift_report() {
  # (org L7-2, the non-gating half) The sentinel design cannot see NEW upstream strings — a
  # fresh English line in a swept file passes every escl_sweep arm green. This report closes
  # the visibility gap: everything upstream ADDED to a swept file since the frozen baseline
  # prints as a warning annotation, with the regenerate-060 instruction riding the warning.
  # The baseline freezes the upstream tip the current 060 was proven against, so the diff is
  # exactly "what upstream did to the wizard's surfaces that the queue never absorbed". Code
  # lines land in the report too — a maintainer filters by eye; the report never gates.
  [ -f "$WIZARD_BASELINE" ] \
    || die "scripts/wizard-drift-baseline is missing — freeze one with 'scripts/replay.sh drift-freeze' before the drift report can run"
  fetch_upstream
  local base f line new=0
  base="$(cat "$WIZARD_BASELINE")"
  git rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
    || die "the frozen baseline sha ${base} is not reachable — re-freeze against a fetched upstream commit ('scripts/replay.sh drift-freeze')"
  while IFS= read -r f; do
    while IFS= read -r line; do
      printf '::warning::wizard drift in %s — upstream content the 060 sweep never absorbed: %s (review for operator-visible English; regenerate 060 if any)\n' "$f" "$line"
      new=$((new + 1))
    done < <(git diff "$base" "$UP/main" -- "$f" | sed -n -e '/^+++/d' -e '/^+$/d' -e 's/^+//p')
  done < <(bash "$REPO_ROOT/scripts/brand-gate.sh" --swept-files)
  if [ "$new" -gt 0 ]; then
    echo "WIZARD DRIFT: $new new line(s) in the swept files since the frozen baseline — operator-visible English among them means 060 must be regenerated (non-gating: this report never fails the run)"
  else
    echo "WIZARD DRIFT: none — upstream moved no swept file since the frozen baseline"
  fi
}

cmd_drift_freeze() {
  fetch_upstream
  git rev-parse "$UP/main" >"$WIZARD_BASELINE"
  say "wizard-string baseline frozen at $(cat "$WIZARD_BASELINE") (the upstream tip) — run this whenever 060 is regenerated, so the drift report measures from the new cut point"
}

case "${1:-}" in
  parity)        shift; cmd_parity "$@" ;;
  sync)          shift; cmd_sync "$@" ;;
  replay)        shift; cmd_replay "$@" ;;
  validate)      shift; cmd_validate "$@" ;;
  drift-report)  shift; cmd_drift_report "$@" ;;
  drift-freeze)  shift; cmd_drift_freeze "$@" ;;
  *)             usage; exit 1 ;;
esac
