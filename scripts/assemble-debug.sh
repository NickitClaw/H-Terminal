#!/usr/bin/env bash
set -euo pipefail
HT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HT_DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
export NODE_HOME="$HT_DEVECO/tools/node"
export JAVA_HOME="$HT_DEVECO/jbr/Contents/Home"
export OHOS_BASE_SDK_HOME="$HT_DEVECO/sdk"
export DEVECO_SDK_HOME="$HT_DEVECO/sdk"
export PATH="$NODE_HOME/bin:$HT_DEVECO/tools/ohpm/bin:$HT_DEVECO/tools/hvigor/bin:$PATH"
cd "$HT_ROOT"
if [[ ${1:-} == --clean ]]; then hvigorw clean --no-daemon; fi
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
