#!/usr/bin/env bash
# The acquisition gate — the installer never reaches a non-APS-Conecta source at install time
# (the steer's channel-completeness principle). Two check classes:
#
# UNCONDITIONAL — true of upstream's own tree; our patches must never break them, and an
# upstream change that does is the drift signal, loudly:
#   - zero `git clone` across the runtime surfaces (every *.sh under Containers/ and php/ —
#     the scripts the shipped containers execute). Measured: upstream ships none. The one git
#     clone upstream does ship is talk-recording's Dockerfile — BUILD-time, in a sibling we
#     retag and never build; the *.sh scoping excludes it by construction. ensure_own_app's
#     clone channel is dev-only and superseded by the bake (research-verified).
#   - the entrypoint still honors the skip.update marker (honored at :185, deleted at :1154
#     today): the migration channel (slice 22) sets it, and with the store off it is
#     load-bearing for migrated clinics.
#
# ROWS — the same contract as brand-gate.sh: every row fires unconditionally; the patch ID is
#   attribution, never a condition.
#   020 — the store-off bake: NC_appstoreenabled="0" ENV in the nextcloud Dockerfile. With the
#         store on, occ upgrade re-downloads every enabled app and no VENDOR pin can hold;
#         the bake + this ENV make the entrypoint's store legs fail-fast.
#   040 — self-update opt-in (slice 9): the automatic_updates checkbox defaults OFF and the
#         wizard carries zero watchtower POST forms. The update channel stays deliberate —
#         D12's one-distribution rule makes even an opted-in nightly watchtower run a no-op
#         (a published tag's digests never move) until the operator runs a new tag on purpose.
#   051 — deSEC removal (slice 10, the v0.2.0 spec): zero deSEC surfaces across templates and
#         public assets; the own-domain form stays as the positive control. The PHP routes
#         (index.php's /desec + /api/desec/register, DesecManager) stay as unreachable dead
#         code per the zero-PHP rule — unreachable because the markup that reached them is
#         what this patch deletes.
#   030 — the bake (slice 13): three rows. (1) The bake channel is checksum-gated at build
#         time — scripts/bake.sh re-runs gestion's VENDOR sha256 gate before any tarball
#         enters the image; the tarball BYTES are gestion-side (test.sh:63-70), so this row
#         pins the MECHANISM to the fork. (2) The suite's skeleton posture is baked —
#         NC_skeletondirectory="" ENV beside 020's store-off (the compose stack's own key,
#         compose.yaml: the wizard's admin is created before any phase can write config, and
#         the NC_ channel is read before config.php). (3) The bake's runtime half is wired —
#         the aps-bake COPY lines and the ENV_PREFIX wiring grep present in the Dockerfile;
#         without this row a regeneration that loses them passes every other row green
#         and ships an unbaked image (the one silently-unbaked-green path
#         nothing else closes). The plan's fourth row — curl in the runtime apk set — was
#         dropped live per FINDINGS P6: /usr/bin/curl 8.22.0 measured PRESENT in the AIO
#         runtime (transitive apk dep; phase 07's AIA fetch already imported the GlobalSign
#         intermediate on the probe), so the premise "the AIO runtime shipped no curl" was
#         falsified and the explicit apk entry would pin a dependency that already ships.
#
# ROUTED (this repo cannot see these channels — recorded so the ledger stays complete, the
# slice-4 curl→030 precedent): VENDOR sha256s live with the vendored tarballs, read from the old
# gestion until #42; the host-bundle sha256 is the suite Release's SHA256SUMS (slice 19);
# data-package checksums are slice 21. Every channel the AIO tree CAN see is checked here or in
# brand-gate.sh.
#
# Usage: scripts/acquisition-gate.sh TREE     (TREE = the tree to assert, e.g. . — the checkout)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "FATAL: $*" >&2; exit 1; }

fails=0
row() {  # ID DESCRIPTION CMD... — fires unconditionally; the ID names the change that owes this
  local id="$1" desc="$2"; shift 2
  if "$@"; then
    printf '  ok: %s — %s\n' "$id" "$desc"
  else
    printf 'FAIL: %s — %s\n' "$id" "$desc" >&2
    fails=$((fails+1))
  fi
}

