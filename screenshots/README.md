# App Store screenshots

Captured on an **iPhone 16 Plus simulator (iOS 18.6)**, which renders natively at
**1290 × 2796** — the 6.9" slot App Store Connect accepts (API display type
`APP_IPHONE_67`). Apple scales that one set down for every smaller device, so no other
size is needed.

English, per the house default for store assets.

| File | Screen |
|---|---|
| `01-onboarding.png` | "Turn your iPhone into a dashcam" |
| `02-library.png` | Drives list: distance, size, event badges, storage summary |
| `03-drive-timeline.png` | One drive: two-up player, timeline with its events, distance and peak G-force |
| `04-protected.png` | The Protected shelf |
| `05-settings.png` | Storage limits, retention, impact and harsh-braking detection, Face ID lock |
| `06-protection.png` | "Automatic protection" |
| `07-privacy.png` | "Privacy first" |

## Reproducing them

```bash
xcodebuild -project Dashcam.xcodeproj -scheme Dashcam -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Plus,OS=18.6' \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

xcrun simctl install <UDID> build/Debug-iphonesimulator/Dashcam.app
xcrun simctl launch  <UDID> dashcam.lno.company.dev \
  -screenshotSeed -uiTestSkipOnboarding -settings.language en
```

`-screenshotSeed` stages four drives with plausible distances, a peak G-force, an impact
and a harsh-braking event. Every number it puts on screen is internally consistent — the
clips it writes are real 1080p files sized to match the story their metadata tells, so no
row ever reads "9 segments · 29 KB". It takes about two minutes to write.

Then drive the UI with the simulator MCP (taps in **points**: 430 × 932) and capture with
`xcrun simctl io <UDID> screenshot`.

## The one that is missing

**The recording screen.** It is the shot that sells a dashcam — two live camera previews,
REC running — and the Simulator has no cameras, so it renders "Camera capture is not
available in the Simulator" instead. It has to come off a real device.

The catch is the pixel size. App Store Connect takes **1290 × 2796** or **1320 × 2868**;
an iPhone 16 Pro screenshots at 1206 × 2622, which is accepted nowhere. Either capture on
a 6.9" device (iPhone 16 Plus, 15 Pro Max, 14 Pro Max, 16 Pro Max…), or rescale:

```bash
sips -Z 2796 record.png --out record-1290.png      # fit the long edge
sips -c 2796 1290 record-1290.png                  # centre-crop to exactly 1290×2796
```

The two aspect ratios differ by 0.3 %, so the crop costs a few pixels at the edges and
nothing visible.
