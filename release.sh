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
ISSUER="${ASC_ISSUER_ID:-$( [ -f "$HOME/.appstoreconnect/issuer_id" ] && cat "$HOME/.appstoreconnect/issuer_id" )}"
[ -n "$ISSUER" ] || { echo "ASC_ISSUER_ID absent : exporter la variable, ou écrire l'issuer ID dans ~/.appstoreconnect/issuer_id (chmod 600). Ce dépôt est public, il n'y revient pas." >&2; exit 1; }
APP_ID="6811080566"
# Minutes écoulées depuis le 2023-11-14 : strictement croissant (~525 000/an) et partagé
# avec .github/workflows/testflight.yml, donc un build local et un build CI ne se croisent
# jamais. Surtout ne pas relire CURRENT_PROJECT_VERSION depuis Config/Base.xcconfig : ces
# numéros à deux chiffres passent SOUS ceux de la CI, et TestFlight trie par NUMÉRO, pas par
# date d'upload — les testeurs resteraient sur le build précédent, l'upload disant « succès ».
BUILD=$(( ($(date +%s) - 1700000000) / 60 ))
VERSION=$(awk -F'= *' '/^MARKETING_VERSION/{print $2}' Config/Base.xcconfig | tr -d ' ')
ARCHIVE="build/Dashcam-$BUILD.xcarchive"
EXPORT="build/export-$BUILD"

echo "▸ Archiving $VERSION ($BUILD)"
python3 gen_pbxproj.py
xcodebuild archive -project Dashcam.xcodeproj -scheme Dashcam \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD" \
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
