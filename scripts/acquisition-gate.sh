#!/usr/bin/env bash
# The acquisition gate — the installer never reaches a non-APS-Conecta source at install time
# (the steer's channel-completeness principle). Two check classes:
#
# UNCONDITIONAL — true of upstream's own tree; our patches must never break them, and an
# upstream change that does is the drift signal, loudly:
#   - zero `git clone` across the runtime surfaces (every *.sh under Containers/ and php/ —
#     the scripts the shipped containers execute). Measured: upstream ships none. The one git
#     clone upstream does ship is talk-recording's Dockerfile — BUILD-time, from the suite's source tree; the *.sh scoping excludes it by construction. A repo row's
#     path is its own release (ADR-0017), and provisioning never clones at all.
#
# ROWS — the same contract as brand-gate.sh: every row fires unconditionally; the patch ID is
#   attribution, never a condition.
#   020 — the store-off posture: NC_appstoreenabled="0" ENV in the nextcloud Dockerfile. With
#         the store on, occ upgrade re-downloads every enabled app and no pin can hold. #42
#         kept the ENV and named its one exception: a command may open the store for itself,
#         alone (row 042) — nothing else ever sees it open.
#   040 — independent self-update paths are absent from the wizard and nightly backup.
#   051 — deSEC registration and IP updates are absent from runtime, including PHP.
#   030 — the image's own posture (slice 13's bake, retired by #42): the skeleton stays baked
#         (NC_skeletondirectory="" beside 020's store-off), the theme rides the image from the
#         tag tree's own themes/apsconecta, and NOTHING app-shaped is copied into
#         /usr/src/nextcloud — apps arrive by their own channels (ADR-0017 releases for own and
#         fork rows, row 042's scoped store for store rows). The ENV_PREFIX wiring grep stays:
#         a server bump that renames the NC_ harvest would flip the store back on with every
#         gate green.
#   042 — the store rules, no bake (#42): three rows. (1) The entrypoint installs notify_push
#         from the store ONLY when it is missing, and that install opens the store for that
#         one command — a per-process NC_appstoreenabled=1 prefix while the container ENV
#         stays "0"; every update leg stays closed. Talk left this channel for its fork's
#         signed releases (ADR-0020, row 145), so notify_push is the scoped open's only
#         first-boot user. (2) AIO's automatic app updates are forced off: the entrypoint runs
#         no scheduled app:update --all and reads UPDATE_NEXTCLOUD_APPS nowhere — apps move
#         only when the operator decides (`aps-conecta actualizar`). (3) Provisioning's store
#         rows install through the same scoped open (occ_store in lib.sh), never a bare
#         `occ app:install`.
#   145 — spreed's channel is the fork's own signed release (ADR-0020): the manifest row is
#         source fork with release on (never the store), the entrypoint installs spreed
#         nowhere (its Talk block is presence-gated configuration alone), and the resolver
#         honours the record's Talk switch — Talk off resolves nothing. The fork repo and its
#         per-suite-release refresh live outside this tree; the release chain's spreed step
#         (release.yml) is what keeps them honest at suite-release time.
#
# ROUTED (this repo cannot see these channels — recorded so the ledger stays complete, the
# slice-4 curl→030 precedent): own and fork apps' bytes live in their own repos' signed
# releases (ADR-0017, resolved and verified by the wizard's fetch leg at install time); the
# host-bundle sha256 is the suite Release's SHA256SUMS (slice 19); data-package checksums are
# slice 21. Store apps' bytes live in the Nextcloud app store, fetched per command by the
# scoped opens this gate pins. Every channel the AIO tree CAN see is checked here or in
# brand-gate.sh.
#
# Usage: scripts/acquisition-gate.sh TREE     (TREE = the tree to assert, e.g. . — the checkout)
set -uo pipefail

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


