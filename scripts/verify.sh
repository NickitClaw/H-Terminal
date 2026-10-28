#!/usr/bin/env bash
set -euo pipefail
HT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HT_DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
if [[ -d "$HT_DEVECO/tools/node/bin" ]]; then
  export PATH="$HT_DEVECO/tools/node/bin:$PATH"
fi
cd "$HT_ROOT"
exec python3 "$HT_ROOT/scripts/verify-report.py" "${1:-unit}"
