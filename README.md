# Dashcam Pocket

An iOS dashcam. Start recording and the iPhone films the road through the rear ultra-wide
camera and the cabin through the front camera at the same time, in short self-contained
segments, entirely on the device.

No navigation. No map. No account. No server. Nothing is uploaded, ever.

---

## What it does

**Records both cameras at once** through `AVCaptureMultiCamSession`, ultra wide preferred
for the road with the wide lens as a fallback. Devices that cannot run two cameras
simultaneously say so and record the road only.

**Always records landscape.** Whichever way the phone is cradled, the file is a full
16:9 picture: the upright image is scaled to fill the frame and cropped top and bottom,
never letterboxed. A portrait mount still sees a narrower slice of the road than a
landscape one — no encoder can invent the sides the lens never captured — but what it does
see fills the frame. The preview and the recording both follow the phone as it turns, so
the horizon stays level.

**Cuts everything into segments** of 1, 3 or 5 minutes, finalized one by one, so a crash or
a power cut costs at most the segment being written. Front and rear segments carrying the
same index cover the same window — that pairing is what keeps the two-up player and the
picture-in-picture export honest.

**Protects an incident** with one big button: five minutes back and two minutes forward,
across as many files as that spans, including footage that has not been recorded yet. A
*detected* event — an impact, an emergency stop — uses a tight ten seconds either side
instead, because the sensor knows the exact instant and owes nothing to reaction time.
Protected footage is never deleted automatically, by any rule.

**Detects impacts and harsh braking** with CoreMotion, as two separate things. A collision
is a step — large, sharp, over in a tenth of a second. An emergency stop is a ramp. The
detector requires sharpness for one and duration for the other, so neither fires on the
other's signal, and both ignore speed bumps, vibration and the phone being picked up.

**Records what the drive felt like**: distance covered, peak G-force, and a G-force trace
kept as one peak per second. Each drive shows a timeline with a mark per event — tap one
and the player jumps there, instead of scrubbing two hours for a three-second incident.

**Cleans up after itself**: a retention age (7 days / 30 days / never), a storage cap
(5–50 GB or unlimited), and a hard floor of 1 GB free disk below which it stops rather than
corrupt anything.

**Keeps the originals clean.** Date, time, position and speed are stored as metadata, not
burned into the recordings. The overlay is rendered only into the file you choose to export
with information.

**Exports** the road camera, the cabin camera, both files, or a picture-in-picture
composition — whole, or just the last 30 seconds, the last minute, or a range you pick.
To the share sheet, Photos, Files, AirDrop, anywhere iOS offers.

**Proof mode** adds a JSON manifest listing the original recordings with their SHA-256
digests and the drive's metadata, so footage can be checked against what the device
actually wrote. It is not signed and carries no trusted timestamp, and it says so.

**Locks the library behind Face ID**, optionally. Recording, stopping and protecting stay
reachable without authenticating — those are the things you may need in a hurry.

**CarPlay**, optionally, as a three-button remote: Start, Stop, Protect. Nothing else.

**Starts itself when you get in the car** — with one honest caveat. The app detects the
CarPlay connection and begins recording, *if it is already open*; iOS gives no app the
power to launch itself. For a closed app, the three Shortcuts actions (Start Recording,
Stop Recording, Protect Footage) let the driver build a one-time personal automation —
"When CarPlay connects → Start Recording" — which does the whole job hands-free.

## Requirements

* iOS 17.0 or later
* Two cameras and an A12 chip or newer for dual recording (iPhone XS and up)
* Xcode 26

## Getting started

```bash
git clone git@github.com:JeremyLNO/dashcam-app.git
cd dashcam-app
python3 gen_pbxproj.py     # the project file is generated, never hand-edited
open Dashcam.xcodeproj
```

Then build and run on a **device** — the Simulator has no cameras and the app will say so.

```bash
./build-run.sh             # build, install and launch on a simulator
./run-tests.sh             # unit + UI suites
```

### Project generation

`Dashcam.xcodeproj/project.pbxproj` is produced by `gen_pbxproj.py`, which scans the source
tree. **Adding a file means creating it and re-running the script** — there is no Xcode
membership to forget, and no merge conflict in a 4000-line project file. UUIDs are hashes
of a role key, so successive runs are byte-identical.

### Configuration

Everything product-specific lives in `Config/*.xcconfig` and reaches the app through
`Info.plist`: bundle id, display name, subscription product ids, support and legal URLs,
the App Store id, and the OneSignal app id. Nothing of the sort is written in Swift.

Two xcconfig traps are worked around in `Base.xcconfig` and should not be "tidied up":
quotes become part of the value, and a literal `//` starts a comment — which is why URLs
are assembled through a `SLASH` variable.

## Layout

```
App/            entry point, object graph, root view
Core/           models, persistence, localization, formatting, logging
Capture/        AVFoundation graph, segment writers, recording, thermal management
Storage/        paths, the SwiftData index, measurement, retention, crash recovery
Location/       CoreLocation — metadata only
Motion/         CoreMotion impact detection
Protection/     protected-event windows
Export/         compositions, overlay rendering, export destinations
Subscriptions/  StoreKit 2
CarPlay/        optional remote-control scene
Notifications/  push (config-gated) and the 24-hour review prompt
Features/       Onboarding, Recording, Library, Settings, Paywall
UI/             design system
Tests/          unit tests
UITests/        UI tests
docs/           architecture, device testing, App Store submission
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for why the pipeline is shaped the way it
is.

## Subscription

One group, three durations, a 3-day free trial as an App Store introductory offer. Prices
always come from StoreKit.

One rule is worth stating plainly, because it is unusual and it is deliberate:

> **During the 3-day free trial, export is locked.** The trial is a free look at the
> dashcam itself — recording, reviewing, deleting, every setting. Getting footage *out* of
> the app is what the subscription buys, and it unlocks when the trial converts.

It lives in exactly one place, `SubscriptionState.canExport`, and nothing else in the app is
allowed to make that judgement. `Tests/SubscriptionStateTests.swift` and
`Tests/SubscriptionManagerTests.swift` guard it.

## Privacy

Video, audio, location and motion are produced and consumed on the device. There is no
server, no account, and no automatic write to Photos. `Resources/PrivacyInfo.xcprivacy`
declares no collected data.

Push notifications are configuration-gated: with `ONESIGNAL_APP_ID` empty, the SDK is never
initialised and no token is ever requested.

## Localization

English, French, Spanish, German, Portuguese, in a single String Catalog. The app follows
the device language and falls back to English; an explicit choice in Settings outranks the
device and is remembered. Changing it takes effect immediately, without a relaunch.

No user-facing string is written in a view — everything goes through `L10n`.

## Testing

```bash
./run-tests.sh                  # everything
./run-tests.sh DashcamTests     # unit only
```

The default simulator runtime is **iOS 18.6** on purpose: StoreKit Testing does not engage
on the iOS 26.x runtimes — `SKTestSession` is created but stays inert — so the subscription
tests can only run for real there. On any other runtime they skip loudly rather than
pretend to pass.

Camera, GPS, CoreMotion, thermal behaviour and CarPlay cannot be validated in a Simulator.
[docs/DEVICE-TESTING.md](docs/DEVICE-TESTING.md) is the checklist for a real device.

## Shipping

[docs/APP-STORE.md](docs/APP-STORE.md) covers the subscription setup, the CarPlay
entitlement request, the privacy answers and the App Review notes.

---

Built by [Crazy Bee Labs](https://crazybeelabs.com/) · [Support & ideas](https://crazybeelabs.com/support/)
