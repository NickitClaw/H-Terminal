cmake_minimum_required(VERSION 3.16)
project(hterminal_entry LANGUAGES CXX)

if(NOT OHOS)
    message(FATAL_ERROR "libentry.so must be built with the HarmonyOS NDK toolchain")
endif()
if(NOT OHOS_COMPATIBLE_SDK_VERSION STREQUAL "26.0.0")
    message(FATAL_ERROR "libentry.so requires OHOS_COMPATIBLE_SDK_VERSION=26.0.0 (API26)")
endif()
if(NOT OHOS_ARCH STREQUAL "arm64-v8a" AND NOT OHOS_ARCH STREQUAL "x86_64")
    message(FATAL_ERROR "Unsupported OHOS_ARCH: ${OHOS_ARCH}")
endif()

set(ENTRY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../..")
set(NATIVE_LIBS "${ENTRY_ROOT}/libs/${OHOS_ARCH}")
set(NATIVE_INCLUDE "${ENTRY_ROOT}/../third_party/install/${OHOS_ARCH}/include")
if(NOT EXISTS "${NATIVE_LIBS}/libssh.so.4" OR NOT EXISTS "${NATIVE_LIBS}/libcrypto.so.3")
    message(FATAL_ERROR "Run scripts/build-native-deps.sh for ${OHOS_ARCH} before building libentry.so")
endif()
if(NOT EXISTS "${NATIVE_INCLUDE}/libssh/libssh.h")
    message(FATAL_ERROR "Missing freshly built libssh headers for ${OHOS_ARCH}: ${NATIVE_INCLUDE}")
endif()

add_library(entry SHARED
    entry.cpp
    session.cpp
    session_registry.cpp
)
add_library(hterminal_ssh SHARED IMPORTED)
set_target_properties(hterminal_ssh PROPERTIES
    IMPORTED_LOCATION "${NATIVE_LIBS}/libssh.so.4"
    IMPORTED_SONAME "libssh.so.4"
)
add_library(hterminal_crypto SHARED IMPORTED)
set_target_properties(hterminal_crypto PROPERTIES
    IMPORTED_LOCATION "${NATIVE_LIBS}/libcrypto.so.3"
    IMPORTED_SONAME "libcrypto.so.3"
)
find_library(NAPI_LIBRARY ace_napi.z
    PATHS "${OHOS_SDK_NATIVE}/sysroot/usr/lib/${OHOS_TOOLCHAIN_NAME}"
    NO_DEFAULT_PATH
    REQUIRED
)
find_package(Threads REQUIRED)

target_compile_features(entry PRIVATE cxx_std_17)
target_compile_options(entry PRIVATE
    -Wall -Wextra -Werror -Wno-unused-command-line-argument -fvisibility=hidden
)
target_include_directories(entry PRIVATE
    "${NATIVE_INCLUDE}"
    "${OHOS_SDK_NATIVE}/sysroot/usr/include"
)
target_link_libraries(entry PRIVATE
    hterminal_ssh
    hterminal_crypto
    "${NAPI_LIBRARY}"
    Threads::Threads
)
set_target_properties(entry PROPERTIES
    OUTPUT_NAME "entry"
    CXX_EXTENSIONS OFF
    SKIP_BUILD_RPATH TRUE
    LIBRARY_OUTPUT_DIRECTORY "${NATIVE_LIBS}"
)
