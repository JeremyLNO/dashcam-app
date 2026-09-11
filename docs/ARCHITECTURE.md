# Architecture

## Shape

```
App/            entry point, object graph, root view, launch flags
Core/
  Models/       SwiftData entities + the settings value types
  Persistence/  container construction, settings store
  Support/      configuration, localization, formatters, logging, demo seeding
Capture/        AVFoundation graph, segment writers, recording orchestration, thermal
Storage/        paths, index (the only SwiftData writer), measurement, retention, recovery
Location/       CoreLocation, metadata only
Motion/         CoreMotion impact detection
Protection/     protected-event windows
Export/         compositions, overlay rendering, export + destinations
Subscriptions/  StoreKit 2
CarPlay/        optional remote-control scene
Notifications/  push (config-gated) + the 24-hour review prompt
Features/       SwiftUI screens: Onboarding, Recording, Library, Settings, Paywall
UI/             design system
```

## The capture pipeline

```
AVCaptureMultiCamSession
  ├── rear device (ultra wide, wide as fallback)  ─► AVCaptureVideoDataOutput ─┐
  ├── front device                                ─► AVCaptureVideoDataOutput ─┤
  └── microphone (optional)                       ─► AVCaptureAudioDataOutput ─┤
                                                                               │
                                          SampleRouter (non-isolated) ◄────────┘
                                                      │
                                              RecordingEngine
                                          ┌───────────┴───────────┐
                                   SegmentWriter(rear)    SegmentWriter(front)
                                          │                       │
                                   rear_0000.mov …         front_0000.mov …
                                          └───────────┬───────────┘
                                                RecordingManager
                                             (indexes each finalized
                                              segment, runs sweeps,
                                              applies protection)
```

Decisions worth knowing:

**Data outputs, not `AVCaptureMovieFileOutput`.** Segmenting a movie file output means
stopping and restarting it, which drops frames at every boundary. Feeding an
`AVAssetWriter` lets the writer cut on a frame boundary with no gap.

**Segment boundaries are computed, not negotiated.** Each writer derives the boundary
from the same `(firstPTS, segmentDuration)` arithmetic, so segment *n* on the front camera
covers the same wall-clock window as segment *n* on the rear — with no shared lock and no
cross-talk between the two writers. That index pairing is what the two-up player and the
picture-in-picture export rely on.

**Nothing about the multi-cam combination is assumed.** `CaptureManager` reads
`AVCaptureDevice.DiscoverySession.supportedMultiCamDeviceSets` and picks a set that pairs
a back and a front camera, preferring ultra wide. No usable set, or
`isMultiCamSupported == false`, degrades to rear-only with a message — never a failure.

**Orientation is tracked live, not sampled once.** Two `AVCaptureDevice.RotationCoordinator`
instances (one per camera) report, continuously, the angle each connection needs to keep
the horizon level. The preview angle goes to the preview layer connections; the capture
angle goes to the video data output connections, so the frames arriving at the writers are
already upright. Turning the phone in its cradle therefore changes the recording
immediately, rather than being frozen at whatever angle Start was pressed at.

That choice has a consequence: rotating the connection changes the shape of the delivered
frames, and an `AVAssetWriterInput` has fixed dimensions for its whole lifetime. So
`SegmentWriter` reads the dimensions off each sample buffer and cuts a new segment when
they change — the same machinery that handles a scheduled boundary, triggered by geometry
instead of by the clock. The segment *index* stays put so the front/rear pairing survives;
the file name takes a `-1` suffix instead.

Landscape is the primary orientation: a windscreen cradle holds the phone sideways, the
recording screen has a layout built for it, and `UISupportedInterfaceOrientations` lists
landscape first. Portrait is fully supported — plenty of cradles hold the phone upright —
and the pipeline follows the device either way. Upside-down is deliberately excluded.

A quality tier is expressed as a **short side** (720 or 1080) rather than a width and a
height, so "1080p" costs the same and looks the same whichever way the phone is mounted.

**Wall-clock mapping is anchored once.** The capture clock is monotonic and unrelated to
`Date()`. Each writer records `(firstPTS, firstSampleDate)` and derives every segment
timestamp from that, instead of calling `Date()` per sample and drifting against the
footage.

## Concurrency

`@MainActor` for anything that publishes to SwiftUI or writes to SwiftData; plain serial
`DispatchQueue`s for the capture graph and the writers. The two never cross: the capture
queues touch no main-actor state (hence `SampleRouter` and the `nonisolated(unsafe)`
markings in `CaptureManager`, each of which is a statement that the object is confined to
`sessionQueue`), and `@Published` mutations only ever happen on the main actor.

