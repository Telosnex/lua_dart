#!/usr/bin/env bash
# Compile and run the ABI-only smoke executable against the exact staged .so
# on a connected Android device/emulator. If no device is connected and
# LUADART_ANDROID_AVD is set, this script starts and later stops that AVD.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
adb="$sdk/platform-tools/adb"
emulator="$sdk/emulator/emulator"
ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$sdk/ndk/28.2.13676358}}"
[[ -x "$adb" ]] || { echo "adb not found: $adb" >&2; exit 1; }
[[ -d "$ndk" ]] || { echo "Android NDK not found: $ndk" >&2; exit 1; }

started_emulator=false
emulator_pid=
cleanup() {
  "$adb" shell 'rm -rf /data/local/tmp/lua_dart_smoke' >/dev/null 2>&1 || true
  if [[ "$started_emulator" == true && "${LUADART_KEEP_ANDROID_RUNNING:-0}" != 1 ]]; then
    "$adb" emu kill >/dev/null 2>&1 || true
    [[ -z "$emulator_pid" ]] || kill "$emulator_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! "$adb" get-state >/dev/null 2>&1; then
  avd="${LUADART_ANDROID_AVD:-}"
  [[ -n "$avd" ]] || {
    echo 'No Android device connected. Set LUADART_ANDROID_AVD to start one.' >&2
    exit 1
  }
  [[ -x "$emulator" ]] || { echo "emulator not found: $emulator" >&2; exit 1; }
  "$emulator" -avd "$avd" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect >"$root/build/android-emulator.log" 2>&1 &
  emulator_pid=$!
  started_emulator=true
  "$adb" wait-for-device
fi

for _ in $(seq 1 180); do
  [[ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
  sleep 1
done
[[ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] || {
  echo 'Android device did not finish booting.' >&2
  exit 1
}

abi="$("$adb" shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$abi" in
  arm64-v8a)
    target=android-arm64; compiler=aarch64-linux-android24-clang
    ;;
  armeabi-v7a)
    target=android-arm; compiler=armv7a-linux-androideabi24-clang
    ;;
  x86_64)
    target=android-x64; compiler=x86_64-linux-android24-clang
    ;;
  *) echo "Unsupported connected Android ABI: $abi" >&2; exit 1 ;;
esac

case "$(uname -s)" in
  Darwin) ndk_host=darwin-x86_64 ;;
  Linux) ndk_host=linux-x86_64 ;;
  *) echo 'Android runtime test requires macOS or Linux.' >&2; exit 1 ;;
esac
cc="$ndk/toolchains/llvm/prebuilt/$ndk_host/bin/$compiler"
artifact="$root/build/native_artifacts/$target/liblua_dart.so"
[[ -x "$cc" ]] || { echo "compiler not found: $cc" >&2; exit 1; }
[[ -f "$artifact" ]] || {
  echo "Missing $artifact; run tool/build_native_artifact.sh $target" >&2
  exit 1
}

build_dir="$root/build/android-device-smoke"
rm -rf "$build_dir"
mkdir -p "$build_dir"
"$cc" -std=c11 -O2 \
  -I"$root/src" "$root/native_test/smoke_test.c" \
  -L"$(dirname "$artifact")" -llua_dart -Wl,-rpath,'$ORIGIN' \
  -o "$build_dir/luadart_smoke_test"

remote=/data/local/tmp/lua_dart_smoke
"$adb" shell "rm -rf $remote && mkdir $remote"
"$adb" push "$build_dir/luadart_smoke_test" "$artifact" "$remote/" >/dev/null
"$adb" shell "chmod 755 $remote/luadart_smoke_test && cd $remote && LD_LIBRARY_PATH=. ./luadart_smoke_test"
echo "PASS: $target runtime-tested on Android API $("$adb" shell getprop ro.build.version.sdk | tr -d '\r')"