clone_free() {  # zero git clone in the runtime *.sh surfaces (hits print as evidence)
  local hits=0
  grep -rn --include="*.sh" "git clone" "$TREE/Containers" "$TREE/php" && hits=1
  [ "$hits" -eq 0 ]
}


TREE="${1:?usage: scripts/acquisition-gate.sh TREE (the tree to assert, e.g. .)}"
[ -d "$TREE/php" ] || die "'$TREE' does not look like the instalador tree (no php/ in it)"


if clone_free; then
  printf '  ok: zero git clone across runtime surfaces — install-time channels stay APS-Conecta-only\n'
else
  echo "FAIL: a runtime script git-clones — the installer's channels are APS-Conecta-only (see the hits above)" >&2
  fails=$((fails+1))
fi
if grep -q "skip.update" "$TREE/Containers/nextcloud/entrypoint.sh"; then
  printf '  ok: the entrypoint still honors skip.update — the migration channel (slice 22) depends on it\n'
else
  echo "FAIL: the entrypoint no longer honors skip.update — the migration channel (slice 22) depends on it; adopt upstream's rename in the migration tool first" >&2
  fails=$((fails+1))
fi


row 020 "the app store is baked off — NC_appstoreenabled=\"0\" ENV in Containers/nextcloud/Dockerfile" \
  grep -q 'NC_appstoreenabled="0"' "$TREE/Containers/nextcloud/Dockerfile"

row 015 "the eurooffice documentserver base pins the suite's certified pairing (DS 9.3.4 ↔ the eurooffice connector — R3's set-certified pin, re-cut from the v0.2.0 choreography's main commit; the connector itself is the APS fork since #36, so its half of the pairing re-certifies per fork release in the office smoke's round-trip)" \
  grep -q 'documentserver:v9.3.4' "$TREE/Containers/eurooffice/Dockerfile"

selfupdate_optin() {  # the suite's update channel is opt-in: checkbox defaults off, no watchtower POST remains
  local f="$TREE/php/templates/containers.twig"
  # both halves (test.sh:217-263 discipline): the unchecked shape PRESENT, the checked shape ABSENT
  if ! grep -q 'id="automatic_updates" name="automatic_updates">' "$f"; then
    echo "  the automatic_updates checkbox is missing or attribute-shaped differently — patch 040's default-off flip is not in the tree" >&2
    return 1
  fi
  if grep -q 'id="automatic_updates" name="automatic_updates" checked' "$f"; then
    echo "  the automatic_updates checkbox still defaults ON — the nightly chain would arm itself on first save" >&2
    return 1
  fi
  if grep -q 'api/docker/watchtower' "$f"; then
    echo "  a watchtower POST form survived — the manual mastercontainer-update trigger is still reachable from the wizard" >&2
    return 1
  fi
  if ! grep -q 'api/docker/start' "$f"; then
    echo "  the container-start forms vanished — patch 040 ate more than the watchtower arms" >&2
    return 1
  fi
}


row 040 "self-update stays opt-in — the automatic_updates checkbox defaults OFF and the wizard carries zero watchtower POST forms (the nightly chain arms only by deliberate operator choice)" \
  selfupdate_optin

desec_surfaces_gone() {  # zero deSEC refs across wizard templates and public assets (hits print).
  # PHP stays byte-identical (zero-PHP rule): index.php keeps the /desec route and the twig
  # context vars, php/src keeps DesecManager — the scan excludes PHP by construction (templates
  # carry no PHP; the public half is include-scoped to js/css).
  local hits=0
  grep -rniHE 'desec' "$TREE/php/templates" && hits=1
  grep -rniHE --include='*.js' --include='*.css' 'desec' "$TREE/php/public" && hits=1
  [ "$hits" -eq 0 ]
}


row 051 "the deSEC registration channel is gone from the wizard — zero deSEC refs across templates and public assets (the third-party domain-registration flow removed at the only layer the operator sees)" \
  desec_surfaces_gone

