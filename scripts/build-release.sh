#!/usr/bin/env bash
# Build release archives for macOS (arm64, amd64) and Linux (arm64, amd64).
#
#   scripts/build-release.sh v1.1.0
#
# Run on macOS. macOS targets are built natively / cross-compiled with the local
# Odin; Linux targets are built in Ubuntu 22.04 containers (OrbStack or Docker
# Desktop) so the binaries only need glibc 2.35+. Output goes to dist/.
set -euo pipefail

VERSION="${1:?usage: build-release.sh <version, e.g. v1.1.0>}"
ODIN_TAG="${ODIN_TAG:-dev-2026-09}"   # Odin release used for the Linux builds
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
WORK="$DIST/.work"
NAME=spotify-history-report

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "working tree is dirty; commit first so the release matches a commit" >&2
  exit 1
fi

rm -rf "$DIST"; mkdir -p "$WORK/odin"

package() { # <os> <arch> <binary>
  local dir="$WORK/pkg/$NAME-$VERSION-$1-$2"
  mkdir -p "$dir"
  install -m 755 "$3" "$dir/$NAME"
  cp "$ROOT/LICENSE.md" "$ROOT/README.md" "$dir/"
  tar -C "$WORK/pkg" -czf "$DIST/$NAME-$VERSION-$1-$2.tar.gz" "$NAME-$VERSION-$1-$2"
}

echo "==> macOS arm64"
odin build "$ROOT/src" -out:"$WORK/macos-arm64" -o:speed
package macos arm64 "$WORK/macos-arm64"

echo "==> macOS amd64 (cross-compiled)"
odin build "$ROOT/src" -out:"$WORK/macos-amd64" -o:speed -target:darwin_amd64
package macos amd64 "$WORK/macos-amd64"

for arch in arm64 amd64; do
  echo "==> Linux $arch (container)"
  tarball="odin-linux-$arch-$ODIN_TAG.tar.gz"
  curl -fsSL -o "$WORK/odin/$tarball" \
    "https://github.com/odin-lang/Odin/releases/download/$ODIN_TAG/$tarball"
  docker run --rm --platform "linux/$arch" \
    -v "$ROOT":/src:ro -v "$WORK":/work ubuntu:22.04 bash -ec "
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null
      apt-get install -y -qq clang llvm lld libc6-dev >/dev/null
      mkdir /opt/odin && tar xzf /work/odin/$tarball -C /opt/odin --strip-components=1
      export PATH=/opt/odin:\$PATH
      cp -r /src /build && cd /build
      odin build src -out:/work/linux-$arch -o:speed
      /work/linux-$arch --help >/dev/null"
  package linux "$arch" "$WORK/linux-$arch"
done

(cd "$DIST" && shasum -a 256 ./*.tar.gz | sed 's#\./##' > SHA256SUMS)
rm -rf "$WORK"
echo; ls -la "$DIST"; cat "$DIST/SHA256SUMS"