row 020 "the app store is off at the image level — NC_appstoreenabled=\"0\" ENV in Containers/nextcloud/Dockerfile; the only openings are 042's per-command scoped installs" \
  grep -q 'NC_appstoreenabled="0"' "$TREE/Containers/nextcloud/Dockerfile"

row 015 "the Euro-Office DocumentServer is pinned — Containers/eurooffice/Dockerfile builds FROM documentserver v9.3.4, the version office-smoke asserts the running DS equals" \
  grep -q 'documentserver:v9.3.4' "$TREE/Containers/eurooffice/Dockerfile"

selfupdate_absent() {
  local status
  if grep -nEi 'watchtower|automatic_updates|UpdateMastercontainer|StartAndUpdateContainers|PullContainerImages' \
      "$TREE/php/public/index.php" "$TREE/php/templates/containers.twig" \
      "$TREE/Containers/mastercontainer/cron.sh" "$TREE/Containers/mastercontainer/daily-backup.sh"; then
    return 1
  else
    status=$?
    [ "$status" -eq 1 ] || return "$status"
  fi
  grep -q 'api/docker/start' "$TREE/php/templates/containers.twig"
}

row 040 "the wizard and nightly backup have no independent self-update path; normal container start remains" \
  selfupdate_absent

desec_surfaces_gone() {
  local status
  [ ! -e "$TREE/php/src/Desec" ] \
    && [ ! -e "$TREE/php/src/Controller/DesecController.php" ] \
    && [ ! -e "$TREE/Containers/mastercontainer/desec-ip-updater.sh" ] || return 1
  if grep -rniHE 'desec|DEDYN_SUFFIX' "$TREE/php/templates" "$TREE/php/public" \
      "$TREE/php/src/Data/ConfigurationManager.php" "$TREE/php/src/DependencyInjection.php" \
      "$TREE/php/src/Controller" "$TREE/Containers/mastercontainer"; then
    return 1
  else
    status=$?
    [ "$status" -eq 1 ]
  fi
}

row 051 "the runtime carries only the establishment's own-domain path" \
  desec_surfaces_gone

row 051 "the own-domain flow is intact — the domain form still present (the deletion's positive control)" \
  grep -q 'id="domain"' "$TREE/php/templates/containers.twig"

theme_only_image() {  # the image's own posture, post-bake (#42): the theme rides the image
  # from the tag tree's own themes/apsconecta, NOTHING app-shaped is copied into the server's
  # app directories, and the ENV_PREFIX wiring grep still proves the NC_ channel is real in
  # the shipped server. A regeneration that reintroduces an app COPY (or drops the theme or
  # the grep) reds here — the one silently-baked-green path nothing else closes.
  local f="$TREE/Containers/nextcloud/Dockerfile"
  [ -f "$f" ] || { echo "  no Dockerfile at '$f'" >&2; return 1; }
  if grep -nE '^COPY[[:space:]].*[[:space:]]/usr/src/nextcloud/custom_apps/' "$f"; then
    echo "  a COPY line still fills custom_apps — no image carries suite apps (#42)" >&2
    return 1
  fi
  grep -q '^COPY themes/apsconecta/ /usr/src/nextcloud/themes/apsconecta' "$f" \
    || { echo "  the theme COPY line is missing — the image carries the theme from the tag tree and nothing else (#42)" >&2; return 1; }
  grep -q 'ENV_PREFIX' "$f" \
    || { echo "  the ENV_PREFIX wiring grep is missing — a server bump that renames the NC_ harvest would silently re-enable the store" >&2; return 1; }
}

row 030 "the suite's skeleton posture is baked — NC_skeletondirectory="" ENV beside 020's store-off (the wizard's admin is created at install time, before any phase can write config; the NC_ channel beats config.php)" \

row 030 "the suite's skeleton posture is baked — NC_skeletondirectory="" ENV beside 020's store-off (the wizard's admin is created at install time, before any phase can write config; the NC_ channel is read before config.php)" \
  grep -q 'NC_skeletondirectory=""' "$TREE/Containers/nextcloud/Dockerfile"