row 051 "the own-domain flow is intact — the domain form still present (the deletion's positive control)" \
  grep -q 'id="domain"' "$TREE/php/templates/containers.twig"

bake_checksum_gate() {  # the bake channel re-runs gestion's VENDOR gate before anything unpacks
  # (the mechanism lives on the fork — the BYTES it gates are gestion-side: test.sh:63-70)
  local f="$REPO_ROOT/scripts/bake.sh"
  [ -f "$f" ] || { echo "  scripts/bake.sh is missing on the fork — the bake channel is ungated" >&2; return 1; }
  grep -q 'sha256sum --check --status' "$f" \
    || { echo "  bake.sh no longer runs sha256sum --check against the VENDOR pins — an ungated bake ships whatever the clone carried" >&2; return 1; }
  grep -qF 'expected exactly 1' "$f" \
    || { echo "  bake.sh no longer enforces the one-tarball-per-app guard — a stale second tarball would bake silently" >&2; return 1; }
  grep -qF 'no longer applies' "$f" \
    || { echo "  bake.sh no longer carries the three-outcome abort — a drifted patch would fuzz or fail soft" >&2; return 1; }
}

bake_runtime_wired() {  # the bake's runtime half exists in the tree — the COPY lines that
  # pull the bake's output into the image and the ENV_PREFIX grep that proves the NC_ channel
  # is real in the shipped server. Without this row a regeneration that loses these lines
  # passes every other row green while the Images build ships an unbaked image.
  local f="$TREE/Containers/nextcloud/Dockerfile"
  [ -f "$f" ] || { echo "  no Dockerfile at '$f'" >&2; return 1; }
  grep -q '^COPY aps-bake/custom_apps/ /usr/src/nextcloud/custom_apps/' "$f" \
    || { echo "  the bake's custom_apps COPY line is missing — the image builds without the app set" >&2; return 1; }
  grep -q '^COPY aps-bake/themes/apsconecta/ /usr/src/nextcloud/themes/apsconecta' "$f" \
    || { echo "  the bake's theme COPY line is missing — the image builds without the apsconecta theme" >&2; return 1; }
  grep -q 'ENV_PREFIX' "$f" \
    || { echo "  the ENV_PREFIX wiring grep is missing — a server bump that renames the NC_ harvest would silently re-enable the store" >&2; return 1; }
}

row 030 "the bake channel is checksum-gated at build time — scripts/bake.sh re-runs gestion's VENDOR sha256 gate (sha256sum --check against each tarball's VENDOR pin) before any byte enters the image; the tarball bytes themselves are gestion-side (test.sh:63-70), so this row pins the mechanism to the fork" \
  bake_checksum_gate

row 030 "the suite's skeleton posture is baked — NC_skeletondirectory="" ENV beside 020's store-off (the wizard's admin is created at install time, before any phase can write config; the NC_ channel is read before config.php)" \
  grep -q 'NC_skeletondirectory=""' "$TREE/Containers/nextcloud/Dockerfile"

row 030 "the bake's runtime half is wired — both aps-bake COPY lines and the ENV_PREFIX wiring grep present in the Dockerfile (a regeneration that drops them would otherwise pass every other row green and ship an unbaked image — the one silently-unbaked-green path nothing else closes)" \
  bake_runtime_wired

# ── L4 S4a: behaviour (R25 community + office, R29 defaults, R28 first-boot calls, R31) ──────

s4_files() {  # PATH... — every file an S4 row reads must exist: a negative arm over a moved file
  # would pass vacuously (grep's «no such file» reads as «no hit»)
  local f fail=0
  for f in "$@"; do [ -f "$f" ] || { echo "  no such file: $f — re-point this row" >&2; fail=1; }; done
  [ "$fail" -eq 0 ]
}

