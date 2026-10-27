#!/usr/bin/env bash
set -euo pipefail

HT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HT_DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
HT_NATIVE="$HT_DEVECO/sdk/default/openharmony/native"
HT_HDC="$HT_DEVECO/sdk/default/openharmony/toolchains/hdc"
HT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/hterminal-flow.XXXXXX")
HT_DEVICE_DIR="/data/local/tmp/hterminal-flow-$$"
HT_PORT=${HT_TEST_PORT:-22224}
HT_SERVER_PID=''
cleanup() {
  if [[ -n "$HT_SERVER_PID" ]]; then
    kill "$HT_SERVER_PID" 2>/dev/null || true
    wait "$HT_SERVER_PID" 2>/dev/null || true
  fi
  "$HT_HDC" shell rm -rf "$HT_DEVICE_DIR" >/dev/null 2>&1 || true
  rm -rf "$HT_WORK"
}
trap cleanup EXIT

"$HT_DEVECO/tools/node/bin/node" "$HT_ROOT/terminal/tests/ssh-fixture.cjs" "$HT_PORT" > "$HT_WORK/server.log" 2>&1 &
HT_SERVER_PID=$!
for HT_ATTEMPT in {1..50}; do
  if rg -q '^READY$' "$HT_WORK/server.log"; then break; fi
  if ! kill -0 "$HT_SERVER_PID" 2>/dev/null; then cat "$HT_WORK/server.log"; exit 1; fi
  sleep 0.1
done
if ! rg -q '^READY$' "$HT_WORK/server.log"; then cat "$HT_WORK/server.log"; exit 1; fi

"$HT_NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos26.0.0 \
  --sysroot="$HT_NATIVE/sysroot" -D__MUSL__ -std=c++17 -O1 -pthread \
  -I"$HT_ROOT/entry/src/main/cpp" -I"$HT_ROOT/third_party/install/arm64-v8a/include" \
  "$HT_ROOT/tests/native/session-flow.cpp" "$HT_ROOT/entry/src/main/cpp/session.cpp" \
  "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" \
  -Wl,--wrap=ssh_channel_poll -Wl,-rpath,"$HT_DEVICE_DIR" -o "$HT_WORK/session-flow"
"$HT_HDC" shell mkdir -p "$HT_DEVICE_DIR"
"$HT_HDC" file send "$HT_WORK/session-flow" "$HT_DEVICE_DIR/session-flow"
"$HT_HDC" file send "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_DEVICE_DIR/libssh.so.4"
"$HT_HDC" file send "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" "$HT_DEVICE_DIR/libcrypto.so.3"
"$HT_HDC" shell chmod 755 "$HT_DEVICE_DIR/session-flow"
# hdc does not consistently propagate the remote process exit status.
"$HT_HDC" shell "$HT_DEVICE_DIR/session-flow $HT_DEVICE_DIR 10.0.2.2 $HT_PORT; echo HT_EXIT:\$?" | tee "$HT_WORK/result.log"
rg -q '^HT_EXIT:0' "$HT_WORK/result.log"

"$HT_NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos26.0.0 \
  --sysroot="$HT_NATIVE/sysroot" -D__MUSL__ -std=c++17 -O1 -pthread \
  -I"$HT_ROOT/entry/src/main/cpp" -I"$HT_ROOT/third_party/install/arm64-v8a/include" \
  "$HT_ROOT/tests/native/session-cancel.cpp" "$HT_ROOT/entry/src/main/cpp/session.cpp" \
  "$HT_ROOT/entry/src/main/cpp/session_registry.cpp" \
  "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" \
  -Wl,-rpath,"$HT_DEVICE_DIR" -o "$HT_WORK/session-cancel"
"$HT_HDC" file send "$HT_WORK/session-cancel" "$HT_DEVICE_DIR/session-cancel"
"$HT_HDC" shell chmod 755 "$HT_DEVICE_DIR/session-cancel"
"$HT_HDC" shell "$HT_DEVICE_DIR/session-cancel $HT_DEVICE_DIR; echo HT_EXIT:\$?" | tee "$HT_WORK/cancel.log"
rg -q '^HT_EXIT:0' "$HT_WORK/cancel.log"

kill "$HT_SERVER_PID"
wait "$HT_SERVER_PID" 2>/dev/null || true
"$HT_DEVECO/tools/node/bin/node" "$HT_ROOT/terminal/tests/ui-fixture.cjs" "$HT_PORT" > "$HT_WORK/protocol-server.log" 2>&1 &
HT_SERVER_PID=$!
for HT_ATTEMPT in {1..50}; do
  if rg -q '^READY$' "$HT_WORK/protocol-server.log"; then break; fi
  sleep 0.1
done
rg -q '^READY$' "$HT_WORK/protocol-server.log"
"$HT_NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos26.0.0 \
  --sysroot="$HT_NATIVE/sysroot" -D__MUSL__ -std=c++17 -O1 -pthread \
  -I"$HT_ROOT/entry/src/main/cpp" -I"$HT_ROOT/third_party/install/arm64-v8a/include" \
  "$HT_ROOT/tests/native/session-protocol.cpp" "$HT_ROOT/entry/src/main/cpp/session.cpp" \
  "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" \
  -Wl,--wrap=ssh_channel_write -Wl,-rpath,"$HT_DEVICE_DIR" -o "$HT_WORK/session-protocol"
"$HT_HDC" file send "$HT_WORK/session-protocol" "$HT_DEVICE_DIR/session-protocol"
"$HT_HDC" shell mkdir -p "$HT_DEVICE_DIR/protocol"
"$HT_HDC" shell chmod 755 "$HT_DEVICE_DIR/session-protocol"
"$HT_HDC" shell "$HT_DEVICE_DIR/session-protocol $HT_DEVICE_DIR/protocol 10.0.2.2 $HT_PORT; echo HT_EXIT:\$?" | tee "$HT_WORK/protocol.log"
rg -q '^HT_EXIT:0' "$HT_WORK/protocol.log"

"$HT_NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos26.0.0 \
  --sysroot="$HT_NATIVE/sysroot" -D__MUSL__ -std=c++17 -O1 -pthread \
  -I"$HT_ROOT/entry/src/main/cpp" -I"$HT_ROOT/third_party/install/arm64-v8a/include" \
  "$HT_ROOT/tests/native/session-multi.cpp" "$HT_ROOT/entry/src/main/cpp/session.cpp" "$HT_ROOT/entry/src/main/cpp/session_registry.cpp" \
  "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" \
  -Wl,-rpath,"$HT_DEVICE_DIR" -o "$HT_WORK/session-multi"
"$HT_HDC" file send "$HT_WORK/session-multi" "$HT_DEVICE_DIR/session-multi"
"$HT_HDC" shell chmod 755 "$HT_DEVICE_DIR/session-multi"
"$HT_HDC" shell "$HT_DEVICE_DIR/session-multi $HT_DEVICE_DIR/protocol 10.0.2.2 $HT_PORT; echo HT_EXIT:\$?" | tee "$HT_WORK/multi.log"
rg -q '^HT_EXIT:0' "$HT_WORK/multi.log"
