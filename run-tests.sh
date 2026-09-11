#!/bin/bash
# Builds and runs the test suites on a clean simulator.
#
# Two things here are deliberate, not incidental:
#
#  * The default runtime is iOS 18.6. StoreKit Testing does not engage on the iOS 26.x
#    simulator runtimes — `SKTestSession` is created but stays inert, every product query
#    comes back empty — so the subscription tests can only run for real on 18.x. They
#    skip (loudly) anywhere else rather than pretending to pass.
#  * Simulators are shut down and allowed to settle between runs. Back-to-back
#    `xcodebuild test` invocations otherwise fail with "Application failed preflight
#    checks (Busy)", which looks exactly like a test failure and is not one.
#
# Usage: ./run-tests.sh [only-testing-spec]
set -uo pipefail
cd "$(dirname "$0")"

PROJ="Dashcam"
DEVICE_NAME="${DASHCAM_DEVICE:-iPhone 16 Pro}"
RUNTIME="${DASHCAM_RUNTIME:-iOS 18.6}"
ONLY="${1:-}"

python3 gen_pbxproj.py

# Resolve a UDID rather than a name: the same device name exists under several runtimes,
# and xcodebuild silently picks the newest one.
DEVICE_ID=$(xcrun simctl list devices available \
  | awk -v rt="-- $RUNTIME --" -v name="$DEVICE_NAME" '
      $0 == rt { inrt = 1; next }
      /^-- / { inrt = 0 }
      inrt && index($0, name " (") { match($0, /\(([-0-9A-F]+)\)/, m); print m[1]; exit }
    ' 2>/dev/null)

if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID=$(xcrun simctl list devices available | python3 -c "
import re, sys
runtime, name = sys.argv[1], sys.argv[2]
current = None
for line in sys.stdin:
    header = re.match(r'^-- (.+) --$', line.strip())
    if header:
        current = header.group(1)
        continue
    if current == runtime and line.strip().startswith(name + ' ('):
        print(re.search(r'\(([-0-9A-F]+)\)', line).group(1))
        break
" "$RUNTIME" "$DEVICE_NAME")
fi

if [ -z "$DEVICE_ID" ]; then
  echo "No simulator '$DEVICE_NAME' on '$RUNTIME'. Available:"
  xcrun simctl list devices available
  exit 1
fi
echo "Testing on $DEVICE_NAME ($RUNTIME) — $DEVICE_ID"

xcrun simctl shutdown all 2>/dev/null
sleep 6
xcrun simctl boot "$DEVICE_ID" 2>/dev/null
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1
sleep 4

ARGS=(-project "$PROJ.xcodeproj" -scheme "$PROJ" -configuration Debug
      -destination "id=$DEVICE_ID" -sdk iphonesimulator
      SYMROOT="$(pwd)/build" CODE_SIGNING_ALLOWED=NO)
if [ -n "$ONLY" ]; then ARGS+=(-only-testing:"$ONLY"); fi

xcodebuild test "${ARGS[@]}" 2>&1 \
  | grep -viE "CoreData: error" \
  | grep -E "Test Case .*(passed|failed|skipped)|error:|Failing tests|Executed [0-9]+ tests|\*\* TEST"
exit "${PIPESTATUS[0]}"