# shellcheck disable=SC2016  # the pattern is the entrypoint's own shell text, not an expansion
s4_install_block() {  # LINE — LINE sits in the entrypoint's fresh-install block: inside the
  # `installed_version = 0.0.0.0` branch, after `occ maintenance:install`, before the first
  # `occ maintenance:repair` that follows it (the repair runs the apps' repair steps; the first
  # cron comes later still)
  local e="$TREE/Containers/nextcloud/entrypoint.sh" z i r l
  z="$(grep -nF 'if [ "$installed_version" = "0.0.0.0" ]; then' "$e" | head -1 | cut -d: -f1)"
  i="$(awk -v z="${z:-0}" 'NR > z && /occ maintenance:install/ {print NR; exit}' "$e")"
  r="$(awk -v i="${i:-0}" 'NR > i && /occ maintenance:repair$/ {print NR; exit}' "$e")"
  l="$(grep -nF -e "$1" "$e" | head -1 | cut -d: -f1)"
  if [ -z "$z" ] || [ -z "$i" ] || [ -z "$r" ] || [ -z "$l" ] || [ "$l" -le "$i" ] || [ "$l" -ge "$r" ]; then
    echo "  not in the fresh-install block (branch :${z:-?}, install :${i:-?}, line :${l:-?}, repair :${r:-?}): $1" >&2; return 1
  fi
  if sed -n "${l}p" "$e" | grep -q '^[[:space:]]*#'; then echo "  commented out in the fresh-install block: $1" >&2; return 1; fi
}

