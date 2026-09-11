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

## What is deliberately absent

No navigation, no map, no route, no geocoding, no address search. No server. No account.
No automatic write to Photos. No background camera capture — iOS does not allow it, and
the app does not pretend otherwise; the discreet screen keeps the app in the foreground
and only removes the preview layers from the view hierarchy.
