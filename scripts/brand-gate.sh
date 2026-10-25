#!/usr/bin/env bash
# The brand gate — the shipped tree must carry OUR identity on every surface the fork has
# rebranded. Since the hard fork (Stage 3) the repo checkout IS the shipped tree — what the
# Images pipeline builds and the clinic runs — and the gate asserts the tree its argument
# names (ci.yml and the release chain both run it against the checkout).
#
# THE ROW CONTRACT (inverted with the hard fork): every row fires on every run. The patch
# content is committed bytes now, so each row is an unconditional assert against the promoted
# tree; the patch ID a row names is attribution — which change owes the guarantee — never a
# condition. "Is the change measured?" has exactly one answer: every row always runs. A row
# that cannot find its subject reds (the rows' own no-such-file arms make a moved target a
# loud failure, never a silent pass).
#
# THE ROW LEDGER (all landed — the queue is gone; the IDs name the changes that owe each
# row): the registry-ref rows — the FRD's brand contract verbatim, zero
# ghcr.io/nextcloud-releases refs including php/src. 010 owns containers.json (plus the
# fork-ref floor: the generated sed's auto-include property means the count only grows — a
# shrunken parse is the B-014 class); 080 owns php/src (the 3 string refs:
# DockerActionManager.php:788, 789, 1111 — the misparse fallback and the 90-day nag's data
# source). Patch 050's vendor-surface rows landed with slice 9: the wizard's office selection
# is ours alone (zero Collabora/OnlyOffice ids across templates and public assets, the
# dictionaries forms gone from the templates, the eurooffice card intact as the positive
# control, the dead vendor svg assets absent). Patch 060's string rows landed with slice 11:
# the operator-visible language is ours (every wizard surface carries the es-CL sweep —
# per-file sentinel pairs, English gone and es-CL present, the JS↔twig toggle words equal)
# and the changelog links point at the fork's own releases, never upstream's. 070's brand
# rows landed with slice 12 (the <title>/h1 swap is the reskin's, not the sweep's — plus the
# asset/token/font floors, the dark-toggle deletion, and the two handoff cards). 030's row
# landed with slice 13 as a build-time assert in the bake, and #42 moved it once more: the
# renames are commits in the fork's own repo now (#36), no image carries app bytes, and the
# enforcement is the clean-boot rehearsal's greps over the INSTALLED bytes — the row pins
# that owner, and the manifest's source:fork, to this tree. And slice 23 extends
# this gate with the README/twig string-equality drift gate.
#
# SCOPE (measured against the tree; grep -rl nextcloud-releases outside containers.json and
# php/src/DockerActionManager.php = 30 files): root docs (readme.md, reverse-proxy.md,
# manual-upgrade.md, develop.md, multiple-instances.md, php/README.md), the helm chart (15
# templates + update-helm.sh), manual-install/latest.yml, root compose.yaml,
# the QA harness (php/tests/compose.yaml), containers.twig's changelog link, and the two
# build-time fetches upstream keeps (whiteboard's FROM line; the GPG-verified server tarball
# in the nextcloud Dockerfile, D7) — plus, since slice 13, the fork's OWN build-time fetch:
# the Images workflow's gestion clone, the bake channel (an APS-Conecta source, VENDOR-
# sha256-gated by scripts/bake.sh, and maintainer-side like the other two — it feeds the
# builder, never the clinic's install). The count uses the BARE pattern — two of the 30 carry
# the name without the contiguous ghcr.io/ prefix (two github.com/nextcloud-releases URLs), so
# the gate's own literal grep stays narrower than
# this ledger on purpose. None is install-time shipped surface: docs are slice 23's
# fork-declaration territory, the harness image is slice 18's, containers.twig's changelog
# link was 060's operator-visible territory (repointed to the fork's releases — the row landed
# with slice 11 and measures it), and the build-time fetches
# are the maintainer's build, not the clinic's install. This gate owns what the clinic's
# install actually resolves: containers.json and php/src.
#
# Usage: scripts/brand-gate.sh TREE     (TREE = the tree to assert, e.g. . — the checkout)
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

upstream_refs() {  # PATH... — zero ghcr.io/nextcloud-releases refs; every hit prints as evidence
  local f hits=0
  for f in "$@"; do
    [ -e "$f" ] || { echo "upstream_refs: no such path: $f" >&2; return 1; }
    grep -rnH "ghcr.io/nextcloud-releases" "$f" && hits=$((hits+1))
  done
  [ "$hits" -eq 0 ]
}

fork_ref_floor() {  # FILE MIN — at least MIN ghcr.io/aps-conecta/ refs (line-counted)
  local n
  n="$(grep -c "ghcr.io/aps-conecta/" "$1")"
  [ "$n" -ge "$2" ] \
    || { echo "  only $n aps-conecta refs in $1 (floor $2) — the sed's prefix rule missed a ref shape, or the list shrank" >&2; return 1; }
}

swept_table() {  # 060's per-file sentinel table — ONE writer, three readers: escl_sweep walks
  # it below (absent/present arms), --swept-files prints the file column (the wizard-string
  # drift report's subject list, org L7-2), and --sentinel-pair N prints one row (the CI
  # regression-injection arm's target — reading the live row keeps the arm pointed at real
  # bytes across 060 regenerations instead of sed-ing nothing against a reworded table).
  cat <<'EOF'
php/templates/containers.twig|value="Log out"|value="Cerrar sesión"
php/templates/includes/optional-containers.twig|value="Save changes"|value="Guardar cambios"
php/templates/includes/aio-config.twig|Click here to view the current AIO config|Haga clic aquí para ver la configuración actual
php/templates/includes/backup-dirs.twig|An example for Linux is|Un ejemplo para Linux es
php/templates/components/container-state.twig|>Stopped</a>|>Detenido</a>
php/templates/setup.twig|All-in-One setup|Anote la frase de contraseña
php/templates/login.twig|Nextcloud AIO Login|Inicie sesión con su frase de contraseña de
php/templates/already-installed.twig|is already installed|ya está instalado
php/templates/log.twig|>Disable</button>|>Desactivar</button>
php/templates/layout.twig|<html lang="en">|<html lang="es">
php/public/forms.js|Server error. Please check|Error del servidor.
php/public/second-tab-warning.js|Cannot open multiple instances|No se pueden abrir múltiples instancias
php/public/containers-form-submit.js|The docker socket proxy container is deprecated|El contenedor docker socket proxy está obsoleto
php/public/log-load.js|statusElem.textContent = 'enabled';|statusElem.textContent = 'activada';
php/public/click-handlers.js|reveal ? 'Hide passphrase' : 'Show passphrase'|reveal ? 'Ocultar frase de contraseña' : 'Mostrar frase de contraseña'
EOF
}

case "${1:-}" in  # the self-test hooks org L7-2's CI arms drive — print-and-exit, no tree needed
  --swept-files)
    swept_table | cut -d'|' -f1
    exit 0
    ;;
  --sentinel-pair)
    row="$(swept_table | sed -n "${2:?usage: scripts/brand-gate.sh --sentinel-pair N}p")"
    [ -n "$row" ] || die "--sentinel-pair ${2}: no such row in 060's sentinel table (1-$(swept_table | wc -l))"
    printf '%s\n' "$row"
    exit 0
    ;;
esac

TREE="${1:?usage: scripts/brand-gate.sh TREE (the tree to assert, e.g. .)}"
[ -d "$TREE/php" ] || die "'$TREE' does not look like the instalador tree (no php/ in it)"


row 010 "containers.json carries zero upstream registry refs (the generated sed's post-state)" \
  upstream_refs "$TREE/php/containers.json"

row 010 "containers.json carries at least 19 aps-conecta image refs (the floor — the auto-include property grows it, never shrinks it)" \
  fork_ref_floor "$TREE/php/containers.json" 19

row 080 "php/src carries zero upstream registry refs (the 3 string refs swapped: DockerActionManager.php:788, 789, 1111)" \
  upstream_refs "$TREE/php/src"

office_ids_absent() {  # PATH... — zero office-collabora/office-onlyoffice ids (hits print)
  local f hits=0
  for f in "$@"; do
    [ -e "$f" ] || { echo "office_ids_absent: no such path: $f" >&2; return 1; }
    grep -rnHE 'office-collabora|office-onlyoffice' "$f" && hits=$((hits+1))
  done
  [ "$hits" -eq 0 ]
}

collabora_forms_gone() {  # the dictionaries/additional-options forms are gone from the TEMPLATES (hits print).
  # Templates-scoped on purpose: index.php:135-136 passes collabora_dictionaries/collabora_additional_options
  # into the twig context and STAYS byte-identical (zero-PHP rule) — the deleted section was their only consumer.
  local hits=0
  grep -rnHE 'collabora_dictionaries|collabora_additional_options' "$TREE/php/templates" && hits=1
  [ "$hits" -eq 0 ]
}

office_floor() {  # FILE... — the eurooffice surface present in each (patch 050's positive control)
  local f
  for f in "$@"; do
    grep -q 'office-eurooffice' "$f" || { echo "  no eurooffice ref in $f — patch 050 ate the suite's own card" >&2; return 1; }
  done
}

