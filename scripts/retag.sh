#!/usr/bin/env bash
# S1's registry mechanics — the 20-image lockstep under ghcr.io/aps-conecta/*, everything the Images
# workflow (.github/workflows/images.yml) rides: the sibling list, the registry-side retag walk, the
# tag-completeness matrix, the digest manifest, and the generated sed that patch 010 reuses.
#
# WHY 20 IMAGES MUST MOVE TOGETHER. The wizard resolves every sibling's tag from the mastercontainer's
# OWN running image tag: %AIO_CHANNEL% becomes the channel (php/src/Docker/DockerActionManager.php,
# BuildImageName), which explodes the running image on ':' and takes field 2. The tag the operator
# runs IS the channel every sibling resolves by — one tag, twenty images, and a missing one is not
# "one feature down": the wizard's registry-reachability checks (isRegistryReachable) fail the start.
# That is why the matrix gates the announce, and why a tag is NEVER a raw digest: `image@sha256:...`
# explodes into a bogus channel and every sibling resolves a tag that cannot exist.
#
# WHAT MOVES AND WHAT BUILDS. 15 of the 20 are registry-side retags — `buildx imagetools create`
# copies the manifest list at the registry itself (seconds, zero runner disk, the multi-arch entries
# carried along byte-for-byte); aio-nextcloud (the apps+theme bake, patch 030), aio-apache (the
# installer's own certificate, patch 235), aio-postgresql (the database, built from this tree and
# tested before its push, patch 260), aio-eurooffice (the pinned DocumentServer, patch 015) and
# all-in-one (the reskin, patch 070) are real builds the workflow's build jobs own —
# from build-ref: THE TAG on every release arm, main on manual dispatches (Stage 3, D-3.4).
#
# THE SOURCE IS OURS (Stage 2 — the self-referential lockstep; the copy-from-upstream arm retired
# with the hard fork, D-rev 2026-10-19, D-3.5). The 15 registry-side retags copy from OUR previous
# suite tag, only ever: `retag TAG` resolves it (the newest git tag carrying a digest-complete
# set — git tags ARE the suite-tag list, D4 — falling back to the recorded aps/BASE.lock
# bootstrap, else FATAL naming the remedy), `--from-tag` pins it for repairs. From the first
# surviving tag on, the chain never needed nextcloud's registry — and now it cannot even read it.
# Resolution happens ONCE per run and is echoed as RETAG_SOURCE_RESOLVED=<spec>: the workflow
# threads that one resolution into the matrix, the manifest, and the release's package re-emit.
#
# THE SEAM 010 SHARES (merge-time now). containers.json's org swap is GENERATED, never
# hand-edited: the same org constants below, the same prefix rule, so an upstream merge that
# re-introduces upstream refs in containers.json re-swaps them with `retag.sh sed` — upstream's
# next container auto-includes (the sibling list is PARSED from php/containers.json, not
# hardcoded).
#
# Registry-call discipline: THE INDEX DIGEST
# (`imagetools inspect --format {{.Manifest.Digest}}` — pinning one platform's manifest would make
# the stack unresolvable on any other), every call bounded (B-015 — a registry call that hangs is
# not a gate), one retry before failing, and the registry's own stderr kept and quoted on the way
# out (B-003: a rate limit and a deleted tag must never print the same sentence).
#
# This file is fork-infra — first-class bytes on main since the hard fork (one tree, no mirror,
# no allowlist; see images.yml's PLACEMENT note).
#
# Usage:
#   scripts/retag.sh list                         the sibling image names, one per line (parsed, in order)
#   scripts/retag.sh sed FILE                     apply the org swap in place + verify (patch 010's generator)
#   scripts/retag.sh retag TAG [--from-tag T] [--force]
#                                    the 15-image registry-side walk — source OURS, always
#   scripts/retag.sh matrix TAG [--from-tag T]
#                                    the gate: all present + the copy keyed to the RESOLVED source
#   scripts/retag.sh manifest TAG                 the publish record, JSON on stdout (retag_source)
#   scripts/retag.sh --self-test                  the hermetic self-test (a stub registry — no network)
#
# Env: RETAG_CONTAINERS (default this repo's php/containers.json), RETAG_SOURCE (the source knob:
# ours | ours:<tag> — the workflow's input; the matrix and manifest jobs
# receive the RETAG job's ONE resolution through it, D-5), RETAG_BUILT_REF + RETAG_BUILT_SHA (the
# manifest's provenance, set by the workflow), RETAG_REMOTE (discovery's ls-remote target, default
# origin), RETAG_RESOLVE_DEPTH (how many newest tags to probe, default 3), RETAG_BASE_LOCK
# (default aps/BASE.lock — the self-test lever).
set -uo pipefail

ORG_UPSTREAM="nextcloud-releases"  # the upstream namespace — cmd_sed's swap source only (never a copy source post-fork)
ORG_FORK="aps-conecta"            # ours — 010's sed and this whole walk swap to exactly this
GHCR="ghcr.io"
BUILD_IMAGES=(aio-nextcloud aio-apache aio-postgresql aio-eurooffice)  # the siblings that are BUILT, not retagged (patches 030, 235, 260 and 015)
MASTER_IMAGE="all-in-one"         # the mastercontainer — not in containers.json; the operator's docker run names it
MIN_SIBLINGS="19"                 # shape-rot alarm (divergence's "expected 27+" precedent): a parse that
                                   # silently shrank would green a walk over fewer images than the suite has
BASE_LOCK="${RETAG_BASE_LOCK:-aps/BASE.lock}"  # the write-once bootstrap record — discovery's fallback (fork-infra on main)
RESOLVE_DEPTH="${RETAG_RESOLVE_DEPTH:-3}"     # newest tags discovery probes before the lock (B-015)

