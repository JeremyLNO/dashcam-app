#!/usr/bin/env python3
"""Reports whether the CarPlay Driving Task entitlement has landed on the App ID.

Requested on 2026-09-12 (see docs/CARPLAY-ENTITLEMENT.md). Apple answers by email, but a
grant also shows up on the App ID as a new capability — this reads that, so the state can
be checked without opening a mailbox.

⚠️ The capability list is evidence of a grant, never proof of a refusal: Apple's answer
arrives by mail first, and a "no" leaves no trace here at all.

Baseline at request time: IN_APP_PURCHASE alone.
Exit code 0 = a CarPlay capability is present, 1 = not yet, 2 = could not tell.
"""
import os, sys, time, jwt, requests

KEY_ID = os.environ.get("ASC_KEY_ID", "88BAZ9XND3")
ISSUER = os.environ.get("ASC_ISSUER_ID", "***ASC-ISSUER-ID-RETIRE***")
BUNDLE = "dashcam.lno.company"
B = "https://api.appstoreconnect.apple.com"

try:
    key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")).read()
except OSError as exc:
    print(f"clé App Store Connect illisible : {exc}")
    sys.exit(2)

now = time.time()
token = jwt.encode({"iss": ISSUER, "iat": int(now), "exp": int(now + 900),
                    "aud": "appstoreconnect-v1"}, key, algorithm="ES256",
                   headers={"kid": KEY_ID})
r = requests.get(f"{B}/v1/bundleIds", headers={"Authorization": f"Bearer {token}"},
                 params={"filter[identifier]": BUNDLE, "include": "bundleIdCapabilities",
                         "limit": 10})
if r.status_code != 200:
    print(f"API {r.status_code}: {r.text[:200]}")
    sys.exit(2)

caps = sorted({i["attributes"].get("capabilityType")
               for i in r.json().get("included", [])
               if i["type"] == "bundleIdCapabilities" and i["attributes"].get("capabilityType")})
carplay = [c for c in caps if "CARPLAY" in c]
print("capacités:", ", ".join(caps) or "aucune")
if carplay:
    print("ACCORDÉ:", ", ".join(carplay))
    sys.exit(0)
print("pas encore de capacité CarPlay sur l'App ID")
sys.exit(1)
