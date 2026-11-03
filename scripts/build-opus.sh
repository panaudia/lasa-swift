#!/bin/sh
# libopus from source as opus.xcframework: ios-arm64, ios-arm64-simulator
# and macos-arm64 slices, static, float-approx, no headers (the COpus
# target carries them). The BSD-3-Clause notice goes in beside the
# slices. Usage: scripts/build-opus.sh [version]   (default 1.5.2)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
VER=${1:-${OPUS_VERSION:-1.5.2}}
WORK="$ROOT/.build/opus"
SRC="$WORK/opus-$VER"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

mkdir -p "$WORK"
if [ ! -d "$SRC" ]; then
  (cd "$WORK" && curl -fLO "https://downloads.xiph.org/releases/opus/opus-$VER.tar.gz" && tar xzf "opus-$VER.tar.gz")
fi

build_slice() { # name, sdk, min-flag, host
  slice=$1; sdk=$2; minflag=$3; host=$4
  prefix="$WORK/$slice"
  rm -rf "$prefix"; mkdir -p "$prefix"
  cc="$(xcrun --sdk "$sdk" --find clang) -arch arm64 -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) $minflag"
  (cd "$SRC" && make distclean >/dev/null 2>&1 || true)
  (cd "$SRC" && CC="$cc" ./configure --host="$host" --prefix="$prefix" \
      --disable-shared --enable-static --disable-doc --disable-extra-programs \
      --enable-float-approx >/dev/null && make -j8 >/dev/null && make install >/dev/null)
  echo "built $slice"
}

build_slice ios-arm64           iphoneos        "-mios-version-min=26.0"            arm64-apple-darwin
build_slice ios-arm64-simulator iphonesimulator "-mios-simulator-version-min=26.0"  arm64-apple-darwin
build_slice macos-arm64         macosx          "-mmacosx-version-min=26.0"         arm64-apple-darwin

rm -rf "$ROOT/opus.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/ios-arm64/lib/libopus.a" \
  -library "$WORK/ios-arm64-simulator/lib/libopus.a" \
  -library "$WORK/macos-arm64/lib/libopus.a" \
  -output "$ROOT/opus.xcframework"
cp "$SRC/COPYING" "$ROOT/opus.xcframework/COPYING.opus"
cp "$SRC/COPYING" "$ROOT/LICENSES/opus.txt"
echo "opus.xcframework written ($VER)"
