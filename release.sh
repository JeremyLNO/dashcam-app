#!/bin/bash
# Archives, exports and uploads a build to TestFlight.
#
# Two lessons are baked in:
#  * signing stays automatic — pinning CODE_SIGN_IDENTITY makes `archive` refuse to sign;
#  * an accepted upload is not a delivered build. The script waits for App Store Connect to
#    report the build and its processing state, because "no error from altool" has meant
#    "nothing arrived" before.
set -euo pipefail
cd "$(dirname "$0")"

KEY_ID="${ASC_KEY_ID:-88BAZ9XND3}"
ISSUER="${ASC_ISSUER_ID:-***ASC-ISSUER-ID-RETIRE***}"
APP_ID="6811080566"
BUILD=$(awk -F'= *' '/^CURRENT_PROJECT_VERSION/{print $2}' Config/Base.xcconfig | tr -d ' ')
VERSION=$(awk -F'= *' '/^MARKETING_VERSION/{print $2}' Config/Base.xcconfig | tr -d ' ')
ARCHIVE="build/Dashcam-$BUILD.xcarchive"
EXPORT="build/export-$BUILD"

echo "▸ Archiving $VERSION ($BUILD)"
python3 gen_pbxproj.py
xcodebuild archive -project Dashcam.xcodeproj -scheme Dashcam \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8" \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  | tail -3

echo "▸ Exporting"
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8" \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  | tail -3

IPA=$(find "$EXPORT" -name "*.ipa" | head -1)
[ -n "$IPA" ] || { echo "no ipa produced"; exit 1; }

echo "▸ Uploading $(basename "$IPA")"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER" | tail -3

echo "▸ Waiting for App Store Connect to report build $BUILD"
python3 - "$APP_ID" "$BUILD" "$KEY_ID" "$ISSUER" <<'PY'
import os, sys, time, jwt, requests
app_id, build, key_id, issuer = sys.argv[1:5]
key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")).read()
B = "https://api.appstoreconnect.apple.com"
def H():
    n = time.time()
    return {"Authorization": "Bearer " + jwt.encode(
        {"iss": issuer, "iat": int(n), "exp": int(n + 900), "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": key_id})}
deadline = time.time() + 3600
while time.time() < deadline:
    r = requests.get(f"{B}/v1/builds", headers=H(),
                     params={"filter[app]": app_id, "filter[version]": build, "limit": 1})
    data = r.json().get("data", [])
    if data:
        state = data[0]["attributes"]["processingState"]
        print(f"  build {build}: {state}", flush=True)
        if state != "PROCESSING":
            sys.exit(0 if state == "VALID" else 1)
    else:
        print("  not visible yet", flush=True)
    time.sleep(60)
print("  timed out waiting for the build")
sys.exit(1)
PY
