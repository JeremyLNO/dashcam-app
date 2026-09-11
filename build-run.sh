#!/bin/bash
# Regenerates the project, builds Dashcam for a simulator, installs and launches it.
# Extra arguments are passed through to the app (see LaunchArguments).
#
#   ./build-run.sh                                   plain launch
#   ./build-run.sh -uiTestReset -uiTestSeed          wipe, then seed a demo library
set -euo pipefail
cd "$(dirname "$0")"

PROJ="Dashcam"
DEVICE="${DASHCAM_DEVICE:-iPhone 17 Pro}"

python3 gen_pbxproj.py

DEV_ID=$(xcrun simctl list devices available | awk -F'[()]' -v dev="$DEVICE" '$0 ~ dev {print $2; exit}')
if [ -z "$DEV_ID" ]; then
  echo "No simulator matching '$DEVICE'. Available:"
  xcrun simctl list devices available
  exit 1
fi

xcodebuild \
  -project "$PROJ.xcodeproj" \
  -scheme "$PROJ" \
  -configuration Debug \
  -destination "id=$DEV_ID" \
  -sdk iphonesimulator \
  SYMROOT="$(pwd)/build" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcrun simctl boot "$DEV_ID" 2>/dev/null || true
open -a Simulator

APP_PATH="build/Debug-iphonesimulator/$PROJ.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist")

xcrun simctl install "$DEV_ID" "$APP_PATH"
xcrun simctl terminate "$DEV_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$DEV_ID" "$BUNDLE_ID" "$@"

echo "Launched $BUNDLE_ID on $DEVICE ($DEV_ID)"
echo "Note: the Simulator has no cameras — recording is only testable on a device."
