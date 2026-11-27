#!/usr/bin/env bash
set -euo pipefail

# Reproducible build script for OpenSSL 3.0.16 + PJSIP 2.17 (libpjsua2.so) on Android.
# Satisfies GPL corresponding-source obligations without checking large .so binaries into Git.

OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.16}"
PJSIP_VERSION="${PJSIP_VERSION:-2.17}"
ANDROID_API="${ANDROID_API:-24}"
ABIS="${ABIS:-arm64-v8a}"
SYNC_JAVA=0

while [ $# -gt 0 ]; do
  case "$1" in
    --abis)
      ABIS="$2"
      shift 2
      ;;
    --api)
      ANDROID_API="$2"
      shift 2
      ;;
    --sync-java)
      SYNC_JAVA=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/build-pjsip-android.sh [--abis "arm64-v8a x86_64"] [--api 24] [--sync-java]
Environment variables:
  ANDROID_NDK_ROOT / ANDROID_NDK_HOME  Path to Android NDK (auto-detected under ANDROID_HOME/ndk if unset)
  OPENSSL_VERSION                      Default: 3.0.16
  PJSIP_VERSION                        Default: 2.17
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/build-pjsip}"
SRC_CACHE="$WORK_DIR/downloads"
JNILIBS_DIR="$ROOT_DIR/android/app/src/main/jniLibs"
JAVA_DIR="$ROOT_DIR/android/app/src/main/java/org/pjsip/pjsua2"
JOBS="$(nproc 2>/dev/null || echo 4)"

if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
  if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
  elif [ -n "${ANDROID_NDK_LATEST_HOME:-}" ]; then
    ANDROID_NDK_ROOT="$ANDROID_NDK_LATEST_HOME"
  elif [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk" ]; then
    ANDROID_NDK_ROOT="$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
  fi
fi

if [ -z "${ANDROID_NDK_ROOT:-}" ] || [ ! -d "$ANDROID_NDK_ROOT" ]; then
  echo "ANDROID_NDK_ROOT not found. Install Android NDK and export ANDROID_NDK_ROOT." >&2
  exit 1
fi
command -v swig >/dev/null 2>&1 || { echo "swig is required (sudo apt-get install -y swig)" >&2; exit 1; }
command -v java >/dev/null 2>&1 || { echo "JDK is required" >&2; exit 1; }

export ANDROID_NDK_ROOT
HOST_TAG="linux-x86_64"
[ "$(uname -s)" = "Darwin" ] && HOST_TAG="darwin-x86_64"
TOOLCHAIN_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin"
SYSROOT_LIB="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/sysroot/usr/lib"
export PATH="$TOOLCHAIN_BIN:$PATH"

mkdir -p "$SRC_CACHE" "$JNILIBS_DIR"

fetch() {
  local url="$1" dest="$2"
  if [ ! -f "$dest" ]; then
    echo "Downloading $url ..."
    curl -fsSL --retry 3 -o "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
}

OPENSSL_TAR="$SRC_CACHE/openssl-${OPENSSL_VERSION}.tar.gz"
PJSIP_TAR="$SRC_CACHE/pjproject-${PJSIP_VERSION}.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" "$OPENSSL_TAR"
fetch "https://github.com/pjsip/pjproject/archive/refs/tags/${PJSIP_VERSION}.tar.gz" "$PJSIP_TAR"

build_abi() {
  local abi="$1"
  local ssl_target="" ndk_triple=""
  case "$abi" in
    arm64-v8a)
      ssl_target="android-arm64"
      ndk_triple="aarch64-linux-android"
      ;;
    x86_64)
      ssl_target="android-x86_64"
      ndk_triple="x86_64-linux-android"
      ;;
    armeabi-v7a)
      ssl_target="android-arm"
      ndk_triple="arm-linux-androideabi"
      ;;
    *)
      echo "Unsupported ABI: $abi" >&2
      exit 1
      ;;
  esac

  echo "=== Building OpenSSL ${OPENSSL_VERSION} + PJSIP ${PJSIP_VERSION} for ${abi} (API ${ANDROID_API}) ==="
  local abi_dir="$WORK_DIR/$abi"
  local ssl_src="$abi_dir/openssl-${OPENSSL_VERSION}"
  local ssl_prefix="$abi_dir/openssl-out"
  local pj_src="$abi_dir/pjproject-${PJSIP_VERSION}"

  rm -rf "$abi_dir"
  mkdir -p "$abi_dir"
  tar -xzf "$OPENSSL_TAR" -C "$abi_dir"
  tar -xzf "$PJSIP_TAR" -C "$abi_dir"

  pushd "$ssl_src" >/dev/null
  ./Configure "$ssl_target"     "-D__ANDROID_API__=${ANDROID_API}"     no-shared no-tests     --prefix="$ssl_prefix" --libdir=lib
  make -j"$JOBS"
  make install_sw
  popd >/dev/null

  cat > "$pj_src/pjlib/include/pj/config_site.h" <<'EOF'
#define PJ_CONFIG_ANDROID 1
#define PJ_HAS_SSL_SOCK 1
#define PJMEDIA_HAS_SRTP 1
#define PJMEDIA_HAS_VIDEO 0
#define PJSIP_MAX_PKT_LEN 8192
#define PJSUA_MAX_ACC 128
#define PJ_IOQUEUE_MAX_HANDLES 256
#include <pj/config_site_sample.h>
#undef PJSUA_MAX_ACC
#define PJSUA_MAX_ACC 128
#undef PJ_IOQUEUE_MAX_HANDLES
#define PJ_IOQUEUE_MAX_HANDLES 256
EOF

  pushd "$pj_src" >/dev/null
  LDFLAGS="-Wl,-z,max-page-size=16384" TARGET_ABI="$abi" APP_PLATFORM="android-${ANDROID_API}" ./configure-android --use-ndk-cflags --with-ssl="$ssl_prefix"
  make dep -j"$JOBS"
  make -j"$JOBS"
  make -C pjsip-apps/src/swig/java

  local built_so
  built_so="$(find pjsip-apps/src/swig/java -name 'libpjsua2.so' | head -n 1)"
  if [ -z "$built_so" ]; then
    echo "Failed to locate built libpjsua2.so for $abi" >&2
    exit 1
  fi
  mkdir -p "$JNILIBS_DIR/$abi"
  cp "$built_so" "$JNILIBS_DIR/$abi/libpjsua2.so"
  cp "$SYSROOT_LIB/$ndk_triple/libc++_shared.so" "$JNILIBS_DIR/$abi/libc++_shared.so"

  if [ "$SYNC_JAVA" = "1" ]; then
    local generated_java
    generated_java="$(find pjsip-apps/src/swig/java -type d -path '*/org/pjsip/pjsua2' | head -n 1)"
    if [ -n "$generated_java" ]; then
      rm -rf "$JAVA_DIR"
      mkdir -p "$JAVA_DIR"
      cp "$generated_java"/*.java "$JAVA_DIR/"
    fi
  fi
  popd >/dev/null
}

for abi in $ABIS; do
  build_abi "$abi"
done

echo "Done! Installed native libraries:"
find "$JNILIBS_DIR" -name '*.so' -exec ls -lh {} +
