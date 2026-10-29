#!/usr/bin/env bash
# Builds one lua_dart native library from the pinned Lua release. Used by
# hook/build.dart for source builds and by the kiln release workflow;
# matching consumers download the release instead.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
# shellcheck source=tool/lua_pin.sh
source "$root/tool/lua_pin.sh"
android_api="${LUADART_ANDROID_API:-24}"

usage() {
  cat >&2 <<'EOF'
Usage: tool/build_native_artifact.sh <target>

Targets:
  macos-arm64              macos-x64
  ios-arm64-iphoneos       ios-arm64-iphonesimulator
  ios-x64-iphonesimulator
  android-arm              android-arm64              android-x64
  linux-arm64              linux-x64
  windows-arm64            windows-x64

Apple targets need Xcode. Android targets need ANDROID_NDK_HOME or a standard
Android SDK. Linux targets build on Linux. Windows targets cross-build on
Linux with MinGW (x64) or llvm-mingw (arm64).

Environment:
  LUADART_LUA_TARBALL  the pinned Lua release; the hook passes it from the
                       kiln cache. Default: tool/fetch_lua.sh downloads it.
  LUADART_BUILD_ROOT   build directory (default build/native/<target>)
  LUADART_OUTPUT       output library path
                       (default build/native_artifacts/<target>/<file>)
  LUADART_MACOS_VERSION, LUADART_IOS_VERSION, LUADART_ANDROID_API
                       minimum OS versions (default 12.0, 13.0, 24)
EOF
  exit 64
}

case "$target" in
  macos-arm64|macos-x64|ios-arm64-iphoneos|ios-arm64-iphonesimulator|ios-x64-iphonesimulator|android-arm|android-arm64|android-x64|linux-arm64|linux-x64|windows-arm64|windows-x64) ;;
  *) usage ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

command -v cmake >/dev/null || { echo 'cmake is required' >&2; exit 1; }
tarball="${LUADART_LUA_TARBALL:-}"
if [[ -z "$tarball" ]]; then
  tarball="$(bash "$root/tool/fetch_lua.sh")"
fi
[[ "$(sha256_of "$tarball")" == "$LUA_SHA256" ]] || {
  echo "PIN MISMATCH: $tarball is not Lua $LUA_VERSION ($LUA_SHA256)" >&2
  exit 1
}

build_dir="${LUADART_BUILD_ROOT:-$root/build/native/$target}"
macos_version="${LUADART_MACOS_VERSION:-12.0}"
ios_version="${LUADART_IOS_VERSION:-13.0}"

rm -rf "$build_dir"
mkdir -p "$build_dir/lua"
tar -xzf "$tarball" -C "$build_dir/lua" --strip-components 1
lua_source="$build_dir/lua/src"
grep -Eq "^#define LUA_VERSION_RELEASE[[:space:]]+\"${LUA_VERSION##*.}\"" "$lua_source/lua.h" || {
  echo "The tarball is not Lua $LUA_VERSION." >&2
  exit 1
}

cmake_args=(
  -DCMAKE_BUILD_TYPE=Release
  -DLUADART_LUA_SOURCE="$lua_source"
  -DLUADART_BUILD_TESTS=OFF
)
os=
artifact_arch=
output_name=
verification_nm=
verification_readelf=
verification_readobj=
verification_objdump=
strip_tool=
run_smoke=false

