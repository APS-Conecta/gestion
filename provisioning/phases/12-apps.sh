# Phase 12 — the apps this instance runs, and the edits we make inside them.  OWNER: ADR-0002.
# Runs before 15-branding and 30-folders, which use side_menu and groupfolders.
#
# APPS is the inventory; provisioning/apps/<appid>/ holds the vendored tarball, its VENDOR
# provenance file, and the *.patch edits applied in name order after unpacking. So this file says
# WHICH apps we run and that directory says which bytes and which edits.
#
# NOTHING HERE CONTACTS THE APP STORE (#98) — the reasoning lives on ensure_vendored_app in lib.sh.
# Cost recorded, not hidden: ~36 MB of tarballs, plus a full copy per bump. calendar is 19 of those
# and is the first place to look if this ever has to shrink.
# Only FILE edits belong here — `occ config:app:set` lives in the database, so it survives an app
# update, and stays in 15-branding, 16-app-policy and 14-office.
# Converges on the VENDORED version, never "whatever is newest" (#117): the same seed produces the
# same instance. Bumping an app is an edit, not a command — new tarball, new VENDOR lines, re-seed.
# eurooffice is installed here and configured in 14-office: this phase owns which apps exist and
# what is patched inside them.
phase_begin "12-apps" "apps this instance runs, plus the edits inside them"

# calendar and contacts were enabled by hand and ran undeclared until 2026-08-03, so a clean install
# did not reproduce them — `make divergence` had been saying so on every run.
#
# DROPPED 2026-08-08, ~25 MB: `maps`, because geography is Territorio's and it is a standalone app
# by that repo's ADR-0001, not a Nextcloud Maps layer; `news`, because epidemiologia now carries the
# MINSAL and ISP feeds it was there for. Neither was configured by any phase. Removing an app from
# this list does NOT uninstall it — nothing here deletes — so a live instance also needs
# `occ app:remove <id>` once, by hand, which is what `make divergence` reports until you do.
APPS="groupfolders side_menu eurooffice calendar contacts"

# Apps WE write (ADR-0003, reversing AD-1). They ship as a tarball under provisioning/apps/ exactly
# like the ones above, built from a release tag of their own repository — so an install needs no
# network, no git and no GitHub. A separate list because they need one extra thing the others do
# not: on a DEVELOPMENT machine apps/<id> is a live git clone rather than an unpacked tarball, and
# unpacking over it would delete a working tree. ensure_own_app dispatches on whether .git is there.
# `make divergence` reads both lists.
# Format: <appid>=<clone url>, one per line, no spaces around the `=`. The URL is only ever printed,
# to tell a developer where the code lives — nothing in an install fetches it.
OWN_APPS="epidemiologia=https://github.com/APS-Conecta/epidemiologia.git"

for entry in $OWN_APPS; do
  ensure_own_app "${entry%%=*}" "${entry#*=}"
done

# Lab apps: ours, under development, NEVER shipped (ADR-0005). Inventory in dev/lab-apps.sh, which
# is tracked but inert — a clinic reads it and falls through here.
#
# THE .git TEST IS THE WHOLE MECHANISM, not a nicety. ensure_own_app hands a directory with no .git
# to ensure_vendored_app, and a lab app has no tarball to unpack: dropping this line was run on
# 2026-08-08 and phase 12 died with "FAILED territorio — no vendored tarball", i.e. every clinic
# install. Guard here rather than inside ensure_own_app, which is right to keep that fallthrough for
# the apps we DO ship.
if [ -f dev/lab-apps.sh ]; then
  . dev/lab-apps.sh
  for entry in ${LAB_APPS:-}; do
    app="${entry%%=*}"
    [ -d "apps/$app/.git" ] || continue
    ensure_own_app "$app" "${entry#*=}"
  done
fi

for app in $APPS; do
  ensure_vendored_app "$app"
  patched=
  for patch in "$HERE"/apps/"$app"/*.patch; do
    [ -e "$patch" ] || continue
    apply_patch "$app" "$patch"
    patched=1
  done

  # appinfo/signature.json is a vendor claim that the files are as shipped; our patches make it
  # false, so the integrity check fails and admin > Overview goes permanently red (#71). Nextcloud
  # verifies a non-shipped app only if that file is present (Checker.php:546), so deleting the claim
  # we just invalidated is both the fix and an honest description of what we did. Core and every
  # unpatched app keep their check. Query-before-set: the second seed finds nothing to drop.
  sig="custom_apps/$app/appinfo/signature.json"
  if [ -n "$patched" ] && occ_sh "test -e $sig"; then
    occ_sh "rm -f $sig" && log "signature dropped for $app (patched, so it no longer describes the files)"
  fi
done

phase_end