`async/await` is used at the seams — configuration, export, recovery, StoreKit — where
there is a genuine suspension to express.

## Persistence

SwiftData holds **metadata only**: sessions, segments, protected events, GPS samples.
Video bytes live under `Application Support/Recordings/<session-uuid>/` and are referenced
by **relative** path, because iOS re-roots the app container between launches and after a
restore — an absolute URL persisted today points nowhere tomorrow.

`SessionIndex` is the single writer. The write rate is a handful of rows per minute, so
one main-actor writer costs nothing and removes a whole class of "two contexts disagree"
bugs.

Preferences live in `UserDefaults` via `SettingsStore` — the platform's own preference
database, and the only store that can answer synchronously from the recording HUD and the
CarPlay scene.

## Deletion safety

Three things are never deleted automatically, checked in this order:

1. a protected segment, whatever rule wanted it gone;
2. a segment reserved in `ActiveFileRegistry` — currently being recorded, or being read by
   an export;
3. beyond those, oldest first.

The floor on free disk space (1 GB) overrides the user's retention choice, because the
alternative is a failed write mid-drive.

## Resilience

Each segment is finalized individually, so a crash or a power cut costs at most the
segment being written. `movieFragmentInterval` means even that one is often recoverable.
On the next launch `RecoveryManager` reconciles disk and database in both directions:
orphan files are adopted, unreadable ones removed, sessions left open are closed, and rows
whose file has vanished are dropped — that last one is what stops the library listing
drives that play nothing.

## Protection windows

How far a protection reaches depends on *who* triggered it, not on what happened:

| Origin | Back | Forward | Why |
|---|---|---|---|
| Manual button, CarPlay | 5 min | 2 min | A person presses it after realising something happened — seconds to minutes late. |
| Impact, harsh braking | 10 s | 10 s | The accelerometer timestamps the instant itself. There is no reaction delay to pay for. |

One caveat worth knowing: protection marks whole **segments**, not slices of time. A
ten-second window around an impact keeps whichever segment contains it — one or two files,
so up to a few minutes of footage at a 3-minute segment length. Shortening the window
reduces how much is pinned, it does not carve out a 20-second clip. Use Export ▸ custom
range for that.

## Lifetime, and footage that exists but is invisible

A `SegmentWriter` must outlive its own finalization. Its `stop()` hands work to a serial
queue, and the `.mov` is only completed — and only reported — when that work runs. With a
weak self-capture there, and with `RecordingEngine.stop` dropping its references as soon as
it returned, the writer could be deallocated in between. The file was still on disk,
created by `startWriting()`, but never finalized and never announced: **the footage existed
and the database never learned it did**, which on screen is indistinguishable from a camera
that did not record.

Its worst property was being a race. The road camera usually won and the cabin usually lost,
so it read as "the front camera does not work" rather than as a lifetime bug. It took a test
that drove the engine with synthetic frames and compared the callbacks against the files on
disk — the two disagreed, and that gap was the answer.

## A coordinate space that bites

A video composition's **layer-instruction transforms live in a top-left origin space** —
unlike Core Graphics, and unlike the Core Animation layer tree used for the overlay, both
of which put the origin bottom-left. Computing the cabin inset as
`y = renderHeight - insetHeight - margin` therefore put it in the *bottom*-right corner
while every geometry test passed, because those tests asserted arithmetic about where a
layer should land rather than where it actually landed.

`PictureInPictureRenderTests` renders a frame from two differently coloured clips and
samples the pixels. It is the only kind of test that could have caught this.

## Evidence

Each segment is hashed (SHA-256) just after it is finalized, off the main actor at utility
priority so it never competes with the two camera streams still writing. A "proof mode"
export writes a `ProofManifest` beside the video: the original files, their digests, the
drive's timing, distance, peak G-force, events and GPS trace.

The manifest deliberately claims nothing it cannot back up. There is no signature and no
trusted timestamp — both would need a server, and this app has none by design. What it
says is "these are the files, this is what they hashed to, here is what the device
observed", and it states that limit in its own `notes` field.

## Detection

Impact and harsh braking come out of the same accelerometer stream and are separated by
shape, not by amplitude: a collision is a step (sharp, brief), an emergency stop is a ramp
(smooth, sustained). The excursion window opens at the *lower* of the two entry levels —
otherwise the braking path would be unreachable behind the impact threshold — and each
detector then applies its own rule. A gyroscope check rejects both when the phone is being
handled rather than driven.

## What is deliberately absent

No navigation, no map, no route, no geocoding, no address search. No server. No account.
No automatic write to Photos. No background camera capture — iOS does not allow it, and
the app does not pretend otherwise; the discreet screen keeps the app in the foreground
and only removes the preview layers from the view hierarchy.
