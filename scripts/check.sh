#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

. scripts/toolchain.sh

BRISTLE_CHECKS=1 ./scripts/build.sh
# Command Line Tools installs don't always find Swift Testing's macros on their own.
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS"
else
  swift test
fi

APP="build/Bristle.app/Contents/MacOS/Bristle"
# The checks use the default settings, whatever yours are.
IGNORE_STATE="-ApplePersistenceIgnoreState YES -returnsToSelect NO -snapsToGrid NO -showsGrid NO -paperSize standard -transparentBackground NO"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck disable=SC2086
BRISTLE_LAUNCH_CHECK=1 "$APP" $IGNORE_STATE
# shellcheck disable=SC2086
BRISTLE_SAVE_CHECK="$ROOT" "$APP" $IGNORE_STATE
sips -s format jpeg Assets/Bristle-Liquid.png --out "$ROOT/photo.jpg" >/dev/null
cp Assets/Bristle-Liquid.png "$ROOT/plain.png"
# shellcheck disable=SC2086
BRISTLE_OPEN_CHECK="$ROOT/plain.png" "$APP" $IGNORE_STATE
for FILE in Drawing.bristle Drawing.png plain.png photo.jpg; do
  # shellcheck disable=SC2086
  BRISTLE_ROUNDTRIP_CHECK="$ROOT/$FILE" "$APP" $IGNORE_STATE
done
# shellcheck disable=SC2086
BRISTLE_STALE_CHECK="$ROOT" "$APP" $IGNORE_STATE
# shellcheck disable=SC2086
BRISTLE_CLICK_CHECK=1 "$APP" $IGNORE_STATE
# shellcheck disable=SC2086
BRISTLE_PERF_CHECK=1 "$APP" $IGNORE_STATE

# Restoring after quitting runs in a copy of the app with its own identifier, so it never
# touches your own windows and drafts.
SESSION_APP="$ROOT/Bristle Checks.app"
cp -R build/Bristle.app "$SESSION_APP"
plutil -replace CFBundleIdentifier -string io.github.PoteNad.bristle.checks "$SESSION_APP/Contents/Info.plist"
codesign --force --sign - "$SESSION_APP" 2>/dev/null
SESSION_STATE="$HOME/Library/Saved Application State/io.github.PoteNad.bristle.checks.savedState"
rm -rf "$SESSION_STATE"
BRISTLE_SESSION_PREPARE=1 "$SESSION_APP/Contents/MacOS/Bristle" -NSQuitAlwaysKeepsWindows YES -returnsToSelect NO
BRISTLE_SESSION_VERIFY=1 "$SESSION_APP/Contents/MacOS/Bristle" -NSQuitAlwaysKeepsWindows YES -returnsToSelect NO
rm -rf "$SESSION_STATE"
defaults delete io.github.PoteNad.bristle.checks >/dev/null 2>&1 || true

./scripts/build.sh
printf 'All checks passed.\n'
