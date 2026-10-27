#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="${DEVECO_SDK_ROOT:-/Applications/DevEco-Studio.app/Contents/sdk}"
NATIVE_DIR="$SDK_ROOT/default/openharmony/native"
TOOLCHAIN_FILE="$NATIVE_DIR/build/cmake/ohos.toolchain.cmake"
CMAKE="$NATIVE_DIR/build-tools/cmake/bin/cmake"
LLVM_BIN="$NATIVE_DIR/llvm/bin"
API_LEVEL="26.0.0"

OPENSSL_VERSION="3.5.9"
OPENSSL_URL="https://www.openssl.org/source/openssl-3.5.9.tar.gz"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_LICENSE="Apache-2.0"
LIBSSH_VERSION="0.12.2"
LIBSSH_URL="https://www.libssh.org/files/0.12/libssh-0.12.2.tar.xz"
LIBSSH_SHA256="49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f"
LIBSSH_LICENSE="LGPL-2.1-or-later"

CACHE_DIR="$ROOT_DIR/third_party/cache"
SOURCE_DIR="$ROOT_DIR/third_party/src"
BUILD_DIR="$ROOT_DIR/third_party/build"
INSTALL_DIR="$ROOT_DIR/third_party/install"
JOBS="${JOBS:-4}"

for tool in curl perl make shasum tar patch; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing host tool: $tool" >&2
        exit 1
    }
done
for path in "$TOOLCHAIN_FILE" "$CMAKE" "$LLVM_BIN/clang"; do
    if [[ ! -e "$path" ]]; then
        echo "missing API26 NDK component: $path" >&2
        exit 1
    fi
done

fetch_and_verify() {
    local url="$1"
    local archive="$2"
    local expected="$3"
    local temporary="$archive.download"

    mkdir -p "$(dirname "$archive")"
    if [[ ! -f "$archive" ]] || ! echo "$expected  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
        rm -f "$archive" "$temporary"
        curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
            --output "$temporary" "$url"
        mv "$temporary" "$archive"
    fi
    echo "$expected  $archive" | shasum -a 256 -c -
}

extract_source() {
    local archive="$1"
    local expected_dir="$2"
    rm -rf "$expected_dir"
    mkdir -p "$SOURCE_DIR"
    tar -xf "$archive" -C "$SOURCE_DIR"
    if [[ ! -d "$expected_dir" ]]; then
        echo "unexpected source archive layout: $archive" >&2
        exit 1
    fi
}

OPENSSL_ARCHIVE="$CACHE_DIR/openssl-$OPENSSL_VERSION.tar.gz"
LIBSSH_ARCHIVE="$CACHE_DIR/libssh-$LIBSSH_VERSION.tar.xz"
OPENSSL_SOURCE="$SOURCE_DIR/openssl-$OPENSSL_VERSION"
LIBSSH_SOURCE="$SOURCE_DIR/libssh-$LIBSSH_VERSION"

fetch_and_verify "$OPENSSL_URL" "$OPENSSL_ARCHIVE" "$OPENSSL_SHA256"
fetch_and_verify "$LIBSSH_URL" "$LIBSSH_ARCHIVE" "$LIBSSH_SHA256"
extract_source "$OPENSSL_ARCHIVE" "$OPENSSL_SOURCE"
extract_source "$LIBSSH_ARCHIVE" "$LIBSSH_SOURCE"
patch -d "$LIBSSH_SOURCE" -p1 -F 0 < "$ROOT_DIR/patches/libssh-0.12.2-drain-buffered-output.patch"

build_abi() {
    local abi="$1"
    local target
    local openssl_target
    case "$abi" in
        arm64-v8a)
            target="aarch64-linux-ohos$API_LEVEL"
            openssl_target="linux-aarch64"
            ;;
        x86_64)
            target="x86_64-linux-ohos$API_LEVEL"
            openssl_target="linux-x86_64"
            ;;
        *)
            echo "unsupported ABI: $abi" >&2
            exit 1
            ;;
    esac

    local openssl_build="$BUILD_DIR/$abi/openssl"
    local libssh_build="$BUILD_DIR/$abi/libssh"
    local prefix="$INSTALL_DIR/$abi"
    local output="$ROOT_DIR/entry/libs/$abi"
    rm -rf "$openssl_build" "$libssh_build" "$prefix"
    mkdir -p "$openssl_build" "$libssh_build" "$prefix" "$output"
    rm -f "$output/libssh.so.4" "$output/libcrypto.so.3"

    echo "building OpenSSL $OPENSSL_VERSION ($OPENSSL_LICENSE) for $abi"
    (
        cd "$openssl_build"
        export CC="$LLVM_BIN/clang"
        export AR="$LLVM_BIN/llvm-ar"
        export RANLIB="$LLVM_BIN/llvm-ranlib"
        export NM="$LLVM_BIN/llvm-nm"
        export STRIP="$LLVM_BIN/llvm-strip"
        export CFLAGS="--target=$target --sysroot=$NATIVE_DIR/sysroot -D__MUSL__ -fPIC -O2 -fstack-protector-strong"
        export LDFLAGS="--target=$target --sysroot=$NATIVE_DIR/sysroot -fuse-ld=lld -Wl,--build-id=sha1 -Wl,-z,noexecstack"
        export ZERO_AR_DATE=1
        perl "$OPENSSL_SOURCE/Configure" "$openssl_target" \
            --prefix="$prefix" --libdir=lib \
            shared no-apps no-docs no-ssl no-tests
        make -j"$JOBS" build_sw
        make install_sw
    )

    test -f "$prefix/lib/libcrypto.so.3"
    echo "building libssh $LIBSSH_VERSION ($LIBSSH_LICENSE) for $abi"
    "$CMAKE" -S "$LIBSSH_SOURCE" -B "$libssh_build" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DOHOS_ARCH="$abi" \
        -DOHOS_COMPATIBLE_SDK_VERSION="$API_LEVEL" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_STATIC_LIB=OFF \
        -DWITH_EXAMPLES=OFF \
        -DWITH_EXEC=OFF \
        -DWITH_FIDO2=OFF \
        -DWITH_GSSAPI=OFF \
        -DWITH_NACL=OFF \
        -DWITH_PCAP=OFF \
        -DWITH_SERVER=OFF \
        -DWITH_SFTP=OFF \
        -DWITH_SYMBOL_VERSIONING=OFF \
        -DWITH_ZLIB=OFF \
        -DUNIT_TESTING=OFF \
        -DOPENSSL_ROOT_DIR="$prefix" \
        -DOPENSSL_INCLUDE_DIR="$prefix/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$prefix/lib/libcrypto.so.3"
    "$CMAKE" --build "$libssh_build" --parallel "$JOBS"
    "$CMAKE" --install "$libssh_build"

    test -f "$prefix/lib/libssh.so.4"
    cp -L "$prefix/lib/libcrypto.so.3" "$output/libcrypto.so.3"
    cp -L "$prefix/lib/libssh.so.4" "$output/libssh.so.4"
    chmod 0755 "$output/libcrypto.so.3" "$output/libssh.so.4"
    "$LLVM_BIN/llvm-strip" --strip-unneeded "$output/libcrypto.so.3" "$output/libssh.so.4"
    echo "installed fresh $abi libraries in $output"
}

abis=("$@")
if [[ ${#abis[@]} -eq 0 ]]; then
    abis=(arm64-v8a x86_64)
fi
for abi in "${abis[@]}"; do
    build_abi "$abi"
done
