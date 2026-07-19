#!/usr/bin/env bash
# Local quality gate — the CI stand-in (Story 0.4). Runs the STATIC checks that need no running
# stack, then the smoke check when a stack is up. Exits non-zero if anything fails.
# NOT `set -e`: we run every check and aggregate, so one failure doesn't hide the rest.
set -uo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "  ok:   $*"; else echo "  FAIL: $*"; fail=1; fi; }

echo "== static checks (no running stack needed) =="
if [ ! -f .env ]; then
  echo "  note: .env absent — compose interpolation will fail; run 'cp .env.example .env' first"
fi
check docker compose -f compose.yaml config -q
check docker compose -f compose.yaml -f compose.dev.yaml config -q
check docker compose --profile collabora --profile eurooffice config -q
for s in scripts/*.sh provisioning/*.sh provisioning/phases/*.sh; do
  [ -e "$s" ] && check bash -n "$s"
done
check test -f dev/xdebug.ini

echo "== smoke (only if a stack is running) =="
if docker compose ps --status running --services 2>/dev/null | grep -qx nextcloud; then
  if bash scripts/smoke.sh; then echo "  ok:   smoke"; else echo "  FAIL: smoke"; fail=1; fi
else
  echo "  skipped: no running stack (static-only gate)"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: local gate green"
  exit 0
else
  echo "FAIL: local gate has failures"
  exit 1
fi
