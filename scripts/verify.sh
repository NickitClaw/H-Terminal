#!/usr/bin/env bash
set -euo pipefail
HT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HT_DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
if [[ -d "$HT_DEVECO/tools/node/bin" ]]; then
  export PATH="$HT_DEVECO/tools/node/bin:$PATH"
fi
cd "$HT_ROOT"
HT_MODE=${1:-unit}
case "$HT_MODE" in unit|build|device|all) ;; *) echo 'usage: verify.sh [unit|build|device|all]' >&2; exit 2;; esac
git rev-parse --short HEAD
node --version
npm ci --prefix terminal --ignore-scripts --no-audit --no-fund
npm --prefix terminal test
if [[ "$HT_MODE" == build || "$HT_MODE" == all ]]; then
  ./scripts/build-debug.sh
fi
if [[ "$HT_MODE" == device || "$HT_MODE" == all ]]; then
  ./scripts/test-native-flow.sh
  ./scripts/test-native-auth.sh
  python3 ./scripts/verify-device-storage.py
  ./scripts/test-ui.sh
fi