files_absent() {  # PATH... — none may exist (a deletion post-state; survivors print)
  local f
  for f in "$@"; do
    if [ -e "$f" ]; then echo "  still present: $f" >&2; return 1; fi
  done
}


row 050 "the wizard carries zero Collabora/OnlyOffice vendor ids — cards, JS refs, CSS selectors gone from templates and public assets" \
  office_ids_absent "$TREE/php/templates" "$TREE/php/public"

row 050 "the Collabora dictionaries/additional-options forms are gone from the templates (the PHP context pass-through at index.php:135-136 stays, zero-PHP rule)" \
  collabora_forms_gone

row 050 "the eurooffice card is intact — radio id, CSS selector, JS guard all present (the deletion's positive control)" \
  office_floor "$TREE/php/templates/includes/optional-containers.twig" "$TREE/php/public/style.css" "$TREE/php/public/disable-containers.js"

row 050 "the vendor logo assets are gone — img/collabora.svg, img/onlyoffice.svg (dead bytes post-deletion)" \
  files_absent "$TREE/php/public/img/collabora.svg" "$TREE/php/public/img/onlyoffice.svg"

office_overview_disabled() {  # the entrypoint kills the first-party `office` app when EuroOffice is on
  grep -q 'occ app:disable office' "$TREE/Containers/nextcloud/entrypoint.sh"
}

row 100 "the first-party 'office' overview app is disabled whenever the suite's office app is EuroOffice — NC34 ships it enabled by default, unwired to EuroOffice (no editor-url), a name-colliding dead surface; the entrypoint owns the kill so every install and reboot re-asserts it (the 2026-09-23 owner flip of the 2026-07-31 'not a duplicate' verdict)" \
  office_overview_disabled

