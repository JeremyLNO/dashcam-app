# Testing on a real device

The Simulator has no cameras, no accelerometer worth the name, and — on the iOS 26.x
runtimes — no working StoreKit Testing. Everything below has to be exercised on hardware
before a release. The Simulator is enough for the library, the paywall layout, settings,
localization and export composition, and nothing else.

## Automated suites

```bash
./run-tests.sh                      # everything
./run-tests.sh DashcamTests         # unit only
./run-tests.sh DashcamUITests       # UI only
```

The script resolves an **iOS 18.6** simulator by default. That is not arbitrary:
`SKTestSession` is created successfully on the iOS 26.x runtimes but stays inert — an
empty `storefront`, and every product query returns nothing. The subscription tests detect
that and `XCTSkip` rather than pass silently. Override with `DASHCAM_DEVICE` /
`DASHCAM_RUNTIME` to test another runtime.

The script also shuts simulators down and lets them settle between runs. Back-to-back
`xcodebuild test` invocations otherwise fail with *"Application failed preflight checks
(Busy)"*, which reads exactly like a test failure and is not one.

## 1. MultiCam

Requires an A12 device or newer (iPhone XS and later).

* Launch, confirm both previews come up and the status tiles read **Ultra Wide** for the
  road camera. On a device with no ultra-wide lens it must fall back to **Wide**.
* Record for longer than one segment length and confirm in the library that the front and
  rear segment counts match and that segment *n* on each camera covers the same window.
* On a device that reports `isMultiCamSupported == false`, confirm the app says so and
  still records rear-only.

**What to watch for:** a combination that looks supported but is not. The app reads
`supportedMultiCamDeviceSets`; if a future device pairs cameras differently, this is where
it shows up.

## 2. Segmentation and resilience

* Record for 10 minutes at a 1-minute segment length. Expect 10 files per camera.
* Mid-recording, force-quit from the app switcher. Relaunch: the last segment may be gone
  or short, everything before it must play. `RecoveryManager` should log one closed
  session.
* Power the device off mid-recording (hold both buttons) and relaunch. Same expectation.

## 3. GPS

* Drive, or use Xcode's *Debug ▸ Simulate Location ▸ City Run*.
* Confirm the GPS tile shows a speed, and that the exported "with information" file carries
  a plausible speed that changes over the clip.
* Deny location and confirm recording is unaffected.

## 4. CoreMotion impact detection

Cannot be simulated meaningfully. On a real drive, with sensitivity on **Normal**:

* Go over a speed bump at a sane speed — should **not** trigger.
* Brake hard (safely, empty road) — should **not** trigger.
* Pick the phone up out of the cradle and put it back — should **not** trigger.
* Slap the cradle firmly with a flat hand — **should** trigger.

Every trigger creates a protected event covering the five minutes before and the two after.
Check the library afterwards.

## 5. Thermal pressure

* Record at **High** quality with both cameras, in sunlight, while charging.
* Watch for the "iPhone is warming up" alert. Expected order: quality drops one tier, then
  the cabin camera is shed, then recording stops. The road camera must be the last thing
  standing.
* `ThermalManager` also reacts to `AVCaptureMultiCamSession.systemPressureCost` reaching
  1.0, which usually arrives before the thermal state does.

## 6. Capture interruptions

* Take a phone call while recording.
* Open the Camera app from Control Center while recording.
* Lock the screen (the idle timer is disabled while recording, so this needs the side
  button).
* Revoke camera permission in Settings while the app is running.

Each must produce a clear message and a clean stop — never a half-written file.

## 7. Storage

* Set the cap to 5 GB and record past it. Oldest unprotected segments should disappear,
  protected ones must not.
* Fill the device to under 1 GB free and start recording. The app should refuse, or stop
  cleanly and finalize what it had.

## 8. StoreKit

**Sandbox (device):** sign in with a Sandbox Apple ID under *Settings ▸ Developer ▸ Sandbox
Apple Account*. Then:

* Subscribe → confirm the app reports **Free trial** and that **Export stays locked**.
* Let the trial convert (sandbox renews on an accelerated clock) → export unlocks.
* Cancel, refund, and re-subscribe; each must be reflected without relaunching.
* Restore Purchases on a second device.

**Local (Simulator, iOS 18.x):** the scheme references `Resources/Dashcam.storekit`; the
subscription unit tests drive the same file through `SKTestSession`.

## 9. CarPlay

Needs the `com.apple.developer.carplay-driving-task` entitlement — see
[APP-STORE.md](APP-STORE.md). Until Apple grants it, the CarPlay scene is simply never
created and the phone app is unaffected.

With the entitlement:

* Xcode ▸ Window ▸ Devices and Simulators, or a real head unit.
* Confirm START / STOP / PROTECT work and that the duration ticks.
* Confirm Maps, Waze or Google Maps keeps running alongside — Dashcam must never take over
  navigation.
