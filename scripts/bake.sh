#!/usr/bin/env bash
# The bake's build-time half (FRD S3). Patch 030's runtime half is two COPY lines in the
# Dockerfile; this script is what produces the bytes they copy. It runs ON THE IMAGES RUNNER,
# never in the image.
#
# WHAT THIS IS. The suite's apps and the apsconecta theme arrive in the image instead of the
# app store: the store is baked off (020's ENV), a published tag's digests never move (D12), so
# nothing can fetch apps later — and a first boot must already carry every app the wizard
# starts containers for. notify_push first of all: the entrypoint installs it from the store
# on every start when it is absent (entrypoint.sh:726-733), and store-off makes that leg fail —
# the FRD's "store-off breaks first boot without it", asserted below as a hard gate, not a hope.
#
# THE CHANNEL (the acquisition gate's checksum story): the old gestion's provisioning/apps at the
# release content, cloned by the Images workflow between the merge and the tag push (until #42),
# and this script re-runs the vendored-app gates before a single byte enters the build context:
#   - the VENDOR sha256 gate (version, sha256, tarball count),
#   - the tarball's own info.xml version must equal the VENDOR pin (the seed's probe parser),
#   - the eurooffice white-label patches applied with the three-outcome rule (forward-dry-run /
#     reverse-dry-run / abort, via git apply — GNU patch fuzzes drifted
#     context, measured; a drifted patch fails the BUILD, never a clinic), then
#     signature.json dropped for patched apps (a patched app's vendor signature
#     no longer describes its files; Checker.php only checks apps that carry one),
#   - the white-label asserts the office smoke used to own (FRD S3: the smoke greps moved to
#     build time — under the suite nothing can revert the rename between builds, which is why
#     the runtime grep's threat model is empty and its retirement is slice 20's call).
#
# PARITY WITH THE SEED, deliberate and load-bearing: this mirrors lib.sh's
# ensure_vendored_app + apply_patch mechanics, because the seed's job at the clinic is to find
# every app already installed and write nothing (seed-idempotent's PASS) — and that only holds
# if the bytes baked here are the bytes the seed's VENDOR pins describe. Where the seed logs
# "already unpacked", the image must hold exactly that.
#
# WHY FORK-INFRA AND NOT A PATCH: files upstream does not ship live on the fork's main (the D6
# amendment; scripts/ is the mirror-parity allowlist). A patch would couple every bake tweak to
# a queue regeneration for zero benefit — and this file is upstream-shellcheck's territory
# anyway (the fork's CI runs it over **.sh on main).
#
# Usage: scripts/bake.sh GESTION_TREE OUT_DIR
#   GESTION_TREE — a checkout of the old gestion (provisioning/apps/ read-only)
#   OUT_DIR      — the docker build-context dir this creates (aps-bake/); refused if non-empty
# The theme is this checkout's own themes/apsconecta.
set -euo pipefail