case "$target" in
  macos-arm64|macos-x64)
    os=macos
    [[ "$target" == macos-arm64 ]] && artifact_arch=arm64 || artifact_arch=x86_64
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    cmake_args+=(
      -DCMAKE_OSX_ARCHITECTURES="$artifact_arch"
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$macos_version"
      -DCMAKE_OSX_SYSROOT="$sdk_path"
      -DLUADART_BUILD_TESTS=ON
    )
    output_name=liblua_dart.dylib
    strip_tool="$(xcrun --sdk macosx -f strip)"
    run_smoke=true
    ;;
  ios-arm64-iphoneos|ios-arm64-iphonesimulator|ios-x64-iphonesimulator)
    os=ios
    [[ "$target" == ios-x64-iphonesimulator ]] && artifact_arch=x86_64 || artifact_arch=arm64
    [[ "$target" == *-iphoneos ]] && sdk=iphoneos || sdk=iphonesimulator
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cmake_args+=(
      -DCMAKE_SYSTEM_NAME=iOS
      -DCMAKE_OSX_ARCHITECTURES="$artifact_arch"
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$ios_version"
      -DCMAKE_OSX_SYSROOT="$sdk_path"
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    )
    output_name=liblua_dart.dylib
    strip_tool="$(xcrun --sdk "$sdk" -f strip)"
    ;;
  android-arm|android-arm64|android-x64)
    os=android
    ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
    if [[ -z "$ndk" ]]; then
      ndk="$HOME/Library/Android/sdk/ndk/28.2.13676358"
    fi
    [[ -d "$ndk" ]] || {
      echo 'Set ANDROID_NDK_HOME to an Android NDK (releases use 28.2.13676358).' >&2
      exit 1
    }
    case "$(uname -s)" in
      Darwin) ndk_host=darwin-x86_64 ;;
      Linux) ndk_host=linux-x86_64 ;;
      *) echo 'Android builds need macOS or Linux.' >&2; exit 1 ;;
    esac
    llvm_bin="$ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
    case "$target" in
      android-arm) android_abi=armeabi-v7a; artifact_arch=arm ;;
      android-arm64) android_abi=arm64-v8a; artifact_arch=aarch64 ;;
      android-x64) android_abi=x86_64; artifact_arch=x86_64 ;;
    esac
    cmake_args+=(
      -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI="$android_abi"
      -DANDROID_PLATFORM="android-$android_api"
    )
    output_name=liblua_dart.so
    verification_nm="$llvm_bin/llvm-nm"
    verification_readelf="$llvm_bin/llvm-readelf"
    strip_tool="$llvm_bin/llvm-strip"
    ;;
  linux-arm64|linux-x64)
    os=linux
    [[ "$(uname -s)" == Linux ]] || {
      echo 'Linux libraries build on Linux.' >&2
      exit 1
    }
    host_arch="$(uname -m)"
    if [[ "$target" == linux-arm64 ]]; then
      artifact_arch=aarch64
      native=false
      [[ "$host_arch" == aarch64 || "$host_arch" == arm64 ]] && native=true
    else
      artifact_arch=x86_64
      native=false
      [[ "$host_arch" == x86_64 ]] && native=true
    fi
    if [[ "$native" == true ]]; then
      cc="${CC:-gcc}"
      strip_tool="${STRIP:-strip}"
      verification_nm="${NM:-nm}"
      verification_readelf="${READELF:-readelf}"
      cmake_args+=(-DCMAKE_C_COMPILER="$cc" -DLUADART_BUILD_TESTS=ON)
      run_smoke=true
    else
      prefix=aarch64-linux-gnu
      [[ "$target" == linux-x64 ]] && prefix=x86_64-linux-gnu
      cc="${CC:-$prefix-gcc}"
      strip_tool="${STRIP:-$prefix-strip}"
      verification_nm="${NM:-$prefix-nm}"
      verification_readelf="${READELF:-$prefix-readelf}"
      cmake_args+=(
        -DCMAKE_SYSTEM_NAME=Linux
        -DCMAKE_SYSTEM_PROCESSOR="$artifact_arch"
        -DCMAKE_C_COMPILER="$cc"
      )
    fi
    output_name=liblua_dart.so
    ;;
  windows-x64)
    os=windows
    [[ "$(uname -s)" == Linux ]] || {
      echo 'Windows libraries cross-build on Linux.' >&2
      exit 1
    }
    artifact_arch=x86_64
    cc="${CC:-x86_64-w64-mingw32-gcc}"
    strip_tool="${STRIP:-x86_64-w64-mingw32-strip}"
    verification_objdump="${OBJDUMP:-x86_64-w64-mingw32-objdump}"
    cmake_args+=(
      -DCMAKE_SYSTEM_NAME=Windows
      -DCMAKE_SYSTEM_PROCESSOR=x86_64
      -DCMAKE_C_COMPILER="$cc"
      -DCMAKE_RC_COMPILER="${WINDRES:-x86_64-w64-mingw32-windres}"
      -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-insert-timestamp
    )
    output_name=lua_dart.dll
    ;;
  windows-arm64)
    os=windows
    [[ "$(uname -s)" == Linux ]] || {
      echo 'Windows libraries cross-build on Linux.' >&2
      exit 1
    }
    artifact_arch=arm64
    # GCC has no Windows ARM64 target: the pinned llvm-mingw, for UCRT.
    cc="${CC:-aarch64-w64-mingw32-clang}"
    strip_tool="${STRIP:-aarch64-w64-mingw32-strip}"
    verification_readobj="${READOBJ:-llvm-readobj}"
    cmake_args+=(
      -DCMAKE_SYSTEM_NAME=Windows
      -DCMAKE_SYSTEM_PROCESSOR=ARM64
      -DCMAKE_C_COMPILER="$cc"
      -DCMAKE_RC_COMPILER="${WINDRES:-aarch64-w64-mingw32-windres}"
      -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-insert-timestamp
    )
    output_name=lua_dart.dll
    ;;
