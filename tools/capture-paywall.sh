#!/bin/bash
# Produces screenshots/08-paywall.png — the App Store review screenshot Apple wants
# attached to every subscription.
#
# It has to go through `xcodebuild test` rather than `simctl launch`: the StoreKit
# configuration is attached to the scheme, and launching the app directly bypasses it,
# leaving the paywall with no products to show.
#
# iPhone 16 Pro on iOS 18.6 is not arbitrary either — StoreKit Testing stays inert on the
# iOS 26.x runtimes, and a 16 Plus booted fresh answered no product queries at all.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME="${DASHCAM_DEVICE:-iPhone 16 Pro}"
RUNTIME="${DASHCAM_RUNTIME:-iOS 18.6}"
OUT="screenshots/08-paywall.png"

DEVICE_ID=$(xcrun simctl list devices available | python3 -c "
import re, sys
runtime, name = sys.argv[1], sys.argv[2]
current = None
for line in sys.stdin:
    header = re.match(r'^-- (.+) --$', line.strip())
    if header:
        current = header.group(1); continue
    if current == runtime and line.strip().startswith(name + ' ('):
        print(re.search(r'\(([-0-9A-F]+)\)', line).group(1)); break
" "$RUNTIME" "$DEVICE_NAME")
[ -n "$DEVICE_ID" ] || { echo "No simulator '$DEVICE_NAME' on '$RUNTIME'"; exit 1; }

python3 gen_pbxproj.py
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1

rm -rf build/paywall.xcresult
xcodebuild test -project Dashcam.xcodeproj -scheme Dashcam -configuration Debug \
  -destination "id=$DEVICE_ID" -sdk iphonesimulator SYMROOT="$(pwd)/build" \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath build/paywall.xcresult \
  -only-testing:DashcamUITests/PaywallScreenshotUITests \
  | grep -E "Test Case .*(passed|failed)|error:|\*\* TEST"

rm -rf build/paywall-attachments
xcrun xcresulttool export attachments --path build/paywall.xcresult \
  --output-path build/paywall-attachments >/dev/null
PNG=$(find build/paywall-attachments -name "*.png" | head -1)
[ -n "$PNG" ] || { echo "no screenshot in the result bundle"; exit 1; }
cp "$PNG" "$OUT"
echo "$OUT  $(sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr -d ' \n')"
