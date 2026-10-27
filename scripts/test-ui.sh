#!/usr/bin/env bash
set -euo pipefail
HT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HT_DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
HT_HDC="$HT_DEVECO/sdk/default/openharmony/toolchains/hdc"
HT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/hterminal-ui.XXXXXX")
HT_PORT=${HT_UI_PORT:-22227}
HT_SERVER_PID=''
HT_AUTH_SERVER_PID=''
HT_AUTH_PORT=${HT_AUTH_PORT:-22228}
cleanup() {
  HT_RESULT=$?
  if [[ -n "$HT_SERVER_PID" ]]; then kill "$HT_SERVER_PID" 2>/dev/null || true; wait "$HT_SERVER_PID" 2>/dev/null || true; fi
  if [[ -n "$HT_AUTH_SERVER_PID" ]]; then kill "$HT_AUTH_SERVER_PID" 2>/dev/null || true; wait "$HT_AUTH_SERVER_PID" 2>/dev/null || true; fi
  "$HT_HDC" shell rm -f /data/local/tmp/hterminal-ui-layout.json >/dev/null 2>&1 || true
  if [[ "$HT_RESULT" != 0 ]]; then
    mkdir -p "$HT_ROOT/.runtime/last-ui-failure"
    cp "$HT_WORK/"*.log "$HT_ROOT/.runtime/last-ui-failure/" 2>/dev/null || true
    cp "$HT_WORK/layout.json" "$HT_ROOT/.runtime/last-ui-failure/" 2>/dev/null || true
  fi
  rm -rf "$HT_WORK"
}
trap cleanup EXIT
"$HT_DEVECO/tools/node/bin/node" "$HT_ROOT/terminal/tests/ui-fixture.cjs" "$HT_PORT" > "$HT_WORK/server.log" 2>&1 &
HT_SERVER_PID=$!
for HT_ATTEMPT in {1..50}; do
  if rg -q '^READY$' "$HT_WORK/server.log"; then break; fi
  if ! kill -0 "$HT_SERVER_PID" 2>/dev/null; then cat "$HT_WORK/server.log"; exit 1; fi
  sleep 0.1
done
rg -q '^READY$' "$HT_WORK/server.log"
"$HT_DEVECO/tools/node/bin/node" "$HT_ROOT/terminal/tests/auth-fixture.cjs" "$HT_AUTH_PORT" "$HT_WORK" > "$HT_WORK/auth-server.log" 2>&1 &
HT_AUTH_SERVER_PID=$!
for HT_ATTEMPT in {1..50}; do
  if rg -q '^READY$' "$HT_WORK/auth-server.log"; then break; fi
  sleep 0.1
done
rg -q '^READY$' "$HT_WORK/auth-server.log"
"$HT_ROOT/scripts/sign-debug.sh" "$HT_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
"$HT_HDC" install -r "$HT_ROOT/.runtime/signing/H-Terminal-signed.hap"
"$HT_HDC" shell power-shell wakeup
"$HT_HDC" shell aa force-stop com.nickitclaw.hterminal || true
"$HT_HDC" shell aa start -a EntryAbility -b com.nickitclaw.hterminal
HT_HDC="$HT_HDC" HT_UI_PORT="$HT_PORT" HT_AUTH_PORT="$HT_AUTH_PORT" HT_UI_WORK="$HT_WORK" python3 "$HT_ROOT/tests/ui/smoke.py"
