#!/usr/bin/env bash
# The static gate, run locally and by .github/workflows/ci.yml: the shell lint over the fork's
# own scripts (syntax, shellcheck's errors, sweep coverage, errexit in a tested subshell), their
# SPDX headers, AIO's page check, and the "Latest" rules' self-test. No stack, no network. Exits
# non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
# The fork's shell namespace, spelled once for the sweep below. Unquoted on purpose: the words
# re-glob where they are used. The comm tripwire a few lines down keeps its own literal copy
# deliberately — it is the alarm that reds when this list and the tree drift apart.
SHELL_NAMESPACE='scripts/*.sh provisioning/*.sh provisioning/phases/*.sh host/*.sh aps/release/*.sh install.sh'
linted=()
for s in $SHELL_NAMESPACE; do
  [ -e "$s" ] || continue
  linted+=("$s"); check bash -n "$s"
done
# Upstream's shellcheck.yml lints upstream's shell and skips these namespaces (aps/keep-list.txt);
# this row holds the fork's shell, the extensionless host CLI included, to shellcheck's errors.
shellcheck_row() { shellcheck --shell bash -S error "${linted[@]}" host/aps-conecta; }
check shellcheck_row
# A glob that matches nothing stays literal, `[ -e ]` skips it, and the gate reports only the checks
# it did run — so a renamed directory would silently lint nothing and still print all-ok.
#
# SUBSET, not equality — and NAMESPACE-SCOPED (unchanged by the hard fork, its rationale re-homed):
# instalador's tree carries UPSTREAM's shell (Containers/*/start.sh and friends), and that shell is
# upstream's own to keep — their shellcheck.yml owns it on every push and PR, so this sweep stays
# out of it. Inside the fork's namespaces the doctrine is unchanged: the sweep legitimately lints
# files git has never heard of (a developer's scratch script under scripts/, a site.sh copied in by
# hand while rehearsing a silent install — real shell someone is about to source), so demanding the
# two lists MATCH would be green on every machine and red only in CI. What matters is that nothing
# TRACKED escapes the sweep, so subtract and require empty.
check bash -c '
  [ -z "$(comm -23 <(git ls-files "*.sh" | grep -E "^scripts/|^provisioning/|^host/|^aps/|^install\.sh$" | sort) \
                   <(ls scripts/*.sh provisioning/*.sh provisioning/phases/*.sh host/*.sh aps/release/*.sh install.sh 2>/dev/null | sort))" ]'
# Regression guard (#39): a `set -e` subshell's status must not be consumed in a conditional
# context — bash suppresses errexit inside it, so what reads as a guard runs on and reports
# success. Two shapes, because the second is the one that shipped:
#   - something TESTS it from the left: `if (`, `while (`, `&& (`. Matched on what PRECEDES
#     the `(` rather than by listing keywords — nothing but whitespace may.
#   - something tests it from the right: `( set -e … ) || exit 1`. This reads exactly like a
#     guard and is not one: it asserts nothing. The sweep reads the whole tree, not only seed.sh,
#     because the shape turns up wherever a guard is written.
# Comments are stripped first, since seed.sh documents the wrong shape on purpose.
# Over `git ls-files`, not a hand-written list of directories: a third copy of that list is a
# third thing to forget, and a sweep that matches nothing passes — which is the very hole the
# lint sweep above was rewritten to close. Python rather than grep because the subshell and the
# `||` that tests it are not always on one line. The file set is namespace-scoped like the lint
# sweep's: upstream's shell stays out of it — their shellcheck.yml owns those bytes on every push
# and PR.
check python3 -c '
import re, subprocess, sys

ERREXIT = r"set\s+(-[a-z]*e|-o[ \t]+errexit)"
FROM_THE_LEFT = re.compile(r"\S[ \t]*\(\s*" + ERREXIT)
FROM_THE_RIGHT = re.compile(r"\(\s*" + ERREXIT + r"[^()]*\)[ \t]*(\|\||&&)")

tracked = subprocess.run(["git", "ls-files", "-z", "*.sh"],
                         capture_output=True, text=True, check=True).stdout.split("\0")
files = [f for f in tracked if re.match(r"^(scripts|provisioning|host|aps)/", f) or f == "install.sh"]
bad = []
for name in filter(None, files):
    with open(name, encoding="utf-8") as handle:
        # Comments are stripped first: seed.sh documents the wrong shape on purpose.
        body = "".join(l for l in handle if not l.lstrip().startswith("#"))
    for hit in FROM_THE_LEFT.finditer(body):
        bad.append(f"{name}: tested from the left — {hit.group(0).strip()!r}")
    for hit in FROM_THE_RIGHT.finditer(body):
        bad.append(f"{name}: tested from the right — the {hit.group(2)} after the subshell")