upstream_changelog_urls_absent() {  # zero upstream changelog/releases URLs in the templates
  # (hits print). 060 repoints the operator-visible "changelog" arms at the fork's own releases
  # — an operator asking "what changed?" must never be sent to upstream's release story.
  local f hits=0
  for f in "$TREE/php/templates"/*.twig "$TREE/php/templates"/includes/*.twig; do
    [ -e "$f" ] || continue
    grep -nHE 'github.com/nextcloud/all-in-one/releases|github.com/nextcloud-releases' "$f" && hits=$((hits+1))
  done
  [ "$hits" -eq 0 ]
}

fork_changelog_present() {  # the positive control: the changelog arms point at the fork's releases
  grep -q 'https://github.com/APS-Conecta/instalador/releases' "$TREE/php/templates/containers.twig"     || { echo "  no APS-Conecta/instalador releases URL in containers.twig — the changelog arms point nowhere" >&2; return 1; }
}

escl_sweep() {  # MODE — walk swept_table's sentinel pairs. absent = the English sentinel must be
  # gone (a lost sweep leaves upstream English in place and reds loudly); present = the
  # es-CL sentinel must be there (a half-applied or mis-regenerated sweep loses a whole FILE —
  # exactly what this canary exists to catch, the 050 ids/floor precedent at row granularity).
  # One sentinel pair per swept file; the sweep's full proof is the patch's own edit points.
  # The table lives in swept_table() above — one writer, three readers (org L7-2).
  # AMENDED WITH SLICE 12 (070's forced extension): the setup and login present-arms pointed at
  # the h1 lines the reskin renames ("Configuración de All-in-One", "Inicio de sesión de
  # Nextcloud AIO") — a sentinel that dies under a later change is a row that reds
  # forever. Both arms point at BODY strings 060 wrote that 070's reskin never touches, so
  # the table holds across the renames; the absent-arms (upstream English) are
  # unaffected by the rename.
  local mode="$1" f en es fail=0
  while IFS='|' read -r f en es; do
    [ -f "$TREE/$f" ] || { echo "escl_sweep: no such file: $f" >&2; return 1; }
    if [ "$mode" = absent ]; then
      if grep -nF "$en" "$TREE/$f" >/dev/null; then
        grep -nF "$en" "$TREE/$f" | head -3 | sed 's/^/  /' >&2
        echo "  English residue in $f — the sweep did not land there" >&2; fail=1
      fi
    else
      grep -qF "$es" "$TREE/$f" || { echo "  no es-CL sentinel in $f — the translation is missing" >&2; fail=1; }
    fi
  done < <(swept_table)
  [ "$fail" -eq 0 ]
}

log_toggle_consistent() {  # the engine's own constraint: log.twig's static toggle labels equal
  # log-load.js's swap labels — a regeneration that rewords one side breaks the log page's
  # enabled/disabled display mid-session (R5's consistency note, made mechanical).
  local t="$TREE/php/templates/log.twig" j="$TREE/php/public/log-load.js"
  grep -q '<span id="autoloading-status">activada</span>' "$t" || { echo "  log.twig's status word drifted" >&2; return 1; }
  grep -q "statusElem.textContent = 'activada';" "$j" || { echo "  log-load.js's enabled word drifted from log.twig's" >&2; return 1; }
  grep -q '<button id="autoloading-control">Desactivar</button>' "$t" || { echo "  log.twig's button label drifted" >&2; return 1; }
  grep -q "button.textContent = 'Desactivar';" "$j" || { echo "  log-load.js's Disable word drifted from log.twig's" >&2; return 1; }
}


row 060 "the operator-visible changelog links point at the fork's releases — zero upstream github.com/nextcloud* changelog URLs in the templates" \
  upstream_changelog_urls_absent

row 060 "the changelog arms land on APS-Conecta/instalador's releases page (the repoint's positive control; AIO was the pre-move home — 2026-10-17)" \
  fork_changelog_present

row 060 "the es-CL sweep left no English on any wizard surface — per-file sentinels gone (15 files: containers, includes, components, small views, public JS)" \
  escl_sweep absent

row 060 "the es-CL sweep landed on every wizard surface — per-file es-CL sentinels present (the sweep's positive control)" \
  escl_sweep present

row 060 "the log page's toggle words agree between twig and JS — log.twig's static labels equal log-load.js's swap labels" \
  log_toggle_consistent

reskin_identity() {  # MODE — walk 070's identity table (the <title>/h1/h2 lockups). absent = upstream's
  # product name must be gone from the identity surface; present = ours must be there. The sweep
  # (060) translated these headings and deliberately kept the upstream product name (its locked
  # keep-list); the reskin (070) renames the identity surfaces — the boundary recorded in the
  # header's "the <title>/h1 swap is the reskin's, not the sweep's". Nominative body copy
  # ("su Nextcloud", the doc links) is deliberately NOT this row's scope: that is slice 23's
  # fork-declaration audit surface, not the identity swap's.
  # AMENDED WITH L4 S2: 130 renames the product to «APS Conecta Gestión AIO», so the present
  # arm checks the «APS Conecta» prefix both names share — 070's own claim — and row 130
  # owns the full name. A sentinel a later patch rewrites is a row that reds forever.
  local mode="$1" f old new fail=0
  while IFS='|' read -r f old new; do
    [ -f "$TREE/$f" ] || { echo "reskin_identity: no such file: $f" >&2; return 1; }
    if [ "$mode" = absent ]; then
      if grep -nF "$old" "$TREE/$f" >/dev/null; then
        grep -nF "$old" "$TREE/$f" | head -3 | sed 's/^/  /' >&2
        echo "  upstream identity residue in $f — the reskin did not land there" >&2; fail=1
      fi
    else
      grep -qF "$new" "$TREE/$f" || { echo "  no APS identity in $f — the rename is missing" >&2; fail=1; }
    fi
  done <<'EOF'
php/templates/layout.twig|<title>AIO</title>|<title>APS Conecta
php/templates/log.twig|<title>AIO</title>|<title>APS Conecta
php/templates/containers.twig|<h1>Nextcloud AIO v|<h1>APS Conecta
php/templates/login.twig|Inicio de sesión de Nextcloud AIO|Inicio de sesión de APS Conecta
php/templates/already-installed.twig|Nextcloud All-In-One ya está instalado|<h2>APS Conecta
php/templates/setup.twig|Configuración de All-in-One|Configuración de APS Conecta
EOF
  [ "$fail" -eq 0 ]
}

dark_mode_gone() {  # the toggle is deleted and nothing can re-apply a stale dark key: zero
  # button/icon refs in templates and CSS, zero [data-theme="dark"] rules left, the toggle
  # script file gone — and the one-shot localStorage clear present in apply-theme.js (the
  # swap that fixes every load surface at once; the PHP heredoc's reference to that file
  # stays byte-identical and inert, so it is excluded by construction like every zero-PHP
  # surface). A stale 'dark' key with the dark rules deleted is inert the moment the new
  # bytes load; the removeItem clears it for every load after that.
  local hits=0
  grep -rnHE 'theme-toggle|theme-icon' "$TREE/php/templates" "$TREE/php/public/style.css" && hits=$((hits+1))
  grep -nHE '\[data-theme="dark"\]' "$TREE/php/public/style.css" && hits=$((hits+1))
  [ -e "$TREE/php/public/toggle-dark-mode.js" ] && { echo "  still present: toggle-dark-mode.js" >&2; hits=$((hits+1)); }
  grep -q "localStorage.removeItem('theme')" "$TREE/php/public/apply-theme.js" \
    || { echo "  the one-shot theme clear is missing from apply-theme.js" >&2; hits=$((hits+1)); }
  [ "$hits" -eq 0 ]
}

reskin_assets_swapped() {  # the wizard's art is the fork's: logo lockup, favicon and background
  # are ours; every upstream asset the reskin replaces is gone. The logo keeps id="logo" (the
  # header and lockup <use> refs) and gains id="wordmark" — a renamed id would render nothing
  # on three views, exactly the class this floor exists to catch. The <use> floor counts ALL
  # refs — 7 across 4 files (the three big views carry #logo + #wordmark each, the containers
  # header carries #logo alone) — so a dropped view (−2) AND a dropped single ref (−1) both red.
  local f n
  for f in "$TREE/php/public/img/logo.svg" "$TREE/php/public/img/favicon.svg" "$TREE/php/public/img/background.svg"; do
    [ -f "$f" ] || { echo "  missing: $f" >&2; return 1; }
  done
  grep -q 'id="logo"' "$TREE/php/public/img/logo.svg" || { echo '  logo.svg lost id="logo" — the <use> refs would render nothing' >&2; return 1; }
  grep -q 'id="wordmark"' "$TREE/php/public/img/logo.svg" || { echo '  logo.svg lost id="wordmark"' >&2; return 1; }
  grep -q 'img/background.svg' "$TREE/php/public/style.css" || { echo "  style.css does not load background.svg" >&2; return 1; }
  files_absent "$TREE/php/public/img/nextcloud-logo.svg" "$TREE/php/public/img/favicon.png" \
    "$TREE/php/public/img/jo-myoung-hee-fluid.webp" "$TREE/php/public/img/jo-myoung-hee-fluid-dark.webp" || return 1
  n="$(grep -ro 'img/logo.svg#' "$TREE/php/templates" | wc -l)"
  [ "$n" -ge 7 ] || { echo "  only $n img/logo.svg# refs in the templates (floor 7 — a dropped view or a dropped ref reds)" >&2; return 1; }
}

reskin_tokens() {  # the :root value table carries the brand tokens (names preserved — the inline
  # SVG and var refs ride them; values swapped per the MAPEO ledger, contrast measured) and the
  # fonts ship as LOCAL subsets — the wizard never fetches a font from anywhere, which is the
  # acquisition gate's install-time rule applied to the wizard's own bytes.
  local css="$TREE/php/public/style.css" fail=0 want
  while IFS= read -r want; do
    grep -qF -e "$want" "$css" || { echo "  token missing from :root: $want" >&2; fail=1; }
  done <<'EOF'
--color-nextcloud-blue: #7f21fe;
--color-main-text: #101828;
--color-border-maxcontrast: #485363;
--color-error: #ea003e;
--color-running: #e06f00;
--color-primary-element: #7f21fe;
--color-primary-element-hover: #6b01fa;
--color-primary-element-light-text: #5315a8;
EOF
  grep -qF 'font-family: "Fraunces";' "$css" || { echo "  the Fraunces @font-face is missing" >&2; fail=1; }
  grep -qF 'font-family: "Nunito Sans";' "$css" || { echo "  the Nunito Sans @font-face is missing" >&2; fail=1; }
  grep -qF 'url("fonts/Fraunces.woff2")' "$css" || { echo "  Fraunces must load the local subset" >&2; fail=1; }
  grep -qF 'url("fonts/NunitoSans.woff2")' "$css" || { echo "  Nunito Sans must load the local subset" >&2; fail=1; }
  if [ ! -f "$TREE/php/public/fonts/Fraunces.woff2" ] || [ ! -f "$TREE/php/public/fonts/NunitoSans.woff2" ]; then
    echo "  the font subset files are missing from php/public/fonts/" >&2; fail=1
  fi
  if grep -nE 'url\(.?https?:|@import' "$css"; then
    echo "  style.css reaches a remote URL — the wizard must ship every byte it renders" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

paso1_card() {  # the handoff card is present — and never a literal URL or port (the locked
  # dynamic-bind decision: the web installer prints its own address at bind time).
  # containers.twig carried no :808x before this patch, so a literal port can only arrive
  # with the card — the absence check is the card's own scope. AMENDED WITH L4 S3: the card's
  # words are 170's («Suite en marcha», `sudo aps-conecta abrir`), so this row keeps the two
  # things 070 still owns — the card and the no-port rule.
  local t="$TREE/php/templates/containers.twig"
  grep -qF 'id="paso-1-card"' "$t" || { echo "  the Paso-1 handoff card is missing" >&2; return 1; }
  if grep -nE ':808[0-9]' "$t"; then
    echo "  a literal provisioner port leaked into containers.twig — the card must show the command only" >&2; return 1
  fi
}


row 070 "the identity lockups name APS Conecta — titles, h1s and the already-installed h2 carry zero upstream product names (the <title>/h1 swap is the reskin's, not the sweep's)" \
  reskin_identity absent

row 070 "the identity swap landed — the APS Conecta name present on every identity surface (130 owns the full product name)" \
  reskin_identity present

row 070 "the dark toggle is gone — button, script, CSS rules and every [data-theme=\"dark\"] block, with the one-shot localStorage clear in apply-theme.js fixing all load surfaces at once" \
  dark_mode_gone

row 070 "the wizard's assets are the fork's — logo.svg (id=\"logo\" + id=\"wordmark\"), favicon.svg and background.svg present; nextcloud-logo.svg, favicon.png and both upstream webp backgrounds deleted" \
  reskin_assets_swapped

row 070 "the token table carries the brand values — primary #7f21fe, ink #101828, muted #485363, error #ea003e, gold running dot; Fraunces and Nunito Sans ship as local subsets with zero remote font URLs" \
  reskin_tokens

row 070 "the handoff card is present — and no literal provisioner port anywhere in containers.twig (170 owns its words)" \
  paso1_card

whitelabel_installed() {  # the renames are COMMITS in the fork's own repo (#36) and no image
  # carries app bytes (#42), so this tree cannot grep them at build time — the clean-boot
  # rehearsal owns the enforcement, grepping the INSTALLED bytes on every run. This row pins
  # that owner to the fork's tree: both served-file pairs (office-smoke.sh:37's exact pairs)
  # must stay in the rehearsal, and the manifest must keep eurooffice source:fork so the
  # store's namesake can never replace it through any channel this repo controls.
  local f="$REPO_ROOT/.github/workflows/cleanboot.yml" m="$REPO_ROOT/apps.json" fail=0
  [ -f "$f" ] || { echo "  the clean-boot workflow is missing — the white-label asserts' owner" >&2; return 1; }
  [ -f "$m" ] || { echo "  no apps.json at the root" >&2; return 1; }
  grep -qF 'grep -qF '"'"'return "Euro-Office";'"'"' /var/www/html/custom_apps/eurooffice/lib/AdminSection.php' "$f" \
    || { echo "  the rehearsal no longer greps the installed AdminSection.php rename" >&2; fail=1; }
  grep -qF "grep -qF '<name>Euro-Office</name>' /var/www/html/custom_apps/eurooffice/appinfo/info.xml" "$f" \
    || { echo "  the rehearsal no longer greps the installed info.xml <name> rename" >&2; fail=1; }
  grep -q '"id": "eurooffice", "source": "fork"' "$m" \
    || { echo "  the manifest no longer declares eurooffice a fork of ours — the store's namesake could arrive through any channel we control" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 030 "the white-label rename is enforced at acceptance — the clean-boot rehearsal greps both served-file pairs in the installed bytes every run, and the manifest keeps eurooffice source:fork (the bake's build-time asserts died with the bake; the renames are commits in the fork's own repo, #36/#42)" \
  whitelabel_installed

suite_escl_present() {  # TREE — the translated suite's positive control: one es-CL sentinel per
  # spec file + helpers (a lost 090 leaves the upstream English assertions in place and
  # reds loudly). The sentinels are measured bytes from the post-060 templates, never typed.
  local t="$1" f s fail=0
  while IFS='|' read -r f s; do
    [ -f "$t/$f" ] || { echo "suite_escl_present: no such file: $f" >&2; return 1; }
    grep -qF "$s" "$t/$f" || { echo "  no es-CL sentinel in $f: $s" >&2; fail=1; }
  done <<'EOF'
php/tests/tests/helpers.js|Abrir el inicio de sesión de
php/tests/tests/initial-setup.spec.js|Enviar dominio
php/tests/tests/initial-setup.spec.js|Los contenedores se están iniciando
php/tests/tests/restore-instance.spec.js|¡El último restore fue exitoso!
php/tests/tests/restore-instance.spec.js|Enviar ubicación y contraseña de cifrado
EOF
  return $fail
}

suite_desec_absent() {  # TREE — 051's consequence, routed to 090: the deSEC flow is gone from the
  # test harness — the 3 dead specs, the mock, and every desec reference in php/tests/.
  local t="$1" f
  for f in php/tests/tests/desec-register.spec.js php/tests/tests/desec-existing.spec.js \
           php/tests/tests/desec-existing-slug.spec.js php/tests/desec-mock.mjs; do
    [ -e "$t/$f" ] && { echo "  dead deSEC file survived: $f" >&2; return 1; }
  done
  if grep -rni "desec" "$t/php/tests/" --include="*" 2>/dev/null | grep -qv "^$t/php/tests/package-lock.json"; then
    grep -rni "desec" "$t/php/tests/" 2>/dev/null | head -3 | sed 's/^/  /' >&2
    echo "  deSEC residue in the test harness" >&2; return 1
  fi
  # the workflow invokers too — run.sh would exit 1 on every dead-spec step (the R1 half-state
  # find: slice 10's referencer list omitted them; this row now owns "every reference" for real)
  if grep -rni "desec\|AIO_TEST_PASSWORD" "$t/.github/workflows/" 2>/dev/null; then
    grep -rni "desec\|AIO_TEST_PASSWORD" "$t/.github/workflows/" | head -3 | sed 's/^/  /' >&2
    echo "  deSEC residue in the workflow invokers" >&2; return 1
  fi
  return 0
}

suite_phpborne_english() {  # TREE — the don't-translate control: the 3 PHP-borne English
  # assertions STAY English (ConfigurationManager.php:619/:689/:1037 — the zero-PHP rule).
  # If a future sweep bleeds into php/src, these specs fail at run time AND this row reds
  # the moment the assertion bytes are "helpfully" translated — the canary for rule drift.
  local t="$1" s fail=0
  for s in "Please enter a domain and not an IP-address!" \
           "The entered timezone does not seem to be a valid timezone!" \
           "Domain does not point to this server or the reverse proxy is not configured correctly."; do
    grep -qF "$s" "$t/php/tests/tests/initial-setup.spec.js" "$t/php/tests/tests/restore-instance.spec.js" \
      || { echo "  PHP-borne English assertion lost: $s" >&2; fail=1; }
  done
  return $fail
}

suite_fork_image() {  # TREE — the dispatch profile pulls the fork's published es-CL image:
  # compose.yaml's app-base repointed at ghcr.io/aps-conecta/all-in-one (research D15: leaving
  # the upstream ref makes code-from-image test upstream English — a silently wrong suite).
  local t="$1"
  grep -q "image: ghcr.io/aps-conecta/all-in-one:develop" "$t/php/tests/compose.yaml" \
    || { echo "  compose.yaml does not pull the fork image" >&2; return 1; }
  upstream_refs "$t/php/tests" && return 0
  return 1
}

row 090 "the translated suite asserts the wizard's es-CL bytes — sentinels per spec + helpers (the 060 sweep's positive control inside the suite)" \
  suite_escl_present "$TREE"
row 090 "the deSEC flow is gone from the test harness — 3 dead specs + the mock + every reference (051's routed consequence)" \
  suite_desec_absent "$TREE"
row 090 "the PHP-borne English assertions stay English — the zero-PHP rule's living proof inside the suite (:619/:689/:1037)" \
  suite_phpborne_english "$TREE"
row 090 "the harness pulls the fork's image — compose.yaml repointed at ghcr.io/aps-conecta/all-in-one, zero upstream refs" \
  suite_fork_image "$TREE"

# ── slice 23: the drift-equality row (the FRD S11 gate: README/twig string equality) ──────

readme_twig_equal() {  # the fork declaration (main's readme.md) quotes the wizard's shipped
  # bytes — docs assert what exists. Each pair is QUOTE|TREE-FILE: the string must byte-exist
  # in the declaration AND in the named file of the tree. A drift on either side —
  # a 070 regeneration that rewords the wizard, or a hand-edit that rewords the declaration —
  # reds naming the string. The two ConfigurationManager examples are the 68-list's own
  # quotes: they assert the stay-English canaries from the README side (the 090 suite row
  # guards three of them from the suite side; these two are the declaration's documentation
  # staying true to php/src's bytes).
  local fail=0 q f
  while IFS='|' read -r q f; do
    grep -qF "$q" "$REPO_ROOT/readme.md" \
      || { echo "  the fork declaration no longer quotes: $q" >&2; fail=1; }
    grep -qF "$q" "$TREE/$f" \
      || { echo "  $f does not carry the declared string: $q" >&2; fail=1; }
  done <<'EOF'
APS Conecta Gestión AIO — Instalador|php/templates/layout.twig
APS Conecta Gestión AIO — Instalador|php/templates/log.twig
APS Conecta Gestión AIO ya está instalado|php/templates/already-installed.twig
Suite en marcha|php/templates/containers.twig
Please enter a domain and not an IP-address!|php/src/Data/ConfigurationManager.php
The entered timezone does not seem to be a valid timezone!|php/src/Data/ConfigurationManager.php
EOF
  [ "$fail" -eq 0 ]
}

row 070 "the fork declaration quotes the wizard's shipped bytes — every declared string byte-exists in the tree and in readme.md (the S11 drift gate: docs assert what exists)" \
  readme_twig_equal

# ── L4 S2: the identity (R21 fonts, R20 lockup, R19 product name) ─────────────────────────────

csp_fonts_self() {  # 110: the wizard's CSP lets its own brand fonts load. Matched on the real
  # header line: the comment block above it names every directive in prose, so a file-wide grep
  # would pass on a comment. default-src stays 'none'; no font source wider than the origin.
  local f="$TREE/Containers/mastercontainer/headers.Caddyfile" line
  line="$(grep -E '^[[:space:]]*Content-Security-Policy ' "$f")" \
    || { echo "  no Content-Security-Policy line in headers.Caddyfile" >&2; return 1; }
  case "$line" in *"default-src 'none';"*) ;; *) echo "  the CSP lost default-src 'none'" >&2; return 1 ;; esac
  case "$line" in *"font-src 'self';"*) ;; *) echo "  the CSP blocks the wizard's own fonts (no font-src 'self')" >&2; return 1 ;; esac
  if printf '%s\n' "$line" | grep -qE "font-src[^;]*([*]|data:|https?:)"; then
    echo "  font-src reaches beyond the wizard's own origin" >&2; return 1
  fi
}

lockup_outlines() {  # 120: the banner lockup's wordmark is outlines. A <use> clone cannot carry fonts
  # embedded in logo.svg, so live text fell back to whatever the page loaded (R20); outlines need
  # no font at all. The ids the templates <use> stay, the accessible name is the product's, and
  # the authoring tool that draws the outlines stays on main.
  local f="$TREE/php/public/img/logo.svg"
  grep -q 'id="logo"' "$f" || { echo '  logo.svg lost id="logo"' >&2; return 1; }
  grep -q 'id="wordmark"' "$f" || { echo '  logo.svg lost id="wordmark"' >&2; return 1; }
  if grep -nE '<text|@font-face|data:font' "$f"; then
    echo "  the lockup still depends on a font" >&2; return 1
  fi
  [ "$(sed -n '/<g id="wordmark">/,/<\/g>/p' "$f" | grep -c '<path ')" -ge 2 ] \
    || { echo "  the wordmark has fewer than its two outline lines" >&2; return 1; }
  grep -qF 'aria-label="APS Conecta Gestión AIO"' "$f" \
    || { echo "  logo.svg's accessible name is not the product name" >&2; return 1; }
  [ -f "$REPO_ROOT/scripts/lockup.py" ] || { echo "  scripts/lockup.py, the lockup's authoring tool, is missing" >&2; return 1; }
}

product_name() {  # 130: «APS Conecta Gestión AIO» on every operator surface (R19). The identity
  # strings, the APS sentence, the buttons and the logo fallback present, the suite's own login
  # link asserted by the test helper, and no «APS Conecta
  # AIO», «Nextcloud AIO» or «All-in-One» left in any text file the wizard serves or renders. Row 170 owns the
  # suite's naming in the page's prose.
  local f s fail=0
  while IFS='|' read -r f s; do
    grep -qF "$s" "$TREE/$f" || { echo "  $f does not carry: $s" >&2; fail=1; }
  done <<'EOF'
php/templates/layout.twig|<title>APS Conecta Gestión AIO — Instalador</title>
php/templates/log.twig|<title>APS Conecta Gestión AIO — Instalador</title>
php/templates/containers.twig|<h1>APS Conecta Gestión AIO
php/templates/setup.twig|<h1>Configuración de APS Conecta Gestión AIO</h1>
php/templates/login.twig|<h1>Inicio de sesión de APS Conecta Gestión AIO</h1>
php/templates/already-installed.twig|<h2>APS Conecta Gestión AIO ya está instalado</h2>
php/tests/tests/helpers.js|Abrir el inicio de sesión de APS Conecta Gestión AIO ↗
php/templates/setup.twig|Instala y mantiene APS Conecta Gestión en este servidor
php/templates/containers.twig|Instala y mantiene APS Conecta Gestión en este servidor
php/templates/containers.twig|de su instancia de APS Conecta Gestión AIO,
php/templates/already-installed.twig|>Abrir APS Conecta Gestión AIO</a>
php/templates/setup.twig|Logotipo de APS Conecta Gestión</text>
php/templates/login.twig|Logotipo de APS Conecta Gestión</text>
php/templates/already-installed.twig|Logotipo de APS Conecta Gestión</text>
EOF
  if grep -rnIE 'APS Conecta AIO|Nextcloud AIO|All-in-One|All-In-One' "$TREE/php/templates" "$TREE/php/public"; then
    echo "  an upstream or pre-Gestión product name survives on a wizard surface" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 110 "the wizard's CSP lets its own brand fonts load — font-src 'self' on the real header line, default-src still 'none', no wider font source (R21)" \
  csp_fonts_self

row 120 "the banner lockup is outlines — no text, no embedded font, two outline lines in the wordmark, the product name as its accessible name, the authoring tool on main (R20)" \
  lockup_outlines

row 130 "the product name is APS Conecta Gestión AIO on every operator surface — titles, headings, the setup link the suite clicks, and no upstream or pre-Gestión name left (R19)" \
  product_name

# ── L4 S3: the wizard page (R23 links, R24 defaults, R25 page choices, R27 post-start, phones) ──

s3_files() {  # PATH... — every file an S3 row reads must exist: a negative arm over a moved file
  # would pass vacuously (grep's «no such file» reads as «no hit»)
  local f fail=0
  for f in "$@"; do [ -f "$f" ] || { echo "  no such file: $f — re-point this row" >&2; fail=1; }; done
  [ "$fail" -eq 0 ]
}

help_links_ours() {  # 140: every help link the wizard renders goes to the suite's own docs, or is
  # gone (R23). No URL of upstream's GitHub, Nextcloud's sites or the App API repo in any
  # template or public text file — links and twig comments alike; the container list no longer
  # renders containers.json's upstream documentation URLs; the platform examples the suite never
  # runs on are gone; and each section of the suite's docs (instalador/aps) the links were
  # mapped to is linked (the positive control).
  local t="$TREE/php/templates" fail=0 a
  s3_files "$t/components/container-state.twig" "$t/includes/backup-dirs.twig" || return 1
  if grep -rnIE 'github\.com/(nextcloud|nextcloud-releases|cloud-py-api)/|([a-z0-9-]+\.)*nextcloud\.(com|org)|nextcloud\.github\.io' "$t" "$TREE/php/public"; then
    echo "  an upstream URL survives on a wizard surface" >&2; fail=1
  fi
  if grep -n 'c.documentation' "$t/components/container-state.twig"; then
    echo "  the container list still renders containers.json's upstream documentation links" >&2; fail=1
  fi
  if grep -nE 'Synology|macOS|Windows' "$t/includes/backup-dirs.twig"; then
    echo "  backup-dirs.twig still offers platforms the suite does not run on" >&2; fail=1
  fi
  for a in INSTALLER.md#3-preflight INSTALLER.md#7-dns-the-host-must-reach-its-own-domain-d10 \
           INSTALLER.md#11-backups INSTALLER.md#12-troubleshooting GUIA-CLINICA.md#3-el-asistente-8080; do
    grep -rqF "https://github.com/APS-Conecta/instalador/blob/main/aps/$a" "$t" \
      || { echo "  no link to the suite's docs (instalador/aps)/$a" >&2; fail=1; }
  done
  [ "$fail" -eq 0 ]
}

row 140 "every help link on the wizard goes to the suite's own docs or is gone — no upstream GitHub, Nextcloud site or App API URL, no per-container upstream documentation link, no Synology/macOS/Windows examples, each mapped suite doc section (instalador/aps) linked (R23)" \
  help_links_ours

aps_defaults() {  # 150: the wizard proposes the suite's own values (R24) — America/Santiago, the
  # backup folder under /srv/aps-conecta (a value, so accepting the default is one click), a
  # gestion domain pattern — and none of upstream's examples is left.
  local t="$TREE/php/templates" fail=0 f s
  s3_files "$t/containers.twig" "$t/includes/backup-dirs.twig" || return 1
  while IFS='|' read -r f s; do
    grep -qF "$s" "$t/$f" || { echo "  $f does not carry: $s" >&2; fail=1; }
  done <<'EOF'
containers.twig|placeholder="gestion.su-establecimiento.cl"
containers.twig|id="borg_backup_host_location" name="borg_backup_host_location" value="/srv/aps-conecta/respaldos"
containers.twig|<input type="text" id="timezone" name="timezone" value="America/Santiago" />
containers.twig|placeholder="/opt/aps-conecta"
includes/backup-dirs.twig|<strong>/srv/aps-conecta/respaldos</strong>
EOF
  if grep -rnE '/mnt/backup|Europe/Berlin|nextcloud\.yourdomain\.com|/directory/on/the/host|my_custom_docker_volume' "$t"; then
    echo "  an upstream example survives in the wizard" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 150 "the wizard proposes the suite's values — America/Santiago, /srv/aps-conecta/respaldos, a gestion domain pattern — and no upstream example is left (R24)" \
  aps_defaults

page_choices() {  # 160: the page offers only what the suite ships (R25, its template part): the
  # baked Nextcloud Hub (no newer-major checkbox, no upgrade note), the suite's version — its
  # image tag — in the heading instead of upstream AIO's, the office card named for what it is
  # with no comparison against the removed cards, the deprecated docker socket proxy and HaRP
  # hidden while off (an instance that has one on still sees it, so it can be unchecked — a
  # hidden checked box would re-save itself forever), and no «mastercontainer» jargon in any
  # template's or script's prose (the asistente, as the docs call it; ids and commands
  # keep the container's real name). The server-side refusals are the acquisition gate's (190, 200).
  local c="$TREE/php/templates/containers.twig" o="$TREE/php/templates/includes/optional-containers.twig" fail=0 id v
  s3_files "$c" "$o" "$TREE/php/public/forms.js" || return 1
  grep -qF "{% set newMajorVersionString = '' %}" "$c" || { echo "  the Hub major-version choice is still offered" >&2; fail=1; }
  grep -qF '<h1>APS Conecta Gestión AIO {{ current_channel }}</h1>' "$c" || { echo "  the heading does not show the suite version" >&2; fail=1; }
  if grep -n 'aio-version.twig' "$c"; then echo "  the heading still reads upstream AIO's version" >&2; fail=1; fi
  grep -qF '<h4>Oficina</h4>' "$o" || { echo "  the office card is not titled Oficina" >&2; fail=1; }
  if grep -nE 'Nextcloud Office|Mejor rendimiento|Compatibilidad ODF limitada|Mejor compatibilidad con Microsoft' "$o"; then
    echo "  the office card still names or compares against upstream's suites" >&2; fail=1
  fi
  for id in docker-socket-proxy:docker_socket_proxy harp:harp; do
    v="${id#*:}"; id="${id%%:*}"
    tr -d '\n' < "$o" | grep -qE "<p\{% if is_${v}_enabled != true %\} hidden\{% endif %\}> *<input +type=\"checkbox\" +id=\"$id\"" \
      || { echo "  the $id option is not hidden-while-off" >&2; fail=1; }
  done
  if grep -rnE '(^|[^-_[:alnum:]])mastercontainer([^-_[:alnum:]]|$)' "$TREE/php/templates" "$TREE/php/public"/*.js | grep -v '{#'; then
    echo "  «mastercontainer» jargon survives in the wizard's prose" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 160 "the page offers only what the suite ships — no Hub major-version choice, the suite version in the heading, the office card titled Oficina, the docker socket proxy and HaRP hidden while off, no mastercontainer jargon (R25, its template part)" \
  page_choices

post_start_page() {  # 170: after start the page says only true, APS things (R27): the suite's
  # update path instead of the no-channel alarm (a pinned suite tag IS the design), «Suite en
  # marcha» naming what the web installer does next instead of the Paso-1 and territorio cards,
  # no docker prune button (the route stays — zero PHP), and the suite's names on the
  # credentials, the open button, the container list and the page's prose — with the translated
  # suite asserting the bytes it clicks. «Nextcloud» stays only where the page hides it: the
  # Hub-upgrade block (160 empties its switch), the docker socket proxy and HaRP options and the
  # JS alert behind them (160 hides them while off).
  local c="$TREE/php/templates/containers.twig" j="$TREE/php/containers.json" s="$TREE/php/tests/tests" fail=0 want
  s3_files "$c" "$j" "$s/initial-setup.spec.js" "$s/restore-instance.spec.js" || return 1
  while IFS= read -r want; do
    grep -qF "$want" "$c" || { echo "  containers.twig does not carry: $want" >&2; fail=1; }
  done <<'EOF'
https://github.com/APS-Conecta/instalador/blob/main/aps/GUIA-CLINICA.md#7-tras-actualizar
<h2>Suite en marcha</h2>
<code>sudo aps-conecta abrir</code>
<p>Contraseña inicial de APS Conecta Gestión: <strong id="initial-nextcloud-password">
>Abrir APS Conecta Gestión ↗</a>
EOF
  if grep -nE 'No se encontró ningún canal|territorio-card|pendiente de empaquetado|aps-conecta provision' "$c"; then
    echo "  a false or stale statement survives on the post-start page" >&2; fail=1
  fi
  if grep -rn 'Nextcloud' "$TREE/php/templates" "$TREE/php/public"/*.js \
      | grep -v -e '{#' \
      | sed -e 's/Nextcloud Hub//g' -e 's/Nextcloud App API//g' -e 's/ExApps de Nextcloud//g' | grep 'Nextcloud'; then
    echo "  «Nextcloud» survives in the wizard's prose" >&2; fail=1
  fi
  if grep -rn 'api/docker/prune' "$TREE/php/templates"; then echo "  the docker prune button is still offered" >&2; fail=1; fi
  grep -qF "name: 'Abrir APS Conecta Gestión ↗'" "$s/initial-setup.spec.js" || { echo "  initial-setup.spec.js clicks a button the page no longer has" >&2; fail=1; }
  grep -qF "name: 'Abrir APS Conecta Gestión ↗'" "$s/restore-instance.spec.js" || { echo "  restore-instance.spec.js clicks a button the page no longer has" >&2; fail=1; }
  grep -qF "Contraseña inicial de APS Conecta Gestión:" "$s/initial-setup.spec.js" || { echo "  initial-setup.spec.js waits for a label the page no longer has" >&2; fail=1; }
  for want in 'Servidor de aplicaciones' Talk 'Grabador de Talk' Euro-Office Whiteboard Collabora; do
    grep -qF "\"display_name\": \"$want\"" "$j" || { echo "  containers.json lacks the display name $want" >&2; fail=1; }
  done
  if grep -nE '"display_name": "(Nextcloud|EuroOffice|Nextcloud Talk|Nextcloud Talk Recording|Nextcloud Whiteboard|Nextcloud Office)"' "$j"; then
    echo "  an upstream container name survives in the list" >&2; fail=1
  fi
  [ "$fail" -eq 0 ]
}

row 170 "the post-start page says only true, APS things — the update path, «Suite en marcha», no territorio card, no docker prune button, the suite's names on the credentials, the open button, the container list and the prose, and the suite asserting the same bytes (R27)" \
  post_start_page

phone_layout() {  # 180: the wizard fits a 360px phone. layout.twig declares the viewport (only
  # containers.twig's <head> stub inside its body block and log.twig did), the setup/login card
  # flows under 640px instead of floating at a fixed 500px, and both stylesheet links carry the
  # new cache key so a warm cache cannot serve the old sheet.
  local t="$TREE/php/templates" css="$TREE/php/public/style.css" fail=0 block
  s3_files "$t/layout.twig" "$t/log.twig" "$t/containers.twig" "$css" || return 1
  grep -qF '<meta name="viewport" content="width=device-width, initial-scale=1.0"/>' "$t/layout.twig" \
    || { echo "  layout.twig declares no viewport" >&2; fail=1; }
  if grep -n '<head>' "$t/containers.twig"; then echo "  containers.twig still carries a <head> stub in its body" >&2; fail=1; fi
  block="$(sed -n '/^@media only screen and (max-width: 640px) {/,/^}/p' "$css" | sed -n '/^    \.login {/,/^    }/p')"
  case "$block" in *"position: static;"*"transform: none;"*"width: auto;"*) ;;
    *) echo "  style.css has no 640px rule letting the login card flow" >&2; fail=1 ;; esac
  grep -qF 'href="style.css?v16"' "$t/layout.twig" || { echo "  layout.twig still links the old stylesheet key" >&2; fail=1; }
  grep -qF 'href="style.css?v16"' "$t/log.twig" || { echo "  log.twig still links the old stylesheet key" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 180 "the wizard fits a 360px phone — the viewport declared, the login card flowing under 640px, the stylesheet's cache key bumped" \
  phone_layout

# ── L4 S5: the container names (D9) ──────────────────────────────────────────────────────────

container_names() {  # 240: the suite's 19 containers are aps-conecta-*, and no swept file names one the old
  # way. The keep-list is the generator's, restated here on purpose: a gate that imported it would agree
  # with any mistake in it.
  local j="$TREE/php/containers.json" fail=0 n left x
  [ -f "$j" ] || { echo "  no such file: $j" >&2; return 1; }
  if grep -nF '"container_name": "nextcloud-aio-' "$j"; then
    echo "  containers.json still names a container nextcloud-aio-*" >&2; fail=1
  fi
  n="$(grep -cF '"container_name": "aps-conecta-' "$j")"
  [ "$n" -ge 19 ] || { echo "  only $n aps-conecta container names in containers.json (floor 19)" >&2; fail=1; }
  for x in php/src php/public php/templates php/tests Containers community-containers; do
    [ -d "$TREE/$x" ] || { echo "  no such directory: $TREE/$x — the sweep would pass over nothing" >&2; return 1; }
  done
  # [a-z0-9-]*: a bare prefix (a filter or a str_starts_with on «nextcloud-aio-») is a miss too
  left="$(cd "$TREE" && grep -rhoE --exclude='*.md' 'nextcloud-aio-[a-z0-9-]*' php/containers.json php/src php/public \
            php/templates php/tests Containers community-containers \
          | sort -u | grep -vxE 'nextcloud-aio-(mastercontainer|mastercontainer-tests|test|rundeps|makemkv)')"
  [ -z "$left" ] || { echo "  old names left in the swept files: $(echo "$left" | tr '\n' ' ')" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 240 'the suite containers are named aps-conecta-* — the 19 in containers.json and every reference in php/, Containers/ and the community JSONs; only the kept names stay nextcloud-aio-* (the mastercontainer, the test project, the apk virtual package, the npm name, the dead makemkv check)' \
  container_names

# shellcheck disable=SC2016  # the PHP and JS lines are matched as bytes; $id is their text, not ours
container_name_patterns() {  # 240: what matches containers by pattern follows the new names — the
  # entrypoint's office and Talk detection (a miss reads the suite's own host as external), the schema the
  # validator holds every JSON to, and the log route's three guards, which still let the wizard's own log in
  local e="$TREE/Containers/nextcloud/entrypoint.sh" sch="$TREE/php/containers-schema.json" fail=0 x
  local run="$TREE/php/tests/run.sh"
  for x in "$e" "$sch" "$TREE/php/public/index.php" "$TREE/php/public/log-load.js" \
           "$TREE/php/src/Controller/DockerController.php" "$run"; do
    [ -f "$x" ] || { echo "  no such file: $x — re-point this row" >&2; return 1; }
  done
  if grep -nF 'grep -q "nextcloud-.*-' "$e"; then
    echo "  the entrypoint still detects the suite's hosts by the old pattern" >&2; fail=1
  fi
  for x in collabora:1 onlyoffice:2 eurooffice:2 talk:1; do
    [ "$(grep -cF "grep -q \"aps-conecta-${x%%:*}\"" "$e")" -eq "${x#*:}" ] \
      || { echo "  the entrypoint does not detect aps-conecta-${x%%:*} ${x#*:} time(s)" >&2; fail=1; }
  done
  grep -qF '"pattern": "^aps-conecta-[a-z0-9-]+$"' "$sch" \
    || { echo "  the schema does not require aps-conecta container names" >&2; fail=1; }
  grep -qF '"pattern": "^aps-conecta-[a-z-]+$"' "$sch" \
    || { echo "  the schema does not require aps-conecta dependencies" >&2; fail=1; }
  grep -qF "if (!str_starts_with(\$id, 'aps-conecta-') && \$id !== 'nextcloud-aio-mastercontainer') {" "$TREE/php/public/index.php" \
    || { echo "  index.php's log route does not take aps-conecta-* and the mastercontainer" >&2; fail=1; }
  grep -qF "!(id.startsWith('aps-conecta-') || id === 'nextcloud-aio-mastercontainer')" "$TREE/php/public/log-load.js" \
    || { echo "  log-load.js does not take aps-conecta-* and the mastercontainer" >&2; fail=1; }
  grep -qF "if (str_starts_with(\$id, 'aps-conecta-') || \$id === 'nextcloud-aio-mastercontainer') {" "$TREE/php/src/Controller/DockerController.php" \
    || { echo "  DockerController's log route does not take aps-conecta-* and the mastercontainer" >&2; fail=1; }
  { grep -qF 'nextcloud-aio-mastercontainer aps-conecta-{apache,' "$run" \
      && grep -qF 'for container in nextcloud-aio-mastercontainer aps-conecta-borgbackup; do' "$run"; } \
    || { echo "  the test harness's name lists (run.sh) do not name aps-conecta-* and the mastercontainer" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 240 'what matches containers by pattern follows the new names — the six entrypoint host checks, the two schema patterns, the three log-route guards (the mastercontainer still allowed), both name lists in the test harness' \
  container_name_patterns

# ── L4 S6: the install by IP over HTTPS (R22) ──────────────────────────────────────────────────

# shellcheck disable=SC2016  # the PHP and spec lines are matched as bytes; $domain is theirs, not ours
ip_when_skipped() {  # 233: an IP is a valid domain while domain validation is skipped — the suite's install
  # by IP over HTTPS with the installer's own certificate (R22, declared PHP). With validation on an IP is
  # still refused, and the suite asserts that in restore-instance; initial-setup skips validation, so its
  # old IP-refusal step is gone.
  local m="$TREE/php/src/Data/ConfigurationManager.php" t="$TREE/php/tests/tests" fail=0
  s3_files "$m" "$t/initial-setup.spec.js" "$t/restore-instance.spec.js" || return 1
  grep -A1 -F 'if(filter_var($domain, FILTER_VALIDATE_IP) && !$this->shouldDomainValidationBeSkipped($skipDomainValidation)) {' "$m" \
    | grep -qF 'throw new InvalidSettingConfigurationException("Please enter a domain and not an IP-address!");' \
    || { echo "  setDomain does not refuse an IP only while domain validation is on" >&2; fail=1; }
  if grep -nF 'if(filter_var($domain, FILTER_VALIDATE_IP)) {' "$m"; then
    echo "  setDomain still refuses every IP" >&2; fail=1
  fi
  if grep -nF "fill('1.1.1.1')" "$t/initial-setup.spec.js"; then
    echo "  initial-setup.spec.js still expects an IP refused while it skips validation" >&2; fail=1
  fi
  grep -A2 -F "fill('1.1.1.1')" "$t/restore-instance.spec.js" \
    | grep -qF "toContainText('Please enter a domain and not an IP-address!')" \
    || { echo "  restore-instance.spec.js does not assert the IP refusal with validation on" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 233 'an IP is accepted as the domain only while domain validation is skipped — the install by IP over HTTPS (R22, declared PHP); with validation on it is refused, and the suite asserts that in restore-instance' \
  ip_when_skipped

# shellcheck disable=SC2016  # the shell, PHP and Caddyfile lines are matched as bytes
installer_certificate() {  # 235: apache serves the installer's own certificate when one is mounted (R22).
  # APS_TLS_DIR binds read-only at /aps-tls into apache alone (empty: no bind, as upstream; the
  # mastercontainer refuses a relative path). start.sh writes the file certificate and default_sni — a
  # client by IP sends no SNI — only on 443 with both files readable, else upstream's ACME stanza, whole.
  # The routes sit in a snippet both site blocks import: a file-certificate site cannot share a block with
  # the plain :23973 address. The tls placeholder is the site block's last line, after its import and
  # before the file's closing brace; the default_sni one sits before the snippet (the global options).
  # «auto_https» and «ADDITIONAL_TRUSTED_DOMAIN» stay on one line each: start.sh rewrites every line
  # matching the first and deletes every line naming the second when it is empty.
  local j="$TREE/php/containers.json" f="$TREE/php/src/ContainerDefinitionFetcher.php" \
        m="$TREE/php/src/Data/ConfigurationManager.php" mc="$TREE/Containers/mastercontainer/start.sh" \
        c="$TREE/Containers/apache/Caddyfile" s="$TREE/Containers/apache/start.sh" fail=0 nr ni nt ns
  s3_files "$j" "$f" "$m" "$mc" "$c" "$s" || return 1
  case "$(sed -n '/"container_name": "aps-conecta-apache"/,/"container_name": /p' "$j" | tr -d ' \n')" in
    *'"source":"%APS_TLS_DIR%","destination":"/aps-tls","writeable":false'*) ;;
    *) echo "  containers.json does not bind APS_TLS_DIR read-only at /aps-tls into apache" >&2; fail=1 ;;
  esac
  [ "$(grep -cF '"%APS_TLS_DIR%"' "$j")" -eq 1 ] || { echo "  APS_TLS_DIR is bound into another container too" >&2; fail=1; }
  grep -A1 -F "} elseif (\$value['source'] === '%APS_TLS_DIR%') {" "$f" | grep -qF '$this->configurationManager->apsTlsDir;' \
    || { echo "  ContainerDefinitionFetcher does not resolve %APS_TLS_DIR%" >&2; fail=1; }
  grep -qF "get => \$this->getEnvironmentalVariableOrConfig('APS_TLS_DIR', 'aps_tls_dir', '');" "$m" \
    || { echo "  ConfigurationManager does not read APS_TLS_DIR" >&2; fail=1; }
  grep -qF 'if [ -n "$APS_TLS_DIR" ]; then' "$mc" || { echo "  the mastercontainer does not check APS_TLS_DIR" >&2; fail=1; }
  nr="$(grep -nxF '(aps_routes) {' "$c" | cut -d: -f1)"
  ni="$(grep -nxF '    import aps_routes' "$c" | tail -1 | cut -d: -f1)"
  nt="$(grep -nxF '    # tls placeholder' "$c" | cut -d: -f1)"
  ns="$(grep -nxF '    # default_sni placeholder' "$c" | cut -d: -f1)"
  { [ "$(grep -cxF '    import aps_routes' "$c")" -eq 2 ] && [ -n "$nr" ]; } \
    || { echo "  the Caddyfile's routes are not one snippet imported by both blocks" >&2; fail=1; }
  { [ -n "$nt" ] && [ -n "$ni" ] && [ "$nt" -gt "$ni" ] && [ "$nt" -eq "$(( $(wc -l < "$c") - 1 ))" ] \
      && [ "$(tail -n 1 "$c")" = '}' ]; } \
    || { echo "  the Caddyfile's tls placeholder is missing or outside the site block" >&2; fail=1; }
  { [ -n "$ns" ] && [ -n "$nr" ] && [ "$ns" -lt "$nr" ]; } \
    || { echo "  the Caddyfile's default_sni placeholder is missing or outside the global options" >&2; fail=1; }
  [ "$(grep -c 'auto_https' "$c")" -eq 1 ] || { echo "  a second Caddyfile line names auto_https — start.sh would rewrite it" >&2; fail=1; }
  [ "$(grep -c 'ADDITIONAL_TRUSTED_DOMAIN' "$c")" -eq 1 ] \
    || { echo "  a second Caddyfile line names ADDITIONAL_TRUSTED_DOMAIN — start.sh would delete it" >&2; fail=1; }
  if grep -nF 'issuer acme' "$c"; then echo "  the Caddyfile still hard-codes the ACME issuer" >&2; fail=1; fi
  { grep -qF "if [ \"\$APACHE_PORT\" = '443' ] && [ -r /aps-tls/tls.crt ] && [ -r /aps-tls/tls.key ]; then" "$s" \
      && grep -qF "TLS_STANZA='tls /aps-tls/tls.crt /aps-tls/tls.key'" "$s" \
      && grep -qF 'DEFAULT_SNI="default_sni $NC_DOMAIN"' "$s" \
      && grep -qF "TLS_STANZA='tls {\n\t\tissuer acme {\n\t\t\tprofile shortlived\n\t\t\tdisable_http_challenge\n\t\t}\n\t}'" "$s" \
      && grep -qxF "    DEFAULT_SNI=''" "$s" \
      && grep -qF -e '-e "s|# tls placeholder|$TLS_STANZA|" -e "s|# default_sni placeholder|$DEFAULT_SNI|"' "$s"; } \
    || { echo "  apache's start.sh does not choose the certificate (the file on 443 with both files, else upstream's ACME stanza)" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 235 "apache serves the installer's own certificate when one is mounted — APS_TLS_DIR bound read-only into apache alone, the file certificate and default_sni on 443 with both files, else upstream's ACME stanza; the routes one snippet (R22, declared PHP: the setting and its bind)" \
  installer_certificate

harness_reset_eurooffice() {  # 237: the suite harness's reset removes Euro-Office too. It is always on
  # (patch 200): a running one survived the reset and locked the next fresh wizard's options (S5).
  local run="$TREE/php/tests/run.sh"
  s3_files "$run" || return 1
  { grep -F 'docker container rm --force' "$run" | grep -qF ',collabora,eurooffice,borgbackup}' \
      && grep -F 'docker volume rm' "$run" | grep -qF ',elasticsearch,eurooffice,eurooffice_data}'; } \
    || { echo "  run.sh's reset does not remove the Euro-Office container and its two volumes" >&2; return 1; }
}

row 237 "the suite harness's reset removes the Euro-Office container and its two volumes — always on, a running one locked the next wizard's options" \
  harness_reset_eurooffice

push_internal_url() {  # 238: the push server reaches Nextcloud over apache's internal plain-http listener, not the
  # public URL. By IP (R22) the public URL carries the installer's certificate, which the push container
  # cannot verify (no CA there; overwrite.cli.url is rewritten on every boot); by domain it saves the
  # hairpin. The listener is the one Collabora's alias already uses (row 235 pins the block).
  local j="$TREE/php/containers.json"
  s3_files "$j" || return 1
  case "$(sed -n '/"container_name": "aps-conecta-notify-push"/,/"container_name": /p' "$j" | tr -d ' \n')" in
    *'"NEXTCLOUD_URL=http://aps-conecta-apache.nextcloud-aio:23973",'*) ;;
    *) echo "  the push server is not pointed at apache's internal listener" >&2; return 1 ;;
  esac
  [ "$(grep -cF 'NEXTCLOUD_URL=http://aps-conecta-apache.nextcloud-aio:23973' "$j")" -eq 1 ] \
    || { echo "  the internal listener is set as NEXTCLOUD_URL on another container too" >&2; return 1; }
}

row 238 "the push server reaches Nextcloud over apache's internal plain-http listener — no certificate to verify by IP, no hairpin by domain (R22)" \
  push_internal_url

# shellcheck disable=SC2016  # the shell, PHP and Caddyfile lines are matched as bytes
tiles_route() {  # 239: apache serves the suite's basemap same-origin at /tiles/ (R49). APS_TILES_DIR binds
  # read-only at /aps-tiles into apache alone (empty: no bind, and /tiles/ is a 404; the mastercontainer
  # refuses a relative path). The route sits in the snippet both site blocks import, ahead of the
  # Nextcloud catch-all: behind it, /tiles/ would be proxied to Nextcloud and the archive never served.
  # The block is pinned whole — strip the prefix, root at the mount, no-cache, file_server (Range, ETag):
  # a try_files or a proxy inside it would hand a missing archive to Nextcloud.
  local j="$TREE/php/containers.json" f="$TREE/php/src/ContainerDefinitionFetcher.php" \
        m="$TREE/php/src/Data/ConfigurationManager.php" mc="$TREE/Containers/mastercontainer/start.sh" \
        c="$TREE/Containers/apache/Caddyfile" fail=0 nr nt nn ne want
  s3_files "$j" "$f" "$m" "$mc" "$c" || return 1
  case "$(sed -n '/"container_name": "aps-conecta-apache"/,/"container_name": /p' "$j" | tr -d ' \n')" in
    *'"source":"%APS_TILES_DIR%","destination":"/aps-tiles","writeable":false'*) ;;
    *) echo "  containers.json does not bind APS_TILES_DIR read-only at /aps-tiles into apache" >&2; fail=1 ;;
  esac
  [ "$(grep -cF '"%APS_TILES_DIR%"' "$j")" -eq 1 ] || { echo "  APS_TILES_DIR is bound into another container too" >&2; fail=1; }
  grep -A1 -F "} elseif (\$value['source'] === '%APS_TILES_DIR%') {" "$f" | grep -qF '$this->configurationManager->apsTilesDir;' \
    || { echo "  ContainerDefinitionFetcher does not resolve %APS_TILES_DIR%" >&2; fail=1; }
  grep -qF "get => \$this->getEnvironmentalVariableOrConfig('APS_TILES_DIR', 'aps_tiles_dir', '');" "$m" \
    || { echo "  ConfigurationManager does not read APS_TILES_DIR" >&2; fail=1; }
  grep -qF 'if [ -n "$APS_TILES_DIR" ]; then' "$mc" || { echo "  the mastercontainer does not check APS_TILES_DIR" >&2; fail=1; }
  nr="$(grep -nxF '(aps_routes) {' "$c" | cut -d: -f1)"
  nt="$(grep -nxF '    route /tiles/* {' "$c" | cut -d: -f1)"
  nn="$(grep -nxF '    route {' "$c" | cut -d: -f1)"
  ne="$(awk -v r="$nr" 'NR > r && $0 == "}" { print NR; exit }' "$c")"
  { [ "$(grep -cxF '    route /tiles/* {' "$c")" -eq 1 ] && [ "$(grep -cxF '    route {' "$c")" -eq 1 ] \
      && [ -n "$nr" ] && [ -n "$nt" ] && [ -n "$nn" ] && [ -n "$ne" ] && [ "$nr" -lt "$nt" ] && [ "$nt" -lt "$nn" ] && [ "$nn" -lt "$ne" ]; } \
    || { echo "  the /tiles/ route is missing, doubled, outside the snippet, or behind the Nextcloud catch-all" >&2; fail=1; }
  want='    route /tiles/* {
        uri strip_prefix /tiles
        root * /aps-tiles
        header Cache-Control "no-cache"
        file_server
    }'
  { [ -n "$nt" ] && [ "$(sed -n "${nt},$((nt + 5))p" "$c")" = "$want" ]; } \
    || { echo "  the /tiles/ block is not exactly: strip the prefix, root at /aps-tiles, no-cache, file_server" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 239 "apache serves the suite's basemap same-origin at /tiles/ — APS_TILES_DIR bound read-only into apache alone, the route ahead of Nextcloud's catch-all in the shared snippet, a missing archive a 404 (R49, declared PHP: the setting and its bind)" \
  tiles_route

modern_tls() {  # 250: modern TLS only — the mastercontainer's ACME and internal listeners pin
  # protocols tls1.2 tls1.3 as their tls block's first directive, and apache's start.sh adds the
  # same pin into the stanza in a second pass, on 443 only (an http listener takes no TLS policy);
  # nothing older negotiates on any ingress. The floor landed on main as ead3eb6e and rode
  # the queue into the tree — committed bytes now, measured like every row's subject.
  local fail=0 f
  for f in "$TREE/Containers/mastercontainer/acme.Caddyfile" "$TREE/Containers/mastercontainer/internal.Caddyfile"; do
    [ "$(grep -cE '^[[:space:]]*protocols tls1\.2 tls1\.3[[:space:]]*$' "$f" 2>/dev/null)" -eq 1 ] \
      || { echo "  $f does not pin 'protocols tls1.2 tls1.3' exactly once in its tls block" >&2; fail=1; }
  done
  [ "$(grep -cF 'protocols tls1.2 tls1.3' "$TREE/Containers/apache/start.sh" 2>/dev/null)" -eq 1 ] \
    && grep -A1 -xF "if [ \"\$APACHE_PORT\" = '443' ]; then" "$TREE/Containers/apache/start.sh" | grep -qF 'protocols tls1.2 tls1.3' \
    || { echo "  apache's start.sh does not pin protocols tls1.2 tls1.3 exactly once, inside the APACHE_PORT = 443 guard — an http listener takes no TLS policy and Caddy refuses the config" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 250 "modern TLS only on every ingress — the mastercontainer's ACME and internal listeners pin protocols tls1.2 tls1.3 in their tls blocks and apache's runtime ACME stanza (start.sh, 235's placeholder) carries the same pin on 443; nothing older negotiates (ead3eb6e's security floor, queue-moved by the parity fence)" \
  modern_tls

buscador_db() {  # 260: the database image ships pgvector (pinned by hash) and aps-roles.sh; start.sh
  # runs aps-roles.sh before a dump replay and at every start; the image is built, not retagged, and
  # the build tests it before the push. scripts/db-image-test.sh proves the behaviour on the built
  # image; this row keeps the bytes from leaving the tree unnoticed between releases.
  local d="$TREE/Containers/postgresql/Dockerfile" s="$TREE/Containers/postgresql/start.sh" fail=0 roles replay bg waits
  grep -qF 'COPY --chmod=775 aps-roles.sh /aps-roles.sh' "$d" 2>/dev/null \
    || { echo "  the database Dockerfile does not copy aps-roles.sh" >&2; fail=1; }
  grep -qE '^ENV PGVECTOR_SHA256=[0-9a-f]{64}$' "$d" 2>/dev/null && grep -qF 'sha256sum -c' "$d" \
    || { echo "  the database Dockerfile does not check pgvector against a pinned sha256" >&2; fail=1; }
  roles="$(grep -nE '^[[:space:]]*/aps-roles\.sh$' "$s" 2>/dev/null | head -1 | cut -d: -f1)"
  replay="$(grep -nF 'psql "$POSTGRES_DB" -U "$POSTGRES_USER" < "$DUMP_FILE"' "$s" 2>/dev/null | cut -d: -f1)"
  [ -n "$roles" ] && [ -n "$replay" ] && [ "$roles" -lt "$replay" ] \
    || { echo "  start.sh does not run /aps-roles.sh before the dump replay" >&2; fail=1; }
  bg="$(grep -nx 'aps_roles &' "$s" 2>/dev/null | cut -d: -f1)"
  waits="$(grep -nxF 'wait "$PG_PID"' "$s" 2>/dev/null | cut -d: -f1)"
  [ -n "$bg" ] && [ -n "$waits" ] && [ "$bg" -lt "$waits" ] \
    || { echo "  start.sh does not start aps_roles before it waits on postgres" >&2; fail=1; }
  grep -qE '^BUILD_IMAGES=\(.*\baio-postgresql\b' "$TREE/scripts/retag.sh" 2>/dev/null \
    || { echo "  retag.sh's BUILD_IMAGES lacks aio-postgresql — it would be retagged without pgvector" >&2; fail=1; }
  grep -qF 'bash scripts/db-image-test.sh' "$TREE/.github/workflows/images.yml" 2>/dev/null \
    || { echo "  images.yml no longer tests aio-postgresql before the push" >&2; fail=1; }
  [ "$fail" -eq 0 ]
}

row 260 "the database is ready for Buscador Documental — pgvector pinned by hash and aps-roles.sh in the image, run by start.sh before a dump replay and at every start; aio-postgresql built, and tested before its push" \
  buscador_db

if [ "$fails" -gt 0 ]; then
  echo "BRAND GATE: *** FAIL *** — $fails row(s) failed" >&2
  exit 1
fi
echo "BRAND GATE: PASS — every row measured against the promoted tree, zero skipped"