die() { echo "FATAL: $*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

GESTION="${1:?usage: scripts/bake.sh GESTION_TREE OUT_DIR}"
OUT="${2:?usage: scripts/bake.sh GESTION_TREE OUT_DIR}"
THEME="$(cd "$(dirname "$0")/.." && pwd)/themes/apsconecta"

command -v sha256sum >/dev/null 2>&1 || die "sha256sum missing on this runner"
command -v git        >/dev/null 2>&1 || die "git missing on this runner (git apply carries the three-outcome rule: --check / --check --reverse — verified outside any repo, slice 4)"
command -v awk        >/dev/null 2>&1 || die "awk missing on this runner"

[ -d "$GESTION/provisioning/apps" ] || die "'$GESTION' does not look like gestion (no provisioning/apps/)"
[ -d "$THEME/core" ] || die "$THEME/core missing — the bake brands with this checkout's theme"
if [ -e "$OUT" ]; then
  [ -d "$OUT" ] || die "'$OUT' exists and is not a directory"
  [ -z "$(ls -A "$OUT")" ] || die "'$OUT' is not empty — refusing to overwrite (bake into a clean dir)"
fi
mkdir -p "$OUT/custom_apps" "$OUT/themes"

# The FRD's first-boot gate, mechanical: notify_push is the one app the entrypoint installs
# from the store on every start, so a release that drops its tarball ships a crash-looping
# first boot with every gate here green. If the release genuinely wants it gone, change the
# entrypoint leg too — never just the tarball list.
[ -d "$GESTION/provisioning/apps/notify_push" ] \
  || die "provisioning/apps/notify_push is absent — the entrypoint installs notify_push from the store on every start (entrypoint.sh:726-733) and the store is baked off: a first boot without it baked crash-loops"

apps=()
patched_total=0

for dir in "$GESTION"/provisioning/apps/*/; do
  app="$(basename "$dir")"
  apps+=("$app")

  # — the tarball guard (12-apps.sh's shape): exactly one tarball, VENDOR readable —
  local_tgz=("$dir"*.tar.gz)
  [ -f "${local_tgz[0]}" ] || die "$app: no vendored tarball in provisioning/apps/$app/"
  [ "${#local_tgz[@]}" -eq 1 ] || die "$app: ${#local_tgz[@]} tarballs in provisioning/apps/$app/, expected exactly 1"
  tgz="${local_tgz[0]}"
  [ -f "$dir/VENDOR" ] || die "$app: provisioning/apps/$app/VENDOR is missing"
  want="$(sed -n 's/^version=//p' "$dir/VENDOR")"
  sha="$(sed -n 's/^sha256=//p'  "$dir/VENDOR")"
  if [ -z "$want" ] || [ -z "$sha" ]; then die "$app: VENDOR is missing version= or sha256="; fi
  src="$(sed -n 's/^url=//p' "$dir/VENDOR")"

  # — the checksum gate: the tarball must hash to the VENDOR pin before anything unpacks it
  echo "$sha  $tgz" | sha256sum --check --status \
    || die "$app: tarball does not match sha256 in VENDOR — re-download it from url=$src"

  # — unpack into the context, then verify the tarball's own <version> equals the pin (the
  # seed's in-container probe reads this same file; a mismatch would make the seed re-impose
  # on every clinic for no reason — or worse, converge on bytes VENDOR does not describe)
  tar -xzf "$tgz" -C "$OUT/custom_apps"
  [ -d "$OUT/custom_apps/$app" ] || die "$app: the tarball did not unpack to a '$app/' top directory"
  got="$(awk -F'[<>]' '/<version>/ {print $3; exit}' "$OUT/custom_apps/$app/appinfo/info.xml")"
  [ "$got" = "$want" ] || die "$app: tarball carries version '$got' but VENDOR pins '$want' — fix the pin or the tarball"

  # — the patches beside the tarball, applied with the seed's own three-outcome rule — via
  # git apply, NOT patch: GNU patch fuzzes drifted context and applies anyway (measured in
  # this slice's own de-risk — a mutated context line landed "with fuzz 1"), which is the
  # silent-rot class the replay engine's doctrine exists to kill ("no fuzzy context, ever").
  # git apply --check / --check --reverse map 1:1 onto forward/reverse dry-run and work
  # outside any repository (slice 4's verification); a real drift aborts the BUILD here.
  patched=0
  for pfile in "$dir"*.patch; do
    [ -e "$pfile" ] || break
    if (cd "$OUT/custom_apps/$app" && git apply --check) < "$pfile" >/dev/null 2>&1; then
      (cd "$OUT/custom_apps/$app" && git apply) < "$pfile"
      say "patch applied: $app/$(basename "$pfile")"
    elif (cd "$OUT/custom_apps/$app" && git apply --check --reverse) < "$pfile" >/dev/null 2>&1; then
      say "patch already applied: $app/$(basename "$pfile")"
    else
      die "$app/$(basename "$pfile") no longer applies — the tarball and the patch stopped describing each other; regenerate the patch (upstream moved)"
    fi
    patched=1
  done

  # — the signature drop (12-apps.sh parity): a patched app's signature.json is a
  # vendor claim our edits make false; Checker.php verifies a non-shipped app only while it
  # carries one, so deleting it is the fix. Unpatched apps keep their check.
  if [ "$patched" = 1 ] && [ -e "$OUT/custom_apps/$app/appinfo/signature.json" ]; then
    rm "$OUT/custom_apps/$app/appinfo/signature.json"
    say "signature dropped for $app (patched, so it no longer describes the files)"
  fi
  patched_total=$((patched_total + patched))

  if [ "$patched" = 1 ]; then
    say "app $app $want baked (from $(basename "$tgz"), patched)"
  else
    say "app $app $want baked (from $(basename "$tgz"))"
  fi
done

# — the white-label asserts, moved here from office-smoke.sh:37 per FRD S3. Both halves, the
# same file:string pairs the runtime grep owned, so a patch regeneration that silently stopped
# renaming fails the build instead of shipping "Nextcloud Office" back into the admin UI.
# (org L7-3) The eurooffice floor is mandatory exactly like notify_push's: dropping the app would
# ship an office-less image with every gate green. The asserts run unconditionally, and a renamed
# file reds instead of skipping: each iteration proves the file exists before it proves the rename.
[ -d "$OUT/custom_apps/eurooffice" ] \
  || die "custom_apps/eurooffice is absent from the bake — the suite's office ships baked (the store is off, 020) and the white-label asserts below run on its served files; an office-less bake with every gate green is exactly the regression this floor exists to catch (org L7-3)"
while IFS= read -r f_want; do
  f="${f_want%%:*}"; wantstr="${f_want#*:}"
  [ -f "$OUT/custom_apps/eurooffice/$f" ] \
    || die "eurooffice/$f is missing from the bake — a renamed file must red, never skip (org L7-3); regenerate the white-label patch against the real tarball"
  grep -qF -- "$wantstr" "$OUT/custom_apps/eurooffice/$f" \
    || die "white-label rename missing from eurooffice/$f — the patch applied but the rename is not in the served file; regenerate the patch against the real tarball"
done <<'EOF'
lib/AdminSection.php:Euro-Office
appinfo/info.xml:<name>Euro-Office</name>
EOF
say "white-label asserts green (eurooffice: AdminSection.php + info.xml)"

# — the theme, whole-dir (probe parity: the slice-1 harness docker-cp'd exactly this tree and
# smoke's checks 7/11 passed against it; tools/ and MAPEO.md ride — inert, and a future theme
# file flows without this script learning about it)
cp -a "$THEME" "$OUT/themes/apsconecta"
theme_digest="$(cd "$OUT/themes/apsconecta" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

echo
say "gestion: $(git -C "$GESTION" rev-parse HEAD 2>/dev/null) — the vendored apps' source tree (the provenance record; a non-git tree cannot answer it)"
say "theme: $theme_digest (deterministic find|sort|sha256sum over themes/apsconecta)"
say "inventory: ${#apps[@]} app(s), $patched_total patched — ${apps[*]}"
echo "BAKE: PASS — ${#apps[@]} app(s) + the theme -> $OUT"
