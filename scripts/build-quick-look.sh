#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  printf 'Usage: %s APP ARCH...\n' "$0" >&2
  exit 64
fi

APP="$1"
shift
SDK="$(xcrun --show-sdk-path)"
BUILD="$PWD/build/quick-look-xcode"
ARCHS=""
for ARCH in "$@"; do
  if [ -n "$ARCHS" ]; then ARCHS="$ARCHS;"; fi
  ARCHS="$ARCHS$ARCH"
done

cmake -S Sources/BristleQuickLook -B "$BUILD" -G Xcode \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES="$ARCHS" -DCMAKE_OSX_SYSROOT="$SDK" >/dev/null
cmake --build "$BUILD" --config Release --target BristleThumbnail BristlePreview -- \
  CODE_SIGNING_ALLOWED=NO >/dev/null

mkdir -p "$APP/Contents/PlugIns"

build_extension() {
  NAME="$1"
  EXTENSION="$APP/Contents/PlugIns/$NAME.appex"
  rm -rf "$EXTENSION"
  cp -R "$BUILD/Release/$NAME.appex" "$EXTENSION"
  if [ -n "${BRISTLE_VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$BRISTLE_VERSION" "$EXTENSION/Contents/Info.plist"
  fi
  if [ -n "${BRISTLE_BUILD_NUMBER:-}" ]; then
    plutil -replace CFBundleVersion -string "$BRISTLE_BUILD_NUMBER" "$EXTENSION/Contents/Info.plist"
  fi
  codesign --force --sign - --entitlements Sources/BristleQuickLook/QuickLook.entitlements "$EXTENSION"
}

build_extension BristleThumbnail
build_extension BristlePreview