row 030 "the image carries only the theme — zero COPY lines into custom_apps, the theme from the tag tree's own themes/apsconecta, and the ENV_PREFIX wiring grep present (a regeneration that bakes an app back reds here; #42)" \
  theme_only_image

scoped_store_installs() {  # 042, 147: the shared boot helper owns the sole scoped install.
  local e="$TREE/Containers/nextcloud/entrypoint.sh" helper="$TREE/Containers/nextcloud/configure-apps.sh" fail=0
  [ -f "$e" ] && [ -f "$helper" ] || return 1
  grep -qF 'source /configure-apps.sh' "$e" && grep -qF 'configure_startup_apps || exit 1' "$e" \
    || { echo "  entrypoint lost its shared app configuration pass" >&2; fail=1; }
  grep -qF 'NC_appstoreenabled=1 php /var/www/html/occ app:install notify_push' "$helper" \
    || { echo "  notify_push lost its scoped store install" >&2; fail=1; }
  if grep -nE 'app:install|NC_appstoreenabled=1 .*app:update' "$e" "$helper" \
      | grep -vE 'NC_appstoreenabled=1 php /var/www/html/occ app:install notify_push >/dev/null 2>&1 \|\| \{$'; then
    echo "  a boot install escaped the sole scoped notify_push acquisition" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 042 "the entrypoint installs notify_push scoped — a per-process NC_appstoreenabled=1 on exactly that one install when it is missing, never on an update leg; Talk left the store channel for its fork's signed releases (ADR-0020), and no install of spreed remains in the entrypoint (#42, #145)" \
  scoped_store_installs

spreed_from_its_fork() {  # 145: the store→fork migration's tree half (ADR-0020). The
  # manifest's row names the fork repo with release on (never the store — apps.py refuses a
  # store row that sets it, so the shape here is the whole channel); the entrypoint installs
  # spreed nowhere; and the resolver's Talk gate exists — Talk off resolves nothing, the
  # record's own switch, the same gate phase 12 reads through TALK_ENABLED. What this tree
  # cannot see — the fork repo's releases, their upstream checksums, the refresh — is the
  # release chain's spreed step and the clean boot's assert-release-app, both at run time.
  local m="$TREE/apps.json" r="$TREE/scripts/releases.py" e="$TREE/Containers/nextcloud/entrypoint.sh" fila fail=0
  for f in "$m" "$r" "$e"; do
    [ -f "$f" ] || { echo "  no such file: $f — re-point this row" >&2; fail=1; }
  done
  [ "$fail" -eq 0 ] || return 1
  fila="$(python3 -c 'import json, sys
fila = next(a for a in json.load(open(sys.argv[1])) if a["id"] == "spreed")
assert fila["source"] == "fork" and fila["repo"] == "APS-Conecta/spreed" and fila.get("release") is True, fila' \
    "$m" 2>&1)" \
    || { echo "  apps.json's spreed row is not the fork's release row: $fila" >&2; fail=1; }
  if grep -nE 'app:(install|update)[[:space:]]+spreed' "$TREE/Containers/nextcloud/entrypoint.sh" "$TREE/Containers/nextcloud/configure-apps.sh"; then
    echo "  the entrypoint installs or updates spreed — the release channel and actualizar are its only movers" >&2
    fail=1
  fi
  if grep -nE 'def talk_on|TALK_ENABLED|spreed.*omitida.*Talk' "$r" "$TREE/provisioning/phases/12-apps.sh"; then
    echo "  a Talk selection gate remains in acquisition" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 145 "spreed's channel is the fork's own signed release — apps.json's row is source fork with release on, the entrypoint installs spreed nowhere, and the resolver gates it on the record's Talk switch (ADR-0020)" \
  spreed_from_its_fork

aio_auto_updates_off() {  # 042: AIO's Saturday app:update --all is gone and the env that
  # armed it is read nowhere — apps move only when the operator decides, whatever the config
  # says. The upgrade-path app:update --all calls stay by design: inert under 020 (the store
  # fetch answers empty), upstream-shaped, and never a scheduled anything.
  local e="$TREE/Containers/nextcloud/entrypoint.sh" c="$TREE/php/containers.json" fail=0
  [ -f "$e" ] || { echo "  no entrypoint at '$e'" >&2; return 1; }
  if grep -n 'UPDATE_NEXTCLOUD_APPS' "$e"; then
    echo "  the entrypoint still reads UPDATE_NEXTCLOUD_APPS — AIO's automatic app updates are off, config or not" >&2
    fail=1
  fi
  if grep -n 'date +%u' "$e"; then
    echo "  the entrypoint still selects a weekday — the Saturday automatic app-update leg is gone" >&2
    fail=1
  fi
  # The placeholder's answering arm is gone with the entrypoint leg (#42): a leftover
  # %UPDATE_NEXTCLOUD_APPS% in containers.json falls to getRegisteredSecret's default and
  # kills the container creation mid-recursion — the first nothing-baked rehearsal found
  # exactly that (aps-conecta-nextcloud never created, the 20-minute bring-up timeout).
  [ -f "$c" ] || { echo "  no containers.json at '$c'" >&2; return 1; }
  if grep -n 'UPDATE_NEXTCLOUD_APPS' "$c"; then
    echo "  containers.json still passes UPDATE_NEXTCLOUD_APPS — the arm that answered the placeholder is gone, and an unregistered placeholder aborts the container start" >&2
    fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 042 "AIO's automatic app updates are forced off — the entrypoint reads UPDATE_NEXTCLOUD_APPS nowhere and keeps no weekday-selected update leg; apps move only when the operator decides (#42)" \
  aio_auto_updates_off

provisioning_scoped_store() {  # 042: phase 12's store rows install through occ_store — the
  # one seam provisioning opens the store on (the same per-process NC_appstoreenabled=1,
  # ridden through docker exec -e), and no bare app:install call survives under
  # provisioning/ to bypass it.
  local l="$TREE/provisioning/lib.sh" fail=0
  [ -f "$l" ] || { echo "  no lib.sh at '$l'" >&2; return 1; }
  grep -qF 'nc_exec -e NC_appstoreenabled=1' "$l" \
    || { echo "  lib.sh no longer opens the store scoped (-e NC_appstoreenabled=1, one command at a time)" >&2; fail=1; }
  if grep -rnE 'occ app:install' "$TREE/provisioning"; then
    echo "  a bare app:install call survived under provisioning/ — the scoped open is occ_store's alone" >&2
    fail=1
  fi
  # the seam is an INSTALL seam, never an update one: a future occ_store app:update would
  # open the store for exactly the leg the doctrine closes, so only app:install may ride it
  if grep -rnE 'occ_store [^[:space:]]+' "$TREE/provisioning" | grep -vE 'occ_store app:install'; then
    echo "  occ_store carries a command other than app:install — the scoped open exists for installs alone (#42)" >&2
    fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 042 "provisioning installs store apps through the scoped seam — occ_store's per-command open in lib.sh, no bare app:install anywhere under provisioning/, and nothing but app:install rides the seam (#42)" \
  provisioning_scoped_store

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

community_channel_closed() {  # 190: the community channel is closed at its source — and, since #48,
  # removed whole: no community-containers directory in the tree, nothing copied or created in the
  # mastercontainer image, no template, no section, no comunitari prose, and the PHP readers gone
  # with it (the directory constant, the config property, the listing method, the form handler, the
  # Caddy trusted-proxy variable — the crafted community-form POST has no handler left to reach).
  local d="$TREE/Containers/mastercontainer/Dockerfile" c="$TREE/php/templates/containers.twig" \
        j="$TREE/php/public/containers-form-submit.js" fail=0
  s4_files "$d" "$c" "$j" || return 1
  [ ! -e "$TREE/community-containers" ] \
    || { echo "  the community-containers directory still ships" >&2; fail=1; }
  if grep -n 'community-containers' "$d"; then echo "  the image still names the community containers" >&2; fail=1; fi
  if grep -nF 'community-containers.twig' "$c"; then echo "  containers.twig still includes the community section" >&2; fail=1; fi
  if [ -e "$TREE/php/templates/includes/community-containers.twig" ]; then
    echo "  the community section's template still ships" >&2; fail=1
  fi
  if grep -niE 'comunitari' "$c"; then echo "  containers.twig still talks about community containers" >&2; fail=1; fi
  if grep -n 'communityFormSubmit' "$j"; then
    echo "  containers-form-submit.js still carries the community form's script" >&2; fail=1
  fi
  if grep -rn 'CommunityContainers\|community-form' "$TREE/php/src" "$TREE/php/public/index.php"; then
    echo "  a PHP reader of the community directory survived" >&2; fail=1
  fi
  # the restore button keeps a confirm: the restore spec accepts a dialog right before it clicks
  grep -qF "data-confirm='¿Restaurar la copia de seguridad seleccionada? Se reemplazará la instancia completa.'" "$c" \
    || { echo "  the restore button lost the confirm its spec accepts" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 190 "the community channel is gone whole — no directory, no image creation, no template or section, no community form script, no PHP reader (R25, closed at the source; #48 removed the readers)" \
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

fixed_suite_services() {  # 210, 183: included services cannot read persisted selections.
  python3 - "$TREE" <<'PYCODE'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
manager = (root / 'php/src/Data/ConfigurationManager.php').read_text()
for name in ('isClamavEnabled', 'isTalkEnabled', 'isImaginaryEnabled', 'isFulltextsearchEnabled', 'isHarpEnabled'):
    assert re.search(r'public bool \$' + name + r' \{\s*get => true;\s*}', manager), name
assert re.search(r'public bool \$isTalkRecordingEnabled \{\s*get => false;\s*}', manager)
for name in ('php/src/Data/Setup.php', 'php/src/Controller/ConfigurationController.php'):
    text = (root / name).read_text()
    assert not re.search(r'->is(?:Clamav|Talk|TalkRecording|Imaginary|Fulltextsearch|Harp)Enabled\s*=', text), name
assert 'options-form' not in (root / 'php/src/Controller/ConfigurationController.php').read_text()
PYCODE
}

row 210 "the full suite is fixed at the configuration boundary; legacy selections cannot disable included services or enable recording (ADR-0021, #183)" \
  fixed_suite_services

first_boot_quiet() {  # 220: a fresh install calls nothing it does not need (R28, the AIO side):
  # nextcloud_announcements is disabled in the fresh-install block, before its first cron run
  # fetches pushfeed.nextcloud.com. The rest of R28 (the connectivity check, the resolver noise,
  # HIBP, the tiles image) is the provisioning phases' or the published allowlist's.
  s4_files "$TREE/Containers/nextcloud/entrypoint.sh" || return 1
  s4_install_block 'php /var/www/html/occ app:disable nextcloud_announcements'
}

row 220 "a fresh install calls nothing it does not need — nextcloud_announcements disabled before its first cron (R28)" \
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
  # fork-live namespace (#48 removed the upstream QA suite the walk used to exclude); a list
  # re-spelled some other way would evade a literal grep, and that is the clean-boot rehearsal's
  # to catch, not a static row's — the check says what it pins instead of pretending.
  local m="$TREE/php/src/Data/ConfigurationManager.php" body fail=0 app
  s4_files "$m" "$TREE/install.sh" || return 1
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
      --exclude=acquisition-gate.sh \
      "$TREE/php" "$TREE/Containers" "$TREE/scripts" "$TREE/host" \
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
