#!/usr/bin/env bash
set -euo pipefail
HT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HT_DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
HT_NATIVE="$HT_DEVECO/sdk/default/openharmony/native"
HT_HDC="$HT_DEVECO/sdk/default/openharmony/toolchains/hdc"
HT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/hterminal-security.XXXXXX")
HT_DEVICE_DIR="/data/local/tmp/hterminal-security-$$"
cleanup() { "$HT_HDC" shell rm -rf "$HT_DEVICE_DIR" >/dev/null 2>&1 || true; rm -rf "$HT_WORK"; }
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$HT_WORK/identity"
"$HT_NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos26.0.0 --sysroot="$HT_NATIVE/sysroot" \
  -D__MUSL__ -std=c++17 -O1 -g -pthread -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
  -I"$HT_ROOT/entry/src/main/cpp" -I"$HT_ROOT/third_party/install/arm64-v8a/include" \
  "$HT_ROOT/tests/native/container-fuzz.cpp" "$HT_ROOT/entry/src/main/cpp/session.cpp" \
  "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" \
  -Wl,-rpath,"$HT_DEVICE_DIR" -o "$HT_WORK/container-fuzz"
"$HT_HDC" shell mkdir -p "$HT_DEVICE_DIR"
for HT_FILE in container-fuzz identity; do "$HT_HDC" file send "$HT_WORK/$HT_FILE" "$HT_DEVICE_DIR/$HT_FILE"; done
"$HT_HDC" file send "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_DEVICE_DIR/libssh.so.4"
"$HT_HDC" file send "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" "$HT_DEVICE_DIR/libcrypto.so.3"
for HT_LIB in "$HT_NATIVE"/llvm/lib/clang/*/lib/aarch64-linux-ohos/libclang_rt.{asan,ubsan_standalone}.so; do
  if [[ -f "$HT_LIB" ]]; then "$HT_HDC" file send "$HT_LIB" "$HT_DEVICE_DIR/$(basename "$HT_LIB")"; fi
done
"$HT_HDC" shell chmod 700 "$HT_DEVICE_DIR"
"$HT_HDC" shell chmod 755 "$HT_DEVICE_DIR/container-fuzz"
HT_RESULT="$HT_ROOT/.runtime/native-security.log"
# API26 supplies ASan/UBSan; LeakSanitizer is not supported on this target.
"$HT_HDC" shell "ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 $HT_DEVICE_DIR/container-fuzz $HT_DEVICE_DIR/identity $HT_DEVICE_DIR; echo HT_EXIT:\$?" > "$HT_RESULT" 2>&1
cat "$HT_RESULT"
rg -q '^HT_EXIT:0' "$HT_RESULT"