die() { echo "FATAL: $*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }
usage() {
  cat >&2 <<'EOF'
usage: scripts/retag.sh <command> [args]
  list                                  the sibling image names parsed from php/containers.json
  sed FILE                              apply the org swap in place + verify (patch 010's generator)
  retag TAG [--from-tag T] [--force]
                                        the registry-side walk — source OURS, always (the
                                        previous suite tag, resolved); --from-tag pins it
  matrix TAG [--from-tag T]
                                        the gate — all images present + the copy keyed to the
                                        resolved source (the immutable previous set, an
                                        integrity proof)
  manifest TAG                          the publish record, JSON on stdout (retag_source names
                                        the resolved spec)
  --self-test                            the hermetic self-test (a stub registry — no network)
EOF
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINERS="${RETAG_CONTAINERS:-$REPO_ROOT/php/containers.json}"

# Registry stderr lands here so a failure can quote it. Removed on any exit, which is why it is a
# trap and not an rm at the end (image-digests.sh's own pattern).
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT

list() { # print the sibling image names — the basename of each image ref, containers.json order
  [ -f "$CONTAINERS" ] || { echo "FATAL: no containers.json at $CONTAINERS" >&2; return 1; }
  python3 - "$CONTAINERS" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        services = json.load(fh)["aio_services_v1"]
except Exception as exc:
    sys.exit(f"cannot parse {sys.argv[1]}: {exc}")
for entry in services:
    image = entry.get("image", "")
    if not image:
        sys.exit(f"an aio_services_v1 entry has no image field — schema surprise; inspect {sys.argv[1]}")
    print(image.rsplit("/", 1)[-1])
PY
}

SIBS=()
RESOLVED_SPEC=""   # set by resolve_spec — the siblings_load idiom: side effect + status, never a captured die
BASE_LOCK_SPEC=""  # set by base_lock_spec, read immediately after by resolve_ours
siblings_load() { # fill SIBS once per run, floor-guarded — a shrunken parse must never green a walk (B-014)
  [ "${#SIBS[@]}" -gt 0 ] && return 0
  mapfile -t SIBS < <(list)
  [ "${#SIBS[@]}" -ge "$MIN_SIBLINGS" ] \
    || die "only ${#SIBS[@]} siblings parsed from $CONTAINERS — expected at least $MIN_SIBLINGS; a green walk over a shrunken set would be green without looking"
  # A built image upstream renamed would be retagged unpatched under its new name, and ours orphaned
  local b
  for b in "${BUILD_IMAGES[@]}"; do
    printf '%s\n' "${SIBS[@]}" | grep -qxF "$b" \
      || die "built image '$b' is not a sibling in $CONTAINERS — upstream renamed or dropped it; fix BUILD_IMAGES and images.yml's build job"
  done
}

tag_valid() { # TAG — a channel-valid Docker tag. ':' and '@' are excluded BY the charset itself; the
  #              moving channel names are refused on purpose: the suite tag IS the release tag
  #              (D12), and a fork-side 'latest' would let the update nag chase our own :latest and
  #              silently diverge from the release the clinic pinned.
  local t="$1"
  case "$t" in
    latest|latest-arm64|latest-aio) return 1 ;;
  esac
  [[ "$t" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
  return 0
}

spec_valid() { # SPEC — the canonical resolved source: 'ours:<tag>' (a previous set of ours).
  #               Bare 'ours' is the resolution INPUT, never the record — everything downstream
  #               (walk, matrix, manifest) carries the resolved form.
  local s="$1"
  case "$s" in
    ours:*)     tag_valid "${s#ours:}" || return 1 ;;
    *)          return 1 ;;
  esac
  return 0
}

digest() { # REF — print the index digest; non-zero (with the registry's own words on stderr) if
  #          unresolvable. One retry, 3s apart — the observed failure class is transient throttling,
  #          not drift (image-digests.sh, 2026-08-05). Bounded on every attempt (B-015).
  local out
  out="$(timeout 120 docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>"$ERRF")"
  case "$out" in
    sha256:*) printf '%s\n' "$out"; return 0 ;;
  esac
  sleep 3
  out="$(timeout 120 docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>"$ERRF")"
  case "$out" in
    sha256:*) printf '%s\n' "$out"; return 0 ;;
  esac
  sed 's/^/       registry said: /' "$ERRF" >&2
  return 1
}

retag_one() { # FORK_REF UPSTREAM_REF — the registry-side copy, bounded (B-015)
  timeout 300 docker buildx imagetools create -t "$1" "$2" 2>"$ERRF" \
    || { sed 's/^/       registry said: /' "$ERRF" >&2; return 1; }
}

is_built() { local b; for b in "${BUILD_IMAGES[@]}"; do [ "$1" = "$b" ] && return 0; done; return 1; }

