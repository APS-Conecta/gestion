#!/usr/bin/env bash
# gestion/tests/desktop_workspace/run.sh — the desktop_workspace pin seat (L4-03, D2).
#
# The app is vendored upstream with zero tests of its own; its pins live HERE, running
# against the unpacked PATCHED tree: the committed tarball + the ADR-0002 patches from
# provisioning/apps/desktop_workspace/, exactly as 12-apps.sh would install them.
#
# Hermetic: needs only bash, tar, patch, node and (for the PHP pins) php — no stack.
# Exits non-zero on any failure; prints one ok-line per green arm.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APPDIR="$REPO/provisioning/apps/desktop_workspace"
TARBALL=("$APPDIR"/desktop_workspace-*.tar.gz)

fail=0
note() { echo "  $1"; }
die()  { echo "FAIL: $1" >&2; exit 1; }

command -v node  >/dev/null 2>&1 || die "node is required for the desktop_workspace seat"
command -v patch >/dev/null 2>&1 || die "patch is required for the desktop_workspace seat"
[ -e "${TARBALL[0]}" ] || die "no vendored tarball under $APPDIR"

# Unpack + patch into a scratch tree (the three-outcome contract collapses here: the
# seat requires the FORWARD outcome — a patch that only applies reversed, or not at
# all, means the tree and the patches disagree and the seat must be red).
TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
tar xzf "${TARBALL[0]}" -C "$TREE" || die "cannot unpack the vendored tarball"
shopt -s nullglob
PATCHES=("$APPDIR"/*.patch)
[ ${#PATCHES[@]} -gt 0 ] || note "note: no patches under $APPDIR yet — pins run against the pristine tree"
for p in "${PATCHES[@]}"; do
  patch -d "$TREE/desktop_workspace" -p1 --silent < "$p" \
    || die "$(basename "$p") does not apply — the tarball and the patches disagree (regenerate the patch; ADR-0002)"
done

# 1. drag-rules pins (destructive-drag validators — the only guards before WebDAV MOVE/COPY)
if node "$HERE/drag-rules.test.cjs" "$TREE/desktop_workspace/js/desktop-drag-rules.js"; then
  note "ok:   drag-rules pins"
else
  echo "FAIL: drag-rules pins" >&2; fail=1
fi

# 2. shell round-trip (saveState → restoreWindows through the real split shell)
if node "$HERE/shell-roundtrip.test.cjs" "$TREE/desktop_workspace/js"; then
  note "ok:   shell round-trip"
else
  echo "FAIL: shell round-trip" >&2; fail=1
fi

# 3. PHP pins (PinService claim/validation, windowStates cap, controller posture, FolderPolicy)
if command -v php >/dev/null 2>&1; then
  if php "$HERE/settings-controller.test.php" "$TREE/desktop_workspace"; then
    note "ok:   settings-controller pins"
  else
    echo "FAIL: settings-controller pins" >&2; fail=1
  fi
else
  # Visible skip with teeth: CI installs php (ci.yml apt step), so a skip here means a
  # dev box without php — the drag/round-trip arms still ran.
  note "skipped: settings-controller pins (no php on this box — CI always runs them)"
fi

[ "$fail" -eq 0 ] || { echo "FAIL: desktop_workspace pin seat" >&2; exit 1; }
echo "PASS: desktop_workspace pin seat (patches: ${#PATCHES[@]})"