esac

jobs="${LUADART_BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
cmake -S "$root" -B "$build_dir/cmake" "${cmake_args[@]}"
cmake --build "$build_dir/cmake" --target lua_dart --parallel "$jobs"
if [[ "$run_smoke" == true ]]; then
  cmake --build "$build_dir/cmake" --target luadart_smoke_test --parallel "$jobs"
  if [[ "$os" == macos && "$artifact_arch" == x86_64 && "$(uname -m)" == arm64 ]]; then
    arch -x86_64 "$build_dir/cmake/luadart_smoke_test"
  elif [[ "$os" == macos && "$artifact_arch" == arm64 && "$(uname -m)" == x86_64 ]]; then
    echo 'Skipping the arm64 smoke test on an x86_64 host.'
  else
    "$build_dir/cmake/luadart_smoke_test"
  fi
fi

built_artifact="$build_dir/cmake/$output_name"
[[ -f "$built_artifact" ]] || {
  echo "Expected library missing: $built_artifact" >&2
  exit 1
}
artifact="${LUADART_OUTPUT:-$root/build/native_artifacts/$target/$output_name}"
mkdir -p "$(dirname "$artifact")"
# A byte stream copy works the same on native hosts and container mounts.
cat "$built_artifact" > "$artifact"
chmod 755 "$artifact"
if [[ "$os" == macos || "$os" == ios ]]; then
  "$strip_tool" -x "$artifact"
else
  "$strip_tool" --strip-unneeded "$artifact"
fi

# The public surface is exactly the functions of src/lua_dart.h.
expected_exports="$build_dir/expected_exports.txt"
grep -oE '\bluadart_[a-z_0-9]+\(' "$root/src/lua_dart.h" | tr -d '(' | sort -u \
  > "$expected_exports"

if [[ "$os" == macos || "$os" == ios ]]; then
  actual_arch="$(lipo -archs "$artifact")"
  [[ "$actual_arch" == "$artifact_arch" ]] || {
    echo "Wrong architecture: expected $artifact_arch, got $actual_arch" >&2
    exit 1
  }
  install_name="$(otool -D "$artifact" | tail -1 | tr -d '[:space:]')"
  [[ "$install_name" == @rpath/liblua_dart.dylib ]] || {
    echo "Unexpected install name: $install_name" >&2
    exit 1
  }
  if otool -L "$artifact" | tail -n +2 | grep -E '/opt/homebrew|/usr/local'; then
    echo 'The library has a non-system dependency.' >&2
    exit 1
  fi
  nm -gU "$artifact" | awk '{print $3}' | sed 's/^_//' | sort > "$build_dir/actual_exports.txt"

  build_version="$(xcrun vtool -show-build "$artifact")"
  expected_platform=MACOS
  expected_min="$macos_version"
  if [[ "$os" == ios ]]; then
    expected_min="$ios_version"
    [[ "$target" == *-iphoneos ]] && expected_platform=IOS || expected_platform=IOSSIMULATOR
    # The arm64 iOS Simulator exists from iOS 14; ld records that minimum.
    if [[ "$target" == ios-arm64-iphonesimulator && "${ios_version%%.*}" -lt 14 ]]; then
      expected_min=14.0
    fi
  fi
  grep -q "platform $expected_platform" <<<"$build_version" || {
    echo "Missing Apple platform $expected_platform" >&2; exit 1;
  }
  awk -v expected="$expected_min" '$1 == "minos" && $2 == expected {found=1} END {exit !found}' <<<"$build_version" || {
    echo "Missing minimum OS $expected_min" >&2; exit 1;
  }
