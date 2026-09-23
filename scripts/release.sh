#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s VERSION\n' "$0" >&2
  exit 64
fi
VERSION="$1"
DIST="$PWD/dist"
STAGE="$DIST/staging"
APP="$STAGE/Bristle.app"
ARCHIVE_NAME="Bristle-$VERSION-macOS.zip"
DISK_IMAGE_NAME="Bristle-$VERSION-macOS.dmg"
ARCHIVE="$DIST/$ARCHIVE_NAME"
DISK_IMAGE="$DIST/$DISK_IMAGE_NAME"

# Checks the SDK and sets BRISTLE_SDK_VERSION for Package.swift.
. scripts/toolchain.sh

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  swift build -c release --arch "$ARCH" --scratch-path ".build-release-$ARCH" --product Bristle
done
lipo -create \
  .build-release-arm64/release/Bristle \
  .build-release-x86_64/release/Bristle \
  -output "$APP/Contents/MacOS/Bristle"
for ARCH in arm64 x86_64; do
  BUILT_SDK="$(xcrun vtool -arch "$ARCH" -show-build "$APP/Contents/MacOS/Bristle" | awk '$1 == "sdk" { print $2; exit }')"
  if [ "${BUILT_SDK%%.*}" -lt 26 ]; then
    printf 'The %s executable was linked against macOS SDK %s.\n' "$ARCH" "$BUILT_SDK" >&2
    exit 1
  fi
done
printf 'Linked against macOS SDK %s\n' "$BRISTLE_SDK_VERSION"

xcrun actool Assets/Bristle.icon \
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon Bristle \
  --output-partial-info-plist "$DIST/Bristle-icon-info.plist" >/dev/null
cp Assets/Bristle.icns "$APP/Contents/Resources/Bristle.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ARCHIVE" "$DISK_IMAGE" "$DIST/Bristle-macOS.zip" "$DIST/Bristle-macOS.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
cp "$ARCHIVE" "$DIST/Bristle-macOS.zip"
(cd "$DIST" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
hdiutil create -volname Bristle -srcfolder "$STAGE" -ov -format UDZO "$DISK_IMAGE"
cp "$DISK_IMAGE" "$DIST/Bristle-macOS.dmg"
(cd "$DIST" && shasum -a 256 "$DISK_IMAGE_NAME" > "$DISK_IMAGE_NAME.sha256")
printf 'Created %s and %s\n' "$ARCHIVE" "$DISK_IMAGE"