base_lock_spec() { # aps/BASE.lock — grep-parsed, never sourced (untrusted-file discipline).
  #                   Comments and blanks skipped; EXACTLY one spec line — a stale first line
  #                   must never win silently (the FATAL remedy invites hand-appends); dies
  #                   otherwise. Sets BASE_LOCK_SPEC; returns 1 only when the file is absent.
  #                   An absolute RETAG_BASE_LOCK is honored as-is (the self-test lever).
  local f="$BASE_LOCK" spec n
  case "$f" in /*) : ;; *) f="$REPO_ROOT/$f" ;; esac
  [ -f "$f" ] || return 1
  n="$(grep -vE '^[[:space:]]*(#|$)' "$f" | wc -l)"
  [ "$n" -eq 1 ] \
    || die "$BASE_LOCK carries ${n} spec lines — exactly one; a stale first line would win silently"
  spec="$(grep -vE '^[[:space:]]*(#|$)' "$f")"
  spec_valid "$spec" \
    || die "$BASE_LOCK names '$spec' — not a valid source spec (ours:<tag>)"
  BASE_LOCK_SPEC="$spec"
  return 0
}

set_complete() { # TAG — 0 iff the registry holds a COMPLETE set under TAG (the matrix's presence
  #                 half, reused as discovery's probe). Bounded digest reads, B-015 throughout.
  local img
  for img in "${SIBS[@]}" "$MASTER_IMAGE"; do
    digest "$GHCR/$ORG_FORK/$img:$1" >/dev/null 2>&1 || return 1
  done
  return 0
}

remote_url() { # where discovery ls-remotes: RETAG_REMOTE wins (the self-test lever), else origin
  if [ -n "${RETAG_REMOTE:-}" ]; then printf '%s\n' "$RETAG_REMOTE"; return 0; fi
  git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    || die "cannot resolve the git remote for tag discovery — set RETAG_REMOTE"
}

resolve_ours() { # TAG — print the canonical spec for bare 'ours' on STDOUT (notes go to stderr:
  #                 the caller captures stdout). The NEWEST tag (excluding TAG itself — a set
  #                 cannot bootstrap itself) whose set is digest-complete. Git tags ARE the
  #                 suite-tag list (D4), so ls-remote is the catalogue — no registry API, no
  #                 token; the digest probe proves the set survived. A failed fetch is NOT an
  #                 empty catalogue — it dies, because a network blip must never become a silent
  #                 source change. Newest-first, depth-capped (B-015); aps/BASE.lock is the
  #                 recorded fallback (the bootstrap); neither is a FATAL naming the remedy.
  local tag="$1" url tags cand
  local -a cands=()
  url="$(remote_url)" || return 1
  tags="$(git ls-remote --tags "$url" 'refs/tags/v*' 2>/dev/null)" \
    || die "tag discovery could not reach '$url' — a failed fetch is not an empty catalogue; fix the remote or set RETAG_REMOTE"
  mapfile -t cands < <(printf '%s\n' "$tags" | grep -vE '\^\{\}$' | cut -f2 \
    | sed 's|^refs/tags/||' | grep . | sort -rV | head -n "$RESOLVE_DEPTH")
  for cand in "${cands[@]}"; do
    [ "$cand" != "$tag" ] || continue
    spec_valid "ours:$cand" || { say "  note: tag '$cand' is not a suite-tag shape — skipped" >&2; continue; }
    if set_complete "$cand"; then
      printf 'ours:%s\n' "$cand"
      return 0
    fi
    say "  note: tag '$cand' carries no complete set — skipped (partial publish? deleted images?)" >&2
  done
  if base_lock_spec; then
    say "  note: no complete set among the newest tags — falling back to $BASE_LOCK" >&2
    printf '%s\n' "$BASE_LOCK_SPEC"
    return 0
  fi
  die "cannot resolve a previous suite tag: no complete set among the newest tags, and $BASE_LOCK does not name one — for a wiped registry record the base in $BASE_LOCK (it ships ours:v0.4.0)"
}

resolve_spec() { # TAG FROM_TAG — the ONE source parser, two entry points (the CLI flag,
  #                 RETAG_SOURCE env — the workflow's knob). Sets RESOLVED_SPEC and returns 0
  #                 (the siblings_load idiom: side effect + status — a die inside a captured
  #                 stdout is neutered under set -uo pipefail, so this is NEVER captured).
  #                 Conflict-with-env, charset and self-source guards all die BEFORE any
  #                 registry call.
  local tag="$1" from_tag="$2" spec
  if [ -n "$from_tag" ] && [ -n "${RETAG_SOURCE:-}" ]; then
    die "CLI source flags and RETAG_SOURCE are both set — one source, one knob"
  fi
  if [ -n "$from_tag" ]; then
    tag_valid "$from_tag" \
      || die "from-tag '$from_tag' is not a channel-valid tag — the D12 rules apply to a source tag of ours too ('latest*' refused; ':' and '@' excluded by construction)"
    [ "$from_tag" != "$tag" ] || die "from-tag '$from_tag' is the tag being published — a set cannot be its own source"
    RESOLVED_SPEC="ours:$from_tag"
  else
    case "${RETAG_SOURCE:-}" in
      ""|ours)
        spec="$(resolve_ours "$tag")" || return 1   # guarded: a captured die must propagate
        RESOLVED_SPEC="$spec"
        ;;
      *)
        spec_valid "$RETAG_SOURCE" \
          || die "RETAG_SOURCE '$RETAG_SOURCE' is not a valid source spec (ours | ours:<tag>)"
        case "$RETAG_SOURCE" in
          ours:*) [ "${RETAG_SOURCE#ours:}" != "$tag" ] \
                    || die "RETAG_SOURCE '$RETAG_SOURCE' names the tag being published — a set cannot be its own source" ;;
        esac
        RESOLVED_SPEC="$RETAG_SOURCE"
        ;;
    esac
  fi
  return 0
}

cmd_list() { list || die "cannot list the siblings"; }

cmd_sed() { # FILE — apply the org swap in place and verify. THE GENERATOR patch 010 replays (S4's
  #           queue): never hand-edit containers.json — upstream's next container must auto-include,
  #           which only a generated rule gives. Idempotent by construction: a second run is a no-op,
  #          which is 010's own "already applied" outcome under the three-outcome rule.
  [ $# -ge 1 ] || { usage; die "sed needs FILE"; }
  local f="$1"
  [ -f "$f" ] || die "no such file: $f"
  sed -i "s|$GHCR/$ORG_UPSTREAM/|$GHCR/$ORG_FORK/|g" "$f"
  # The verify is the gate, not a courtesy: a bare-form upstream ref (no trailing slash) survives the
  # sed — die loudly so the GENERATOR gets fixed, never the file (the one-rule doctrine).
  if grep -q "$GHCR/$ORG_UPSTREAM" "$f"; then
    die "$f still names $GHCR/$ORG_UPSTREAM — the sed's prefix rule missed a ref shape; fix the generator, never the file"
  fi
  siblings_load
  local n
  n="$(grep -c "$GHCR/$ORG_FORK/" "$f")"
  [ "$n" -eq "${#SIBS[@]}" ] \
    || die "$f carries ${n} $ORG_FORK refs but containers.json names ${#SIBS[@]} images — the file and the list disagree"
  say "sed applied and verified: ${n} image refs now $GHCR/$ORG_FORK/; upstream refs: 0; %AIO_CHANNEL% untouched"
}

cmd_retag() { # TAG [--from-tag T] [--force] — the lockstep walk. The source is OURS, always
  #              (Stage 2): bare resolution finds the previous suite tag, --from-tag pins it.
  [ $# -ge 1 ] || { usage; die "retag needs TAG"; }
  local tag="$1"; shift
  local from_tag="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-tag) [ $# -ge 2 ] || die "--from-tag needs a value"; from_tag="$2"; shift 2 ;;
      --force)    force=1; shift ;;
      *)          die "unknown argument to retag: $1" ;;
    esac
  done
  tag_valid "$tag" \
    || die "suite tag '$tag' is not a channel-valid tag — charset [A-Za-z0-9._-] (':' and '@' excluded BY construction: the wizard resolves the channel by exploding the running image on ':', and a digest-style ref parses as a bogus channel); 'latest*' names are reserved because the suite tag IS the release tag (D12)"
  siblings_load
  resolve_spec "$tag" "$from_tag" || exit 1   # side effect: RESOLVED_SPEC (a die prints its own FATAL)
  local spec="$RESOLVED_SPEC"
  say "resolved retag source: $spec"
  echo "RETAG_SOURCE_RESOLVED=$spec"   # machine-readable — the workflow threads this one resolution (D-5)
  local src_ours="${spec#ours:}"
  local total=$(( ${#SIBS[@]} + 1 ))
  # Immutability pre-check, the published-tag rule made mechanical: a FULLY present set means a prior
  # run announced this tag, and a published tag's digests never move. A PARTIAL set is a failed or
  # interrupted run — completing it is what a retry is for (the matrix below is the arbiter of whether
  # the completed set is coherent). --force is the deliberate re-publish: repairing a set that failed
  # verification, or refreshing a throwaway CI tag. Never a green, published release tag.
  local existing=0 img
  for img in "${SIBS[@]}" "$MASTER_IMAGE"; do
    if digest "$GHCR/$ORG_FORK/$img:$tag" >/dev/null 2>&1; then existing=$((existing+1)); fi
  done
  if [ "$existing" -eq "$total" ] && [ "$force" = 0 ]; then
    die "tag '${tag}' is already fully published (${existing}/${total}) — a published tag's digests never move. If the previous run FAILED verification (a mixed set), or this is a throwaway CI tag, re-run with --force to rebuild the set from one snapshot."
  fi
  [ "$existing" = 0 ] || say "note: ${existing}/${total} images already carry '${tag}' — completing the set"
  local n=0
  for img in "${SIBS[@]}"; do
    if is_built "$img"; then
      say "  skip $img — built by the workflow's build jobs, never retagged"
      continue
    fi
    retag_one "$GHCR/$ORG_FORK/$img:$tag" "$GHCR/$ORG_FORK/$img:$src_ours" \
      || die "retag failed: $GHCR/$ORG_FORK/$img:$src_ours -> $GHCR/$ORG_FORK/$img:$tag"
    say "  retagged $img"
    n=$((n+1))
  done
  say "retag walk done: ${n} images now carry :${tag} (copied from our :${src_ours}; built separately: ${BUILD_IMAGES[*]}, $MASTER_IMAGE)"
}

cmd_matrix() { # TAG [--from-tag T] — THE GATE. Existence is only half of it; the other half
  #              keys to the RESOLVED SOURCE (D-4): under ours:<tag> the previous set is
  #              IMMUTABLE, so every retagged image must equal our :<tag> NOW — a mismatch
  #              means the walk did not copy faithfully, and "mixed" turns from a snapshot
  #              race into an integrity proof. Built images and the mastercontainer are
  #              exempt — they are rebuilt per run, never copied.
  [ $# -ge 1 ] || { usage; die "matrix needs TAG"; }
  local tag="$1"; shift
  local from_tag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-tag) [ $# -ge 2 ] || die "--from-tag needs a value"; from_tag="$2"; shift 2 ;;
      *)          die "unknown argument to matrix: $1" ;;
    esac
  done
  tag_valid "$tag" || die "suite tag '$tag' is not a channel-valid tag (see retag's message)"
  siblings_load
  resolve_spec "$tag" "$from_tag" || exit 1   # the workflow passes the RETAG job's one resolution via RETAG_SOURCE (D-5); a bare 'ours' resolves here
  local spec="$RESOLVED_SPEC" src_org src_tag
  say "matrix keyed to source: $spec"
  echo "RETAG_SOURCE_RESOLVED=$spec"
  src_org="$GHCR/$ORG_FORK"; src_tag="${spec#ours:}"
  local total=$(( ${#SIBS[@]} + 1 ))
  local missing=0 mixed=0 unprovable=0 present=0 img d u
  echo "== matrix: ${total} images must resolve under $GHCR/$ORG_FORK/:${tag} =="
  for img in "${SIBS[@]}" "$MASTER_IMAGE"; do
    if ! d="$(digest "$GHCR/$ORG_FORK/$img:$tag")"; then
      printf '  %-26s MISSING\n' "$img"
      missing=$((missing+1))
      continue
    fi
    present=$((present+1))
    printf '  %-26s %s\n' "$img" "$d"
    if is_built "$img" || [ "$img" = "$MASTER_IMAGE" ]; then continue; fi  # rebuilt per run, never copied
    if ! u="$(digest "$src_org/$img:$src_tag")"; then
      printf '  %-26s cannot prove the copy: %s:%s unresolvable\n' "$img" "$src_org/$img" "$src_tag"
      unprovable=$((unprovable+1))
      continue
    fi
    if [ "$d" != "$u" ]; then
      printf '  %-26s MIXED: %s != our :%s (%s) — the copy is not faithful\n' "$img" "$d" "$src_tag" "$u"
      mixed=$((mixed+1))
    fi
  done
  echo
  if [ "$missing" -gt 0 ] || [ "$mixed" -gt 0 ] || [ "$unprovable" -gt 0 ]; then
    echo "MATRIX: *** FAIL *** — of ${total}: ${missing} missing, ${mixed} mixed, ${unprovable} unprovable" >&2
    echo "  missing     = the wizard's start would fail on this tag (registry-reachability checks)" >&2
    echo "  mixed       = the tag does not faithfully mirror our :${src_tag} — the source set is immutable, so the walk itself erred; re-run the walk with --force to re-copy it" >&2
    echo "  unprovable  = our :${src_tag} could not be read; a matrix that cannot look is not a matrix" >&2
    exit 1
  fi
  local retagged=$(( ${#SIBS[@]} - ${#BUILD_IMAGES[@]} ))
  echo "MATRIX: PASS — ${present}/${total} images present; the ${retagged} retagged faithfully mirror our :${src_tag} (the immutable previous set); built: ${BUILD_IMAGES[*]} + $MASTER_IMAGE from build-ref"
  exit 0
}

cmd_manifest() { # TAG — the publish record: every image's index digest, JSON on stdout. The registry
  #                is the hand-off; this record is the LEDGER of what the walk produced — and its
  #                retag_source field names what the walk actually copied FROM: the RESOLVED spec
  #                (ours:<tag>, D-3), threaded from the retag job's one
  #                resolution (D-5). The old upstream_channel name is retired with this change:
  #                under ours:<tag> there is no honest value for a field named upstream_channel —
  #                the lineage's original channel is untraceable once the chain is self-referential.
  [ $# -ge 1 ] || { usage; die "manifest needs TAG"; }
  local tag="$1"
  tag_valid "$tag" || die "suite tag '$tag' is not a channel-valid tag (see retag's message)"
  siblings_load
  resolve_spec "$tag" "" || exit 1   # env-only entry point: the workflow passes the resolved spec; a local bare 'ours' resolves here
  RETAG_MANIFEST_TAG="$tag" \
  RETAG_MANIFEST_SOURCE="$RESOLVED_SPEC" \
  RETAG_MANIFEST_PREFIX="$GHCR/$ORG_FORK" \
  RETAG_MANIFEST_IMAGES="$(printf '%s\n' "${SIBS[@]}" "$MASTER_IMAGE")" \
  RETAG_MANIFEST_REF="${RETAG_BUILT_REF:-}" \
  RETAG_MANIFEST_SHA="${RETAG_BUILT_SHA:-}" \
  python3 - <<'PY'
import json, os, subprocess, sys

def digest(ref):
    # THE INDEX DIGEST — `imagetools inspect --format {{.Manifest.Digest}}`. Bounded (B-015); unreachable is FATAL, never silently omitted:
    # a record that cannot name a digest is a record of nothing.
    out = subprocess.run(["docker", "buildx", "imagetools", "inspect", "--format",
                           "{{.Manifest.Digest}}", ref], capture_output=True, text=True, timeout=120)
    if out.returncode == 0 and out.stdout.strip().startswith("sha256:"):
        return out.stdout.strip()
    sys.exit(f"FATAL: {ref} did not resolve — the manifest cannot record what the registry cannot see: {out.stderr.strip()}")

env = os.environ
manifest = {
    "suite_tag": env["RETAG_MANIFEST_TAG"],
    "retag_source": env["RETAG_MANIFEST_SOURCE"],
    "images": {},
}
for name in env["RETAG_MANIFEST_IMAGES"].splitlines():
    if name:
        manifest["images"][name] = digest(f'{env["RETAG_MANIFEST_PREFIX"]}/{name}:{env["RETAG_MANIFEST_TAG"]}')
if env.get("RETAG_MANIFEST_REF") and env.get("RETAG_MANIFEST_SHA"):
    manifest["built_from"] = {"ref": env["RETAG_MANIFEST_REF"], "sha": env["RETAG_MANIFEST_SHA"]}
json.dump(manifest, sys.stdout, indent=2, sort_keys=True)
print()
PY
}

selftest() { # the hermetic self-test — the repo's own self-test idiom: a PATH-shim
  #             docker keyed on argv shapes over a fixture registry, env-knob levers, an
  #             aggregating check(), flip-then-revert, and the verdict as the last stdout
  #             line. The catalogue is a REAL local git repo per discovery scenario (ls-remote
  #             over a local path is hermetic — no network — and exercises the REAL output
  #             format, peeled ^{} lines included); every arm runs this script itself as a
  #             subprocess, so each FATAL/exit is caught, not the self-test. Sleep budget: a
  #             failing digest() probe pays digest()'s own one-3s-retry; the arms arrange ~7
  #             failing probes (~21 s) and deliberately never walk a fresh tag's 20-probe
  #             pre-check over an empty set — that path is the ci.6 rehearsal's, not a
  #             self-test's.
  local n=0 FAILED=0 tmp tshim FIX REG CALLS SELF OPATH out rc dg=0
  OPATH="$PATH"
  tmp="$(mktemp -d)"; tshim="$tmp/bin"; FIX="$tmp/fix"
  mkdir -p "$tshim" "$FIX"
  SELF="$REPO_ROOT/scripts/retag.sh"
  REG="$FIX/reg"; CALLS="$FIX/calls"
  mkdir -p "$REG"

  check() { local name="$1" cond="$2"; n=$((n + 1))
    if eval "$cond"; then :; else echo "  FAIL: $name" >&2; FAILED=$((FAILED + 1)); fi; }

  local FORK="$GHCR/$ORG_FORK"

  # the fixture world: 15 retaggable siblings + the 4 built ones = MIN_SIBLINGS (the master
  # container is not in containers.json, as in the real one); the registry is a fixture tree
  # where $REG/<full-ref> holds the digest line; auto-digests are distinct per seeding.
  python3 - "$FIX/containers.json" <<'PY'
import json, sys
sibs = [f"ghcr.io/nextcloud-releases/nextcloud-aio-sib{i:02d}" for i in range(1, 16)]
sibs += ["ghcr.io/nextcloud-releases/aio-nextcloud", "ghcr.io/nextcloud-releases/aio-apache",
         "ghcr.io/nextcloud-releases/aio-postgresql", "ghcr.io/nextcloud-releases/aio-eurooffice"]
json.dump({"aio_services_v1": [{"image": s} for s in sibs]}, open(sys.argv[1], "w"), indent=1)
PY
  seed() { # REF [DIGEST] — plant the fixture registry (auto: distinct per seeding)
    mkdir -p "$(dirname "$REG/$1")"
    if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$REG/$1"
    else dg=$((dg+1)); printf 'sha256:%064d\n' "$dg" > "$REG/$1"; fi
  }
  local i
  for i in $(seq -w 1 15); do
    seed "$FORK/nextcloud-aio-sib$i:v0.4.0"
    seed "$FORK/nextcloud-aio-sib$i:v0.5.0"   # DISTINCT digests: presence is all the
  done                                          # immutability arm needs; the forced walk re-copies
  seed "$FORK/all-in-one:v0.4.0";      seed "$FORK/all-in-one:v0.5.0"
  seed "$FORK/aio-nextcloud:v0.4.0";   seed "$FORK/aio-nextcloud:v0.5.0"
  seed "$FORK/aio-apache:v0.4.0";      seed "$FORK/aio-apache:v0.5.0"
  seed "$FORK/aio-postgresql:v0.4.0";  seed "$FORK/aio-postgresql:v0.5.0"
  seed "$FORK/aio-eurooffice:v0.4.0";  seed "$FORK/aio-eurooffice:v0.5.0"

  # the docker shim — the #143 behavioral pattern: argv-shape keyed. inspect answers from the
  # fixture registry in BOTH argument orders the family uses (retag.sh's `inspect REF --format
  # F`, the manifest python's `inspect --format F REF`); create is what imagetools create IS —
  # the new tag carries the source's manifest digest — so the shim copies source→target and
  # appends the call to the log. Never-green: an unknown ref fails the way a registry would,
  # and any argv shape this shim does not know fails loudly (70).
  cat > "$tshim/docker" <<'DSHIM'
#!/usr/bin/env bash
REG="${RETAG_ST_REG:?docker shim: fixture registry unset}"
CALLS="${RETAG_ST_CALLS:?docker shim: calls log unset}"
[ "$1" = buildx ] && [ "$2" = imagetools ] || { echo "docker shim: unexpected argv: $*" >&2; exit 70; }
case "$3" in
  inspect)
    shift 3; ref=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --format) shift 2 ;;
        -*) shift ;;
        *) ref="$1"; break ;;
      esac
    done
    if [ -n "$ref" ] && [ -f "$REG/$ref" ]; then cat "$REG/$ref"; exit 0; fi
    echo "docker shim: ${ref:-<no ref>} does not resolve in the fixture registry" >&2
    exit 1 ;;
  create)
    shift 3; tgt=""; src=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) tgt="$2"; shift 2 ;;
        *) src="$1"; shift ;;
      esac
    done
    [ -n "$tgt" ] && [ -n "$src" ] || { echo "docker shim: create argv unparsable: $*" >&2; exit 70; }
    printf 'create %s <- %s\n' "$tgt" "$src" >> "$CALLS"
    [ -f "$REG/$src" ] || { echo "docker shim: source $src does not resolve" >&2; exit 1; }
    mkdir -p "$(dirname "$REG/$tgt")"
    cp "$REG/$src" "$REG/$tgt"
    exit 0 ;;
  *) echo "docker shim: unexpected argv: $*" >&2; exit 70 ;;
esac
DSHIM
  chmod +x "$tshim/docker"

  # the discovery catalogues: real local repos, no network. repoA's newest two tags carry no
  # set (the skip arms) and v0.4.0 is complete AND annotated — ls-remote then emits the peeled
  # ^{} line, which resolve_ours must filter or the candidate would not validate. The -c
  # identity pair rides every object-creating git call: the CI runner configures none.
  mkrepo() { # DIR [TAG...] — a scratch local repo (one empty commit, then the tags)
    git init -q "$1"
    git -C "$1" -c user.email=self-test@aps -c user.name=self-test commit -q --allow-empty -m fixture
    local t
    for t in "${@:2}"; do git -C "$1" tag "$t"; done
  }
  mkrepo "$FIX/repoA" v0.9.9 v0.8.8 v0.4.0
  git -C "$FIX/repoA" tag -d v0.4.0 >/dev/null \
    && git -C "$FIX/repoA" -c user.email=self-test@aps -c user.name=self-test tag -a v0.4.0 -m annotated
  mkrepo "$FIX/repoEmpty"                     # no tags at all: discovery's empty catalogue
  mkrepo "$FIX/repoSelf" v0.5.0 v0.4.0        # the publishing tag itself sits newest

  printf '# the fixture bootstrap record\nours:v0.4.0\n' > "$FIX/BASE.lock"

  export RETAG_CONTAINERS="$FIX/containers.json"
  export RETAG_ST_REG="$REG" RETAG_ST_CALLS="$CALLS"
  export RETAG_REMOTE="$FIX/repoA" RETAG_BASE_LOCK="$FIX/BASE.lock"
  export PATH="$tshim:$OPATH"

  # ── the validation arms — every die lands before any registry call, so no sleeps ──
  out="$(bash "$SELF" retag v0.9.0 --channel latest 2>&1)"; rc=$?
  check "retag: the retired --channel flag is refused" \
    '[ "$rc" -ne 0 ] && case "$out" in *"unknown argument to retag: --channel"*) ;; *) false ;; esac'
  out="$(bash "$SELF" retag v0.9.0 --from-tag v0.9.0 2>&1)"; rc=$?
  check "retag: a from-tag equal to the published tag is refused" \
    '[ "$rc" -ne 0 ] && case "$out" in *"its own source"*) ;; *) false ;; esac'
  out="$(bash "$SELF" retag v0.9.0 --from-tag latest 2>&1)"; rc=$?
  check "retag: a latest from-tag is refused — D12 reaches source tags too" \
    '[ "$rc" -ne 0 ] && case "$out" in *"channel-valid tag"*) ;; *) false ;; esac'
  out="$(RETAG_SOURCE=ours:v0.4.0 bash "$SELF" retag v0.9.0 --from-tag v0.3.9 2>&1)"; rc=$?
  check "retag: CLI source flags and RETAG_SOURCE together are refused" \
    '[ "$rc" -ne 0 ] && case "$out" in *"one knob"*) ;; *) false ;; esac'
  out="$(RETAG_SOURCE=bogus:x bash "$SELF" retag v0.9.0 2>&1)"; rc=$?
  check "retag: an invalid RETAG_SOURCE spec is refused naming the valid forms" \
    '[ "$rc" -ne 0 ] && case "$out" in *"not a valid source spec"*) ;; *) false ;; esac'
  out="$(RETAG_SOURCE=ours:v0.9.0 bash "$SELF" retag v0.9.0 2>&1)"; rc=$?
  check "retag: RETAG_SOURCE naming the published tag is refused" \
    '[ "$rc" -ne 0 ] && case "$out" in *"its own source"*) ;; *) false ;; esac'
  out="$(RETAG_SOURCE=bogus:x bash "$SELF" manifest v0.9.0 2>&1)"; rc=$?
  check "manifest: an invalid spec is refused before any registry call" \
    '[ "$rc" -ne 0 ] && case "$out" in *"not a valid source spec"*) ;; *) false ;; esac'
  out="$(bash "$SELF" retag latest 2>&1)"; rc=$?
  check "retag: a latest suite tag is refused" '[ "$rc" -ne 0 ]'

  # ── the lock ladder: discovery → BASE.lock → FATAL. An empty catalogue costs no probes. ──
  printf 'ours:v0.1.0\nours:v0.2.0\n' > "$FIX/bad.lock"
  out="$(RETAG_REMOTE="$FIX/repoEmpty" RETAG_BASE_LOCK="$FIX/bad.lock" bash "$SELF" retag v0.5.0 2>&1)"; rc=$?
  check "lock: a multi-spec lock dies — a stale first line must not win silently" \
    '[ "$rc" -ne 0 ] && case "$out" in *"exactly one"*) ;; *) false ;; esac'
  printf 'bogus:x\n' > "$FIX/bad.lock"
  out="$(RETAG_REMOTE="$FIX/repoEmpty" RETAG_BASE_LOCK="$FIX/bad.lock" bash "$SELF" retag v0.5.0 2>&1)"; rc=$?
  check "lock: a lock naming an invalid spec dies" \
    '[ "$rc" -ne 0 ] && case "$out" in *"not a valid source spec"*) ;; *) false ;; esac'
  out="$(RETAG_REMOTE="$FIX/repoEmpty" RETAG_BASE_LOCK="$FIX/absent.lock" bash "$SELF" retag v0.5.0 2>&1)"; rc=$?
  check "resolution: no complete set and no lock — FATAL names the remedy" \
    '[ "$rc" -ne 0 ] && case "$out" in *"record the base"*) ;; *) false ;; esac'
  out="$(RETAG_REMOTE="$FIX/no-such-repo" bash "$SELF" retag v0.5.0 2>&1)"; rc=$?
  check "resolution: a failed fetch is not an empty catalogue" \
    '[ "$rc" -ne 0 ] && case "$out" in *"not an empty catalogue"*) ;; *) false ;; esac'

  # ── the bootstrap fallback + the immutability pre-check (one invocation, two proofs) ──
  out="$(RETAG_REMOTE="$FIX/repoEmpty" bash "$SELF" retag v0.5.0 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$tmp/boot.txt"
  check "lock: the fallback is said and the bootstrap spec recorded" \
    'grep -q "falling back to" "$tmp/boot.txt" && grep -qx "RETAG_SOURCE_RESOLVED=ours:v0.4.0" "$tmp/boot.txt"'
  check "retag: a fully-present set without --force dies at the immutability pre-check" \
    '[ "$rc" -ne 0 ] && case "$out" in *"already fully published"*) ;; *) false ;; esac'

  # ── the depth cap and the self-exclusion ──
  out="$(RETAG_RESOLVE_DEPTH=1 bash "$SELF" retag v0.5.0 2>&1)"; rc=$?
  check "resolution: the depth cap is honoured — the one newest candidate, then the lock" \
    '[ "$rc" -ne 0 ] && case "$out" in *"no complete set among the newest tags"*"RETAG_SOURCE_RESOLVED=ours:v0.4.0"*) ;; *) false ;; esac'
  out="$(RETAG_REMOTE="$FIX/repoSelf" bash "$SELF" retag v0.5.0 2>&1)"; rc=$?
  check "resolution: the publishing tag is skipped — a set cannot bootstrap itself" \
    'case "$out" in *"RETAG_SOURCE_RESOLVED=ours:v0.4.0"*) ;; *) false ;; esac'

  # ── the lockstep walk: resolve ours, force over the present set, copy faithfully ──
  : > "$CALLS"
  out="$(bash "$SELF" retag v0.5.0 --force 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$tmp/walk.txt"
  check "walk: the forced re-publish resolves ours and walks green" '[ "$rc" -eq 0 ]'
  check "walk: the one resolution is announced, column-0 machine-readable" \
    'grep -qx "RETAG_SOURCE_RESOLVED=ours:v0.4.0" "$tmp/walk.txt"'
  check "resolution: incomplete candidates are said and skipped" \
    'grep -q "v0.9.9.*carries no complete set" "$tmp/walk.txt" && grep -q "v0.8.8.*carries no complete set" "$tmp/walk.txt"'
  check "walk: 15 copies, every source OUR previous set — upstream is never read" \
    '[ "$(grep -c "^create " "$CALLS")" -eq 15 ] \
     && [ "$(grep -c " <- $FORK/nextcloud-aio-sib..:v0.4.0$" "$CALLS")" -eq 15 ] \
     && ! grep -q "nextcloud-releases" "$CALLS"'
  check "walk: the built images and the mastercontainer are never copied, their skip said" \
    '! grep -qE " <- .*(aio-nextcloud|aio-apache|aio-postgresql|aio-eurooffice|all-in-one):" "$CALLS" \
     && grep -q "skip aio-nextcloud" "$tmp/walk.txt" && grep -q "skip aio-apache" "$tmp/walk.txt" \
     && grep -q "skip aio-postgresql" "$tmp/walk.txt" && grep -q "skip aio-eurooffice" "$tmp/walk.txt"'

  # ── the matrix: both arms, and every red class ──
  out="$(bash "$SELF" matrix v0.5.0 2>&1)"; rc=$?
  check "matrix: a bare ours resolves locally and passes keyed to it" \
    '[ "$rc" -eq 0 ] && case "$out" in *"matrix keyed to source: ours:v0.4.0"*"MATRIX: PASS"*) ;; *) false ;; esac'
  out="$(RETAG_SOURCE=ours:v0.4.0 bash "$SELF" matrix v0.5.0 2>&1)"; rc=$?
  check "matrix: the threaded spec needs no second resolution" \
    '[ "$rc" -eq 0 ] && case "$out" in *"carries no complete set"*) false ;; *"RETAG_SOURCE_RESOLVED=ours:v0.4.0"*) ;; *) false ;; esac'
  seed "$FORK/nextcloud-aio-sib01:v0.5.0" "sha256:$(printf '%064d' 999)"
  out="$(RETAG_SOURCE=ours:v0.4.0 bash "$SELF" matrix v0.5.0 2>&1)"; rc=$?
  check "matrix: ours-arm MIXED is an integrity failure — the copy was not faithful" \
    '[ "$rc" -ne 0 ] && case "$out" in *"the copy is not faithful"*) ;; *) false ;; esac'
  cp "$REG/$FORK/nextcloud-aio-sib01:v0.4.0" "$REG/$FORK/nextcloud-aio-sib01:v0.5.0"
  mv "$REG/$FORK/all-in-one:v0.5.0" "$FIX/kept"
  out="$(RETAG_SOURCE=ours:v0.4.0 bash "$SELF" matrix v0.5.0 2>&1)"; rc=$?
  check "matrix: a missing image reds the gate" \
    '[ "$rc" -ne 0 ] && case "$out" in *"1 missing"*) ;; *) false ;; esac'
  mv "$FIX/kept" "$REG/$FORK/all-in-one:v0.5.0"
  mv "$REG/$FORK/nextcloud-aio-sib02:v0.4.0" "$FIX/kept"
  out="$(RETAG_SOURCE=ours:v0.4.0 bash "$SELF" matrix v0.5.0 2>&1)"; rc=$?
  check "matrix: an unreadable source is unprovable, and that reds" \
    '[ "$rc" -ne 0 ] && case "$out" in *"unprovable"*) ;; *) false ;; esac'
  mv "$FIX/kept" "$REG/$FORK/nextcloud-aio-sib02:v0.4.0"

  # ── the ledger ──
  out="$(RETAG_SOURCE=ours:v0.4.0 RETAG_BUILT_REF=v0.5.0 RETAG_BUILT_SHA=deadbeefcafe bash "$SELF" manifest v0.5.0 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$tmp/manifest.json"
  check "manifest: green, naming the resolved spec" \
    '[ "$rc" -eq 0 ] && grep -q "\"retag_source\": \"ours:v0.4.0\"" "$tmp/manifest.json"'
  check "manifest: 20 image digests and built_from recorded" \
    '[ "$(grep -c "\"sha256:" "$tmp/manifest.json")" -eq 20 ] && grep -q "\"built_from\"" "$tmp/manifest.json"'
  check "manifest: the retired upstream_channel name is gone" \
    '! grep -q upstream_channel "$tmp/manifest.json"'

  rm -rf "$tmp"
  echo "self-test: $n checks OK"
  [ "$FAILED" -eq 0 ] || { echo "self-test: $FAILED FAILED" >&2; exit 1; }
  return 0
}

case "${1:-}" in
  list)     shift; cmd_list "$@" ;;
  sed)      shift; cmd_sed "$@" ;;
  retag)    shift; cmd_retag "$@" ;;
  matrix)   shift; cmd_matrix "$@" ;;
  manifest) shift; cmd_manifest "$@" ;;
  --self-test) selftest ;;
  *)        usage; exit 1 ;;
esac
