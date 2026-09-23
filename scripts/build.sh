#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. scripts/toolchain.sh
swift build -c release "$@"
BUILT_SDK="$(xcrun vtool -show-build .build/release/Bristle | awk '$1 == "sdk" { print $2; exit }')"
BUILT_SDK_MAJOR="${BUILT_SDK%%.*}"
if [ "$BUILT_SDK_MAJOR" -lt 26 ]; then
  printf 'The Bristle executable was linked against macOS SDK %s. Clean .build and rebuild with the selected SDK.\n' "$BUILT_SDK" >&2
  exit 1
fi
APP="$PWD/build/Bristle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Bristle "$APP/Contents/MacOS/Bristle"
# The Liquid Glass icon for macOS 26 and later; Bristle.icns covers earlier versions.
if ! xcrun actool Assets/Bristle.icon \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon Bristle \
  --output-partial-info-plist "$PWD/build/Bristle-icon-info.plist" >/dev/null; then
  rm -f "$APP/Contents/Resources/Assets.car"
fi
cp Assets/Bristle.icns "$APP/Contents/Resources/Bristle.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${BRISTLE_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$BRISTLE_VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
printf 'Built %s with macOS SDK %s\n' "$APP" "$BUILT_SDK"
