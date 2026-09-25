#!/usr/bin/env bash
# The org boilerplate drift gate (org L0-09, AIO-parity style): per-repo files stay
# per-repo (GitHub requires it, the tarball doctrine requires it), and this gate is
# the machine that notices when the copies stop agreeing.
#
# WHAT IT COMPARES (territorio ↔ farmacia, the two apps the doctrine matured on;
# epidemiologia joins per-check when its Phase-7 tree lands — every exclusion here
# names its reason, the AIO allowlist doctrine):
#   phpunit.xml / phpunit.integration.xml  exact bytes — the suites' shape is shared
#   Makefile                                the core target set is present in each
#   eslint.config.mjs                       the doctrine pins (no-undef error, vue
#                                           plugin) — the configs' prose is per-app,
#                                           whole-file equality is not the contract
#   src/aps + vendor/aps/common/src         aps-sync parity: both apps' committed
#                                           subtrees equal each other AND the
#                                           aps-common checkout (needs the org
#                                           sibling, or APS_ROOT set)
#
# WHAT IT DELIBERATELY DOES NOT COMPARE: .github canon files (canon-drift in
# repo-docs owns them), ci.yml (per-app by design), openapi.sh / smoke.sh (the
# per-app halves of a shared shape — normalized compare joins when Phase 3's
# territorio script exists in the implemented tree; recorded here so the gate's
# scope is explicit).
#
# Usage: scripts/check-org-drift.sh APPS_ROOT    (APPS_ROOT = the dir holding
# territorio/ and farmacia/ — gestion's CI passes apps/; APS_ROOT names the
# aps-common checkout when it is not the org-root sibling)
set -uo pipefail

APPS="${1:?usage: scripts/check-org-drift.sh APPS_ROOT (the dir holding territorio/ farmacia/)}"
T="$APPS/territorio"; F="$APPS/farmacia"
# org layout: APPS_ROOT is gestion/apps, aps-common is the org root's sibling of gestion
APS="${APS_ROOT:-"$(cd "$APPS/../.." && pwd)/aps-common"}"
fails=0
bad() { printf 'DRIFT: %s\n' "$*" >&2; fails=$((fails + 1)); }

[ -d "$T" ] || { echo "FATAL: no territorio at $T" >&2; exit 2; }
[ -d "$F" ] || { echo "FATAL: no farmacia at $F" >&2; exit 2; }

# — exact: the phpunit shapes (farmacia's three cosmetic deltas — cacheDirectory,
# testsuite name case, trailing newline — and its missing doctrine comment were
# normalized by the phase that added this gate; anything beyond them is new drift)
for f in phpunit.xml phpunit.integration.xml; do
  if [ -e "$T/$f" ] && [ -e "$F/$f" ]; then
    cmp -s "$T/$f" "$F/$f" || bad "$f: territorio and farmacia differ — $(diff "$T/$f" "$F/$f" | wc -l) diff line(s); the suites' shape is shared, reconcile the copies"
  elif [ -e "$T/$f" ] || [ -e "$F/$f" ]; then
    bad "$f: exists in one app only — the shape is shared or absent, never half"
  fi
done

# — presence: the core Makefile targets every own app carries (the per-app
# extras — smoke, openapi, test-js… — are the app's own and never compared)
for app in "$T" "$F"; do
  name="$(basename "$app")"
  for target in test clean instance-up instance-occ instance-down instance-clean aps-sync aps-drift; do
    grep -qE "(^|[[:space:]])$target([[:space:]]|:|\$)" "$app/Makefile" \
      || bad "$name/Makefile lost the core target '$target' — the apps share the gate vocabulary"
  done
done

# — doctrine pins: both eslint configs keep their teeth (whole-file equality is
# not the contract — the prose and the browser-globals block are per-app)
for app in "$T" "$F"; do
  name="$(basename "$app")"
  grep -q "'no-undef': *'error'" "$app/eslint.config.mjs" \
    || bad "$name/eslint.config.mjs no longer pins 'no-undef': 'error' — the one rule with teeth"
  grep -q "eslint-plugin-vue" "$app/eslint.config.mjs" \
    || bad "$name/eslint.config.mjs dropped eslint-plugin-vue — .vue files lint as plain js"
done

# — aps-sync parity: the committed subtrees equal each other and the package.
# Digest of a git tree at a path: stable across clones and immune to mtimes. The
# package side drops `*.test.js` — aps-sync strips them (the apps' bare vitest
# picks up default includes; the package's own tests never ship). Blob+basename:
# the prefixes legitimately differ (apps: src/aps/, vendor/aps/common/src/;
# package: js/, src/).
tree_digest() {  # REPO PATH [EXCLUDE-TESTS]
  local out
  if [ "${3:-}" = "notests" ]; then
    out="$(git -C "$1" ls-tree -r HEAD -- "$2" | grep -v '\.test\.js$')"
  else
    out="$(git -C "$1" ls-tree -r HEAD -- "$2")"
  fi
  printf '%s\n' "$out" | awk '{n=$NF; sub(/.*\//, "", n); print $3, n}' | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}
if [ -d "$APS/src" ]; then
  t_aps="$(tree_digest "$T" src/aps)"; f_aps="$(tree_digest "$F" src/aps)"
  t_vendor="$(tree_digest "$T" vendor/aps/common/src)"; f_vendor="$(tree_digest "$F" vendor/aps/common/src)"
  want_js="$(tree_digest "$APS" js notests)"
  want_php="$(tree_digest "$APS" src)"
  [ "$t_aps" = "$f_aps" ] || bad "src/aps subtrees differ between territorio and farmacia — run make aps-sync in both"
  [ "$t_vendor" = "$f_vendor" ] || bad "vendor/aps/common/src subtrees differ — run make aps-sync in both"
  [ "$t_aps" = "$want_js" ] || bad "territorio/src/aps is not aps-common's js/ — run make aps-sync and commit"
  [ "$t_vendor" = "$want_php" ] || bad "apps' vendor/aps/common/src is not aps-common's src/ — run make aps-sync and commit"
else
  echo "  (aps-sync parity: no aps-common at $APS — skipped, name the checkout with APS_ROOT=)" >&2
fi

if [ "$fails" -gt 0 ]; then
  echo "ORG DRIFT: *** FAIL *** — $fails finding(s)" >&2
  exit 1
fi
echo "ORG DRIFT: PASS — the shared shapes agree (phpunit exact, core targets, eslint teeth, aps-sync parity)"