community_channel_closed() {  # 190: the image ships no community container (R25). The third-party
  # channel upstream offers next to health data (AzuraCast, Jellyfin, Vaultwarden, …) is closed at
  # its source: the mastercontainer image creates an EMPTY community-containers directory (DataConst
  # realpaths it, so it must exist), the page no longer includes the section (a17's own arm) and the
  # template is gone, the restore note about community backups is gone, and the options script
  # tolerates the absent form. A crafted community-form POST has nothing to enable:
  # ConfigurationController keeps only ids the directory lists.
  local d="$TREE/Containers/mastercontainer/Dockerfile" c="$TREE/php/templates/containers.twig" \
        j="$TREE/php/public/containers-form-submit.js" fail=0
  s4_files "$d" "$c" "$j" || return 1
  if grep -n 'COPY community-containers' "$d"; then echo "  the image still copies upstream's community containers" >&2; fail=1; fi
  grep -qF 'RUN mkdir -p /var/www/docker-aio/community-containers' "$d" \
    || { echo "  the image no longer creates the empty community-containers directory DataConst reads" >&2; fail=1; }
  if grep -nF 'community-containers.twig' "$c"; then echo "  containers.twig still includes the community section" >&2; fail=1; fi
  if [ -e "$TREE/php/templates/includes/community-containers.twig" ]; then
    echo "  the community section's template still ships" >&2; fail=1
  fi
  if grep -niE 'comunitari' "$c"; then echo "  containers.twig still talks about community containers" >&2; fail=1; fi
  if grep -n 'communityFormSubmit\.' "$j" | grep -v 'if (communityFormSubmit)'; then
    echo "  containers-form-submit.js dereferences the absent community form" >&2; fail=1
  fi
  # the restore button keeps a confirm: the restore spec accepts a dialog right before it clicks
  grep -qF "data-confirm='¿Restaurar la copia de seguridad seleccionada? Se reemplazará la instancia completa.'" "$c" \
    || { echo "  the restore button lost the confirm its spec accepts" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 190 "the image ships no community container — an empty directory instead of upstream's set, no community section or template, no community restore note, the options script tolerant of the absent form (R25)" \
  community_channel_closed

# shellcheck disable=SC2016  # the patterns are literal PHP — their $ is not a shell expansion
office_is_euro_office() {  # 200: the suite's office is Euro-Office, and only Euro-Office (R25, D12 b).
  # The options form refuses any other office_suite_choice — the one PHP guard, its throw on the
  # line after the test, both before the setter — with a 422 and a Spanish message, and the page
  # no longer offers «Desactivar suite de oficina». Setup's first-boot copy of the default
  # (Setup.php:28) never passes through the controller, so the guard cannot refuse the suite's own
  # default; the suite's drive never posts an office choice.
  local k="$TREE/php/src/Controller/ConfigurationController.php" \
        o="$TREE/php/templates/includes/optional-containers.twig" s="$TREE/php/tests/tests/initial-setup.spec.js" fail=0 g w
  s4_files "$k" "$o" "$s" "$TREE/php/public/style.css" || return 1
  g="$(grep -nF 'if ($officeSuite !== OfficeSuite::Eurooffice) {' "$k" | head -1 | cut -d: -f1)"
  w="$(grep -nF '$this->configurationManager->officeSuite = $officeSuite;' "$k" | head -1 | cut -d: -f1)"
  if [ -z "$g" ] || [ -z "$w" ] || [ "$g" -ge "$w" ]; then
    echo "  ConfigurationController stores an office choice without refusing a non-Euro-Office one first" >&2; fail=1
  fi
  grep -A1 -F 'if ($officeSuite !== OfficeSuite::Eurooffice) {' "$k" \
    | grep -qF "throw new InvalidSettingConfigurationException('La oficina de la suite es Euro-Office: no se puede cambiar ni desactivar.');" \
    || { echo "  the refusal does not throw its Spanish message inside the guard" >&2; fail=1; }
  if grep -n 'office-none' "$o" "$TREE/php/public/style.css"; then echo "  the page still offers (or styles) disabling the office suite" >&2; fail=1; fi
  if [ -e "$TREE/php/public/img/office-none.svg" ]; then echo "  the office-none icon still ships" >&2; fail=1; fi
  grep -qF 'id="office-eurooffice"' "$o" || { echo "  the Euro-Office card is gone (the guard's positive control)" >&2; fail=1; }
  if grep -nE "Desactivar suite de oficina|#office-none" "$s"; then
    echo "  initial-setup.spec.js still disables the office suite" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 200 "the suite's office is Euro-Office only — any other office choice is refused before it is stored (422, Spanish), and the page offers no way to disable it (R25, D12 b)" \
  office_is_euro_office

options_start_off() {  # 210: Talk, Whiteboard and Imaginary start off (R29, R27.5/7; D12 a) — the
  # three PHP default literals Setup.php copies into a fresh config. The Provisionador's step 7 turns Talk on
  # where the server's memory and cores allow; the translated suite's persisted-defaults spec
  # expects the same three falses.
  local m="$TREE/php/src/Data/ConfigurationManager.php" s="$TREE/php/tests/tests/persist-default-config.spec.js" fail=0 k
  s4_files "$m" "$s" || return 1
  for k in isTalkEnabled isWhiteboardEnabled isImaginaryEnabled; do
    grep -qF "get => (bool) \$this->get('$k', false);" "$m" || { echo "  $k does not default to off" >&2; fail=1; }
    if grep -nF "get('$k', true)" "$m"; then echo "  a $k getter still defaults on" >&2; fail=1; fi
    grep -qF "$k: false," "$s" || { echo "  persist-default-config.spec.js does not expect $k off" >&2; fail=1; }
  done
  [ "$fail" -eq 0 ]
}

row 210 "Talk, Whiteboard and Imaginary start off — the three PHP defaults a fresh config copies, and the suite's spec expecting them (R29, D12 a)" \
  options_start_off

first_boot_quiet() {  # 220: a fresh install calls nothing it does not need (R28, the AIO side):
  # whiteboard's npm never asks the registry about its own update (when Whiteboard is enabled —
  # 210 starts it off), and nextcloud_announcements is disabled in the fresh-install block, before
  # its first cron run fetches pushfeed.nextcloud.com. The rest of R28 (the connectivity check, the
  # resolver noise, HIBP, the tiles image) is the provisioning phases' or the published allowlist's.
  local w="$TREE/Containers/whiteboard/Dockerfile" fail=0
  s4_files "$w" "$TREE/Containers/nextcloud/entrypoint.sh" || return 1
  grep -qF 'ENV NPM_CONFIG_UPDATE_NOTIFIER=false' "$w" || { echo "  whiteboard's npm still checks for its own update" >&2; fail=1; }
  s4_install_block 'php /var/www/html/occ app:disable nextcloud_announcements' || fail=1
  [ "$fail" -eq 0 ]
}

row 220 "a fresh install calls nothing it does not need — whiteboard's npm update check off, nextcloud_announcements disabled before its first cron (R28)" \
  first_boot_quiet

circles_probe_skipped() {  # 230: the fresh install logs no «relation "oc_circle_circles" does not
  # exist» (R31): circles' migration_22 is marked done between the install and the first repair,
  # so the repair never probes the legacy table a fresh install does not have. The theming
  # background job's one-shot error needs no patch: phase 15 stores the brand images,
  # which creates appdata theming/global.
  s4_files "$TREE/Containers/nextcloud/entrypoint.sh" || return 1
  s4_install_block 'php /var/www/html/occ config:app:set circles migration_22 --value=1'
}

row 230 "the fresh install skips circles' legacy-table probe — migration_22 marked done between the install and the first repair (R31)" \
  circles_probe_skipped

startup_apps_default_empty() {  # 270: the fork's startup-app default is the empty string (#67) —
  # upstream's six-app fallback was a second app list beside apps.json, and a latent store
  # channel: with NEXTCLOUD_STARTUP_APPS unset, the entrypoint's startup loop would app:install
  # the apps the manifest never declares while the store is still on at first boot. The CLI and
  # the testbed pass the empty value regardless (its own self-test asserts the string), so a
  # clean boot installs exactly what it installed before: the manifest's set, nothing more.
  # Two arms, the both-halves discipline: the method's fallback IS the empty string, and
  # upstream's startup-set literal is gone from the fork-live surfaces. The scan walks every
  # fork-live namespace — tests/QA rides --exclude-dir because it is upstream's own QA suite,
  # #48-doomed with the other un-walked upstream parts (the Helm chart, manual install, the
  # upstream root docs, the app directory, community containers, the inert workflows); a list
  # re-spelled some other way would evade a literal grep, and that is the clean-boot rehearsal's
  # to catch, not a static row's — the check says what it pins instead of pretending.
  local m="$TREE/php/src/Data/ConfigurationManager.php" body fail=0 app
  s4_files "$m" "$TREE/compose.yaml" "$TREE/install.sh" || return 1
  body="$(awk '/public function getNextcloudStartupApps/,/^    \}/' "$m")"
  [ -n "$body" ] || { echo "  getNextcloudStartupApps is gone — re-point this row" >&2; return 1; }
  printf '%s' "$body" | grep -qF "return '';" \
    || { echo "  the startup-app fallback is not the empty string" >&2; fail=1; }
  for app in deck twofactor_totp tasks calendar contacts notes; do
    printf '%s' "$body" | grep -qw "$app" \
      && { echo "  the startup-app fallback still names $app" >&2; fail=1; }
  done
  # --exclude=this gate's own name: the literal above is this row's probe, not an app list (the
  # comm tripwire's precedent — the alarm keeps its own copy on purpose).
  if grep -rnF 'deck twofactor_totp tasks calendar contacts notes' \
      --exclude=acquisition-gate.sh --exclude-dir=QA \
      "$TREE/php" "$TREE/Containers" "$TREE/compose.yaml" "$TREE/scripts" "$TREE/host" \
      "$TREE/provisioning" "$TREE/aps" "$TREE/docs" "$TREE/sites" "$TREE/themes" \
      "$TREE/tests" "$TREE/install.sh" 2>/dev/null; then
    echo "  an app list beside the suite manifest survives in a fork-live surface (see the hits above)" >&2
    fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 270 "the startup-app default is empty and apps.json is the only app list — ConfigurationManager's fallback is the empty string and upstream's startup-set literal is gone from every fork-live surface this row walks (#67)" \
  startup_apps_default_empty

if [ "$fails" -gt 0 ]; then
  echo "ACQUISITION GATE: *** FAIL *** — $fails check(s) failed" >&2
  exit 1
fi
echo "ACQUISITION GATE: PASS — install-time channels stay APS-Conecta-only; every row measured, zero skipped"
