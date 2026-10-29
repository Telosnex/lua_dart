#!/usr/bin/env bash
# Installs the Linux and Windows build toolchain in the pinned Debian
# containers of the release workflow (through tool/kiln/prepare.dart), as
# root.
#
# windows-arm64 installs llvm-mingw at /opt/llvm-mingw; add
# /opt/llvm-mingw/bin to PATH. GCC has no Windows arm64 target.
set -euo pipefail

target="${1:-}"
packages=(build-essential ca-certificates cmake curl git make xz-utils)
case "$target" in
  linux-x64|linux-arm64|windows-arm64) ;;
  windows-x64)
    packages+=(gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64)
    ;;
  *)
    echo "Usage: $0 <linux-x64|linux-arm64|windows-x64|windows-arm64>" >&2
    exit 64
    ;;
esac

# Debian 11 is past its end of life: its packages are on archive.debian.org.
if grep -q '^VERSION_CODENAME=bullseye$' /etc/os-release; then
  cat > /etc/apt/sources.list <<'SOURCES'
deb http://archive.debian.org/debian bullseye main
deb http://archive.debian.org/debian bullseye-updates main
deb http://archive.debian.org/debian-security bullseye-security main
SOURCES
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends "${packages[@]}" >/dev/null

if [[ "$target" == windows-arm64 ]]; then
  # llvm-mingw's Linux builds need glibc 2.35+, so this target uses the
  # Debian 12 image.
  release=20260922
  case "$(uname -m)" in
    aarch64)
      host=aarch64
      sha256=07d21263c56bfe9a713db6fdb3f7434bf4c121a005e40397d3b4c0170fb06769
      ;;
    x86_64)
      host=x86_64
      sha256=bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21
      ;;
    *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  name="llvm-mingw-$release-ucrt-ubuntu-22.04-$host"
  curl -fsSL -o /tmp/llvm-mingw.tar.xz \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/$release/$name.tar.xz"
  echo "$sha256  /tmp/llvm-mingw.tar.xz" | sha256sum -c -
  rm -rf "/opt/$name" /opt/llvm-mingw
  tar -xJf /tmp/llvm-mingw.tar.xz -C /opt
  mv "/opt/$name" /opt/llvm-mingw
  rm /tmp/llvm-mingw.tar.xz
  /opt/llvm-mingw/bin/aarch64-w64-mingw32-clang --version | head -1
fi

if [[ "$target" == linux-* ]]; then
  gcc -dumpfullversion | grep "^12\."
fi