if bad:
    print("errexit is suppressed in a tested context, so these guard nothing:")
    for line in bad:
        print("  " + line)
    sys.exit(1)'
# --- gate: a new file in the fork's namespaces carries an SPDX header (#63) ---------------------
# AGENTS.md's inherited rule ("new fork-owned scripts carry an SPDX header") met 46 of them
# without one, so every PR asked its reviewer to weigh the rule against precedent (#30's retro).
# The owner's call on #63: enforce for files added from now on, fork namespaces only — the same
# namespaces the lint and errexit sweeps own, upstream's shell staying upstream's, and, because
# the rule names scripts, over .sh and .py both; other files (.json, .conf, docs) stay out.
# SPDX_BASELINE freezes the headerless scripts that predate the decision, so main is green by
# construction and the row reds only on a file it has never seen: a tracked one without the
# header line and not on the list. When a baseline file gains its header, drop its line here;
# an exception is a baseline extension in a commit that says why — never a silent row-weakening.
SPDX_BASELINE='
install.sh
provisioning/app-policy.sh
provisioning/intravox/render.py
provisioning/lib.sh
provisioning/phases/05-security.sh
provisioning/phases/06-jobs.sh
provisioning/phases/07-certs.sh
provisioning/phases/10-locale.sh
provisioning/phases/12-apps.sh
provisioning/phases/14-office.sh
provisioning/phases/15-branding.sh
provisioning/phases/16-app-policy.sh
provisioning/phases/20-groups.sh
provisioning/phases/30-folders.sh
provisioning/phases/40-acl.sh
provisioning/phases/41-intravox.sh
provisioning/phases/50-users.sh
provisioning/seed.sh
provisioning/standings.sh
provisioning/usuarios.sh
scripts/comuna-package.sh
scripts/deis.py
scripts/divergence.sh
scripts/env.sh
scripts/office-smoke.sh
scripts/package-release.sh
scripts/provisionador.py
scripts/seed-idempotent.sh
scripts/smoke.sh
scripts/test.sh
scripts/validate.sh
'
spdx_offenders() {
  # every argument that neither carries the header line nor sits on the frozen baseline
  local f
  for f in "$@"; do
    grep -qxF "$f" <<<"$SPDX_BASELINE" && continue
    grep -qx "# SPDX-License-Identifier: AGPL-3.0-or-later" "$f" || printf "%s\n" "$f"
  done
}
spdx_header_row() {
  local off
  off="$(spdx_offenders $(git ls-files "*.sh" "*.py" | grep -E '^scripts/|^provisioning/|^host/|^aps/|^install\.sh$'))"
  [ -z "$off" ] || { printf "tracked scripts lacking an SPDX header and not on the #63 baseline:\n%s\n" "$off" >&2; return 1; }
}
check spdx_header_row
# The baseline's own gate (the seed-idempotent lesson: an allowlist that can rot must not rot
# silently). spdx_header_row pins one direction — every tracked script is headered or on the
# baseline; this pins the other — every baseline line still names a tracked, headerless script.
# Together they make baseline ≡ the headerless set, so green on main cannot erode: a line left
# behind by a rename or a deletion, or by a file that gained its header, reds here instead of
# rotting, and a line appended that names nothing real reds on the spot.
spdx_baseline_row() {
  local line
  local -a dead=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! git ls-files -- "$line" | grep -qx "$line"; then
      dead+=("$line (no longer a tracked file)")
    elif grep -qx "# SPDX-License-Identifier: AGPL-3.0-or-later" "$line"; then
      dead+=("$line (has the header — drop its baseline line)")
    fi
  done <<<"$SPDX_BASELINE"
  [ ${#dead[@]} -eq 0 ] || { printf 'SPDX_BASELINE lines that no longer name a headerless tracked script:\n' >&2; printf '%s\n' "${dead[@]}" >&2; return 1; }
}
check spdx_baseline_row
# The detector's own gate (a row whose detector cannot go red is not a row). The same
# spdx_offenders bytes the row runs, over a fabricated corpus: a new unheadered script is the one
# offender; a baseline member without the header and a newcomer WITH it are not.
spdx_offenders_cases() {
  local tmp off
  tmp="$(mktemp -d)"
  printf "#!/usr/bin/env bash\necho hi\n" > "$tmp/new.sh"
  printf "#!/usr/bin/env bash\n" > "$tmp/old.sh"
  printf "#!/usr/bin/env bash\n# SPDX-FileCopyrightText: 2026 APS Conecta\n# SPDX-License-Identifier: AGPL-3.0-or-later\necho hi\n" > "$tmp/headered.sh"
  off="$(SPDX_BASELINE="$tmp/old.sh" spdx_offenders "$tmp/new.sh" "$tmp/old.sh" "$tmp/headered.sh")"
  rm -rf "$tmp"
  [ "$off" = "$tmp/new.sh" ] \
    || { echo "spdx detector: expected exactly the new unheadered script, got: $off" >&2; return 1; }
}
check spdx_offenders_cases
# And the baseline row's red test, in a scratch git tree so "tracked" is real: a frozen line
# naming a tracked headerless script passes; a line for a file that gained its header, and one
# for a file that is gone, both red — each named with its cause.
spdx_baseline_cases() {
  local tmp out
  tmp="$(mktemp -d)"
  printf "#!/usr/bin/env bash\n" > "$tmp/old.sh"
  printf "#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n" > "$tmp/gained.sh"
  if ! ( cd "$tmp" && git init -q . && git add old.sh gained.sh \
         && SPDX_BASELINE="old.sh" spdx_baseline_row ); then
    rm -rf "$tmp"; echo "spdx baseline: a frozen line naming a tracked headerless script red" >&2; return 1
  fi
  out="$( cd "$tmp" && SPDX_BASELINE="old.sh
gained.sh
gone.sh" spdx_baseline_row 2>&1 )"
  rm -rf "$tmp"
  printf '%s\n' "$out" | grep -q "gained.sh (has the header — drop its baseline line)" \
    && printf '%s\n' "$out" | grep -q "gone.sh (no longer a tracked file)" \
    || { echo "spdx baseline: a gained header or a vanished file did not red with its cause: $out" >&2; return 1; }
}
check spdx_baseline_cases
# --- gate: AIO's page and its notifications are es-CL Spanish (#288) ---------------------------
# scripts/aio-page.py reads what AIO's page and the mastercontainer's notifications show: an English
# word, the other product's name or a colour of the brand token file outside it reds.
aio_page_out="$(python3 -I scripts/aio-page.py 2>&1)" \
  && echo "  ok:   scripts/aio-page.py" \
  || { echo "  FAIL: scripts/aio-page.py"; printf '%s\n' "$aio_page_out" | head -40; fail=1; }
# Its red test, in a scratch copy of what it reads: a planted English sentence, a notification
# naming the other product and a brand hex in the stylesheet must each red, named.
aio_page_cases() {
  local tmp out other='APS Conecta Gestión AIO' # the name of the other product, APS-Conecta/gestion-aio
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/community-containers" "$tmp/themes/apsconecta/core/css"
  cp -R php "$tmp/" && cp -R community-containers/caddy "$tmp/community-containers/" \
    && cp themes/apsconecta/core/css/tokens.css "$tmp/themes/apsconecta/core/css/" \
    || { rm -rf "$tmp"; return 1; }
  printf '<p>Click here to continue.</p>\n' >> "$tmp/php/templates/login.twig"
  printf '<?php $m->sendNotification($c, %s, %s);\n' "'$other'" "'Su copia de seguridad'" \
    > "$tmp/php/src/Cron/Planted.php"
  printf '.planted { color: #7f21fe; }\n' >> "$tmp/php/public/style.css"
  out="$(python3 -I scripts/aio-page.py "$tmp" 2>&1)" \
    && { rm -rf "$tmp"; echo "aio-page: nothing planted went red" >&2; return 1; }
  rm -rf "$tmp"
  grep -q "login.twig:[0-9]*: English .*Click" <<<"$out" \
    && grep -q "Planted.php:1: carries '${other#APS Conecta }'" <<<"$out" \
    && grep -q "style.css:[0-9]*: carries '#7f21fe'" <<<"$out" \
    || { echo "aio-page: a planted English text, the other product's name or a brand hex went unnamed: $out" >&2; return 1; }
}
check aio_page_cases

echo "== self-tests (hermetic — no docker, no stack) =="
# The release pipeline's "Latest" rules, against fixture releases.
latest_out="$(python3 -I aps/release/latest-test.py 2>&1)" \
  && echo "  ok:   aps/release/latest-test.py ($(printf '%s\n' "$latest_out" | grep '^Ran '))" \
  || { echo "  FAIL: aps/release/latest-test.py"; printf '%s\n' "$latest_out" | tail -25; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "PASS: local gate green"
  exit 0
else
  echo "FAIL: local gate has failures"
  exit 1
fi
