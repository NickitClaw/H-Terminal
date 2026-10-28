#!/usr/bin/env bash
set -euo pipefail
HT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HT_DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
HT_HDC="$HT_DEVECO/sdk/default/openharmony/toolchains/hdc"
HT_NATIVE="$HT_DEVECO/sdk/default/openharmony/native"
HT_DOCKER_CONTEXT=${HT_DOCKER_CONTEXT:-colima}
HT_IMAGE=${HT_OPENSSH_IMAGE:-hterminal-openssh:test}
HT_PORT=${HT_OPENSSH_PORT:-22229}
mkdir -p "$HT_ROOT/.runtime"
HT_WORK=$(mktemp -d "$HT_ROOT/.runtime/openssh-fixture.XXXXXX")
HT_DEVICE_DIR="/data/local/tmp/hterminal-openssh-$$"
HT_CONTAINER=''
HT_EVIDENCE=${HT_REPORT_DIR:-$HT_ROOT/.runtime/openssh}
mkdir -p "$HT_EVIDENCE"
cleanup() {
  "$HT_HDC" file recv "$HT_DEVICE_DIR/bridge.trace" "$HT_EVIDENCE/bridge.trace" >/dev/null 2>&1 || true
  if [[ -n "$HT_CONTAINER" ]]; then docker --context "$HT_DOCKER_CONTEXT" logs "$HT_CONTAINER" > "$HT_EVIDENCE/sshd.log" 2>&1 || true; fi
  if [[ -n "$HT_CONTAINER" ]]; then docker --context "$HT_DOCKER_CONTEXT" rm -f "$HT_CONTAINER" >/dev/null 2>&1 || true; fi
  "$HT_HDC" shell rm -rf "$HT_DEVICE_DIR" >/dev/null 2>&1 || true
  rm -rf "$HT_WORK"
}
trap cleanup EXIT
if [[ -z ${HT_OPENSSH_IMAGE:-} ]]; then
  docker --context "$HT_DOCKER_CONTEXT" build -t "$HT_IMAGE" "$HT_ROOT/tests/openssh"
fi
ssh-keygen -q -t ed25519 -N '' -f "$HT_WORK/identity"
chmod 644 "$HT_WORK/identity.pub"
HT_CONTAINER=$(docker --context "$HT_DOCKER_CONTEXT" run -d --label hterminal.fixture=openssh \
  -p "127.0.0.1:$HT_PORT:22" --mount "type=bind,src=$HT_WORK/identity.pub,dst=/etc/ssh/fixture_authorized_keys,readonly" "$HT_IMAGE")
for HT_ATTEMPT in {1..100}; do
  if docker --context "$HT_DOCKER_CONTEXT" logs "$HT_CONTAINER" 2>&1 | rg -q 'Server listening'; then break; fi
  sleep 0.1
done
docker --context "$HT_DOCKER_CONTEXT" exec "$HT_CONTAINER" cat /fixture-versions | tee "$HT_EVIDENCE/versions.txt"
docker --context "$HT_DOCKER_CONTEXT" image inspect "$HT_IMAGE" --format '{{.Id}}' >> "$HT_EVIDENCE/versions.txt"
"$HT_NATIVE/llvm/bin/clang++" --target=aarch64-linux-ohos26.0.0 --sysroot="$HT_NATIVE/sysroot" \
  -D__MUSL__ -std=c++17 -O1 -pthread -I"$HT_ROOT/entry/src/main/cpp" -I"$HT_ROOT/third_party/install/arm64-v8a/include" \
  "$HT_ROOT/tests/native/session-bridge.cpp" "$HT_ROOT/entry/src/main/cpp/session.cpp" \
  "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" \
  -Wl,-rpath,"$HT_DEVICE_DIR" -o "$HT_WORK/session-bridge"
"$HT_HDC" shell mkdir -p "$HT_DEVICE_DIR"
for HT_FILE in session-bridge identity; do "$HT_HDC" file send "$HT_WORK/$HT_FILE" "$HT_DEVICE_DIR/$HT_FILE"; done
"$HT_HDC" file send "$HT_ROOT/entry/libs/arm64-v8a/libssh.so.4" "$HT_DEVICE_DIR/libssh.so.4"
"$HT_HDC" file send "$HT_ROOT/entry/libs/arm64-v8a/libcrypto.so.3" "$HT_DEVICE_DIR/libcrypto.so.3"
"$HT_HDC" shell chmod 700 "$HT_DEVICE_DIR"
"$HT_HDC" shell chmod 755 "$HT_DEVICE_DIR/session-bridge"
"$HT_HDC" shell chmod 600 "$HT_DEVICE_DIR/identity"
HT_HDC="$HT_HDC" HT_DEVICE_DIR="$HT_DEVICE_DIR" HT_OPENSSH_PORT="$HT_PORT" HT_REPORT_DIR="$HT_EVIDENCE" \
  "$HT_DEVECO/tools/node/bin/node" "$HT_ROOT/tests/openssh/compat.cjs"
# Reuse the same isolated server/key with real OpenSSH partial authentication.
docker --context "$HT_DOCKER_CONTEXT" exec "$HT_CONTAINER" sh -c \
  'printf "\nAuthenticationMethods publickey,keyboard-interactive:pam\n" >> /etc/ssh/sshd_config'
docker --context "$HT_DOCKER_CONTEXT" restart "$HT_CONTAINER" >/dev/null
for HT_ATTEMPT in {1..100}; do
  if nc -z 127.0.0.1 "$HT_PORT"; then break; fi
  sleep 0.1
done
HT_HDC="$HT_HDC" HT_DEVICE_DIR="$HT_DEVICE_DIR" HT_OPENSSH_PORT="$HT_PORT" HT_REPORT_DIR="$HT_EVIDENCE" HT_OPENSSH_MFA=1 \
  "$HT_DEVECO/tools/node/bin/node" "$HT_ROOT/tests/openssh/compat.cjs"
