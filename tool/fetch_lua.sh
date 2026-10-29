#!/usr/bin/env bash
# Downloads the pinned Lua release into third_party/ and checks its SHA-256.
# Only standalone builds use it; the build hook gets the same file from the
# kiln cache (native_artifacts/sources.json).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tool/lua_pin.sh
source "$root/tool/lua_pin.sh"
dest="${LUADART_THIRD_PARTY:-$root/third_party}"
tarball="$dest/lua-$LUA_VERSION.tar.gz"

sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mkdir -p "$dest"
if [[ ! -f "$tarball" || "$(sha256_of "$tarball")" != "$LUA_SHA256" ]]; then
  curl -fsSL -o "$tarball.partial" "$LUA_URL"
  actual="$(sha256_of "$tarball.partial")"
  if [[ "$actual" != "$LUA_SHA256" ]]; then
    rm -f "$tarball.partial"
    echo "PIN MISMATCH: $LUA_URL has sha256 $actual, expected $LUA_SHA256" >&2
    exit 1
  fi
  mv "$tarball.partial" "$tarball"
fi
echo "$tarball"
