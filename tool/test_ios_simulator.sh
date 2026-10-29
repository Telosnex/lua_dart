#!/usr/bin/env bash
# Compile the ABI-only smoke executable for the host's iOS Simulator
# architecture, boot an available simulator, and execute against the exact
# staged dylib. The simulator is shut down only if this script booted it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || {
  echo 'iOS Simulator testing requires macOS/Xcode.' >&2
  exit 1
}
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 1; }

case "$(uname -m)" in
  arm64)
    arch_name=arm64
    target=ios-arm64-iphonesimulator
    minimum=14.0
    ;;
  x86_64)
    arch_name=x86_64
    target=ios-x64-iphonesimulator
    minimum=13.0
    ;;
  *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac

artifact="$root/build/native_artifacts/$target/liblua_dart.dylib"
[[ -f "$artifact" ]] || {
  echo "Missing $artifact; run tool/build_native_artifact.sh $target" >&2
  exit 1
}

# Prefer an already-booted available iOS simulator; otherwise choose a device
# from the newest installed iOS runtime.
devices_json="$(xcrun simctl list devices available -j)"
read -r udid initial_state < <(python3 -c '
import json, re, sys
obj = json.load(sys.stdin)
candidates = []
for runtime, devices in obj["devices"].items():
    if "SimRuntime.iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in re.findall(r"\d+", runtime.rsplit("iOS-", 1)[-1]))
    for device in devices:
        if device.get("isAvailable", True):
            candidates.append((device.get("state") == "Booted", version, device))
if not candidates:
    raise SystemExit("No available iOS simulator")
candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
device = candidates[0][2]
print(device["udid"], device.get("state", "Shutdown"))
' <<<"$devices_json")

booted_here=false
cleanup() {
  if [[ "$booted_here" == true && "${LUADART_KEEP_SIMULATOR_BOOTED:-0}" != 1 ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$initial_state" != Booted ]]; then
  xcrun simctl boot "$udid"
  booted_here=true
fi
xcrun simctl bootstatus "$udid" -b

build_dir="$root/build/ios-simulator-smoke"
rm -rf "$build_dir"
mkdir -p "$build_dir"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
cc="$(xcrun --sdk iphonesimulator -f clang)"
"$cc" \
  -std=c11 -arch "$arch_name" \
  -mios-simulator-version-min="$minimum" -isysroot "$sdk_path" \
  -I"$root/src" "$root/native_test/smoke_test.c" "$artifact" \
  -Wl,-rpath,@executable_path \
  -o "$build_dir/luadart_smoke_test"
cp "$artifact" "$build_dir/liblua_dart.dylib"
codesign -s - --force \
  "$build_dir/luadart_smoke_test" "$build_dir/liblua_dart.dylib" >/dev/null

xcrun simctl spawn "$udid" "$build_dir/luadart_smoke_test"
echo "PASS: $target runtime-tested on simulator $udid"
