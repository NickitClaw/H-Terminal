#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
export NODE_HOME="$DEVECO/tools/node"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export OHOS_BASE_SDK_HOME="$DEVECO/sdk"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export PATH="$NODE_HOME/bin:$DEVECO/tools/ohpm/bin:$DEVECO/tools/hvigor/bin:$DEVECO/sdk/default/openharmony/toolchains:$PATH"

cd "$ROOT"
npm ci --prefix "$ROOT/terminal" --ignore-scripts --no-audit --no-fund
node "$ROOT/terminal/scripts/sync-assets.mjs"
"$ROOT/scripts/build-native-deps.sh"
ohpm install --all
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