elif [[ "$os" == android || "$os" == linux ]]; then
  machine="$($verification_readelf -h "$artifact" | awk -F: '/Machine:/ {sub(/^[[:space:]]+/, "", $2); print $2}')"
  case "$target:$machine" in
    android-arm:'ARM') ;;
    android-arm64:'AArch64') ;;
    android-x64:'Advanced Micro Devices X86-64') ;;
    linux-arm64:'AArch64') ;;
    linux-x64:'Advanced Micro Devices X86-64') ;;
    *) echo "Unexpected ELF machine for $target: $machine" >&2; exit 1 ;;
  esac
  if "$verification_readelf" -d "$artifact" | grep -E 'NEEDED.*(libgcc_s|liblua)'; then
    echo 'The library has an unexpected dependency.' >&2
    exit 1
  fi
  if [[ "$os" == linux ]]; then
    "$verification_readelf" -d "$artifact" | grep 'SONAME.*liblua_dart.so' >/dev/null || {
      echo 'The Linux library has no liblua_dart.so SONAME.' >&2; exit 1;
    }
    if "$verification_readelf" -d "$artifact" | grep -E 'RPATH|RUNPATH'; then
      echo 'The Linux library has an RPATH or RUNPATH.' >&2; exit 1;
    fi
  fi
  if [[ "$os" == android ]]; then
    # Every LOAD segment is aligned for 16KB pages (Android 15+).
    "$verification_readelf" -lW "$artifact" \
      | awk '$1 == "LOAD" { print $NF }' > "$build_dir/load_alignments.txt"
    if [[ ! -s "$build_dir/load_alignments.txt" ]] || \
        grep -Evq '^0x0*4000$' "$build_dir/load_alignments.txt"; then
      echo 'ELF LOAD segments are not all 16KB-page aligned.' >&2
      exit 1
    fi
  fi
  "$verification_nm" -D --defined-only "$artifact" \
    | awk '{print $3}' | sed 's/@@.*//; /^LUA_DART_1$/d' | sort -u \
    > "$build_dir/actual_exports.txt"
elif [[ "$target" == windows-arm64 ]]; then
  "$verification_readobj" --file-headers "$artifact" \
    | grep -E 'Machine: IMAGE_FILE_MACHINE_ARM64 ' >/dev/null || {
      echo 'Unexpected PE machine: expected IMAGE_FILE_MACHINE_ARM64.' >&2; exit 1;
    }
  if "$verification_readobj" --coff-imports "$artifact" \
      | grep -Ei 'Name:.*(libunwind|libgcc_s|winpthread|lua)'; then
    echo 'The Windows library has an unexpected runtime dependency.' >&2
    exit 1
  fi
  "$verification_readobj" --coff-exports "$artifact" \
    | awk '$1 == "Name:" { print $2 }' | sort -u \
    > "$build_dir/actual_exports.txt"
elif [[ "$target" == windows-x64 ]]; then
  machine="$($verification_objdump -f "$artifact" | awk '/architecture:/ {gsub(",", "", $2); print $2}')"
  [[ "$machine" == i386:x86-64 ]] || {
    echo "Unexpected PE machine: $machine" >&2; exit 1;
  }
  if "$verification_objdump" -p "$artifact" \
      | grep -Ei 'DLL Name:.*(libgcc_s|winpthread|lua)'; then
    echo 'The Windows library has an unexpected runtime dependency.' >&2
    exit 1
  fi
  "$verification_objdump" -p "$artifact" \
    | awk '
        /\[Ordinal\/Name Pointer\] Table/ { exports=1; next }
        exports && /^\t\[[[:space:]]*[0-9]+\]/ { print $NF; next }
        exports && NF == 0 { exports=0 }
      ' | sort -u \
    > "$build_dir/actual_exports.txt"
fi

if ! diff -u "$expected_exports" "$build_dir/actual_exports.txt"; then
  echo 'The exports differ from the functions of src/lua_dart.h.' >&2
  exit 1
fi

strings "$artifact" | grep "lua_dart ABI 1; Lua $LUA_VERSION" >/dev/null || {
  echo 'The build-info string is missing or unexpected.' >&2
  exit 1
}

sha256="$(sha256_of "$artifact")"
size="$(wc -c < "$artifact" | tr -d ' ')"
echo "Built $artifact"
echo "target=$target"
echo "sha256=$sha256"
echo "size=$size"
