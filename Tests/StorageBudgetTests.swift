import XCTest
@testable import Dashcam

/// The arithmetic that decides whether recording may start, and for how long.
final class StorageBudgetTests: XCTestCase {
    private func snapshot(dashcam: Int64, free: Int64) -> StorageSnapshot {
        var snapshot = StorageSnapshot()
        snapshot.dashcamBytes = dashcam
        snapshot.freeBytes = free
        return snapshot
    }

    func testBudgetIsCappedByTheUserLimitWhenDiskIsPlentiful() {
        let snapshot = snapshot(dashcam: 4_000_000_000, free: 200_000_000_000)
        // 5 GB cap, 4 GB used -> 1 GB of headroom, even though the disk has 200 GB.
        XCTAssertEqual(snapshot.writableBudget(limit: .gb5), 1_000_000_000)
    }

    func testBudgetIsCappedByTheDiskWhenTheLimitIsGenerous() {
        // 2.5 GB free, of which 1 GB is the untouchable safety floor.
        let snapshot = snapshot(dashcam: 1_000_000_000, free: 2_500_000_000)
        XCTAssertEqual(snapshot.writableBudget(limit: .gb50), 1_500_000_000)
    }

    func testUnlimitedStillRespectsTheSafetyFloor() {
        let snapshot = snapshot(dashcam: 80_000_000_000, free: 3_000_000_000)
        XCTAssertEqual(snapshot.writableBudget(limit: .unlimited), 2_000_000_000)
    }

    func testBudgetNeverGoesNegativeWhenAlreadyOverTheCap() {
        let snapshot = snapshot(dashcam: 12_000_000_000, free: 50_000_000_000)
        XCTAssertEqual(snapshot.writableBudget(limit: .gb10), 0)
    }

    /// The one boundary that matters: exactly at the floor is still critical, one byte
    /// above it is not.
    func testCriticalThresholdIsExactlyOnTheBoundary() {
        XCTAssertTrue(snapshot(dashcam: 0, free: RecordingSettings.criticalFreeSpace - 1).isCriticallyLow)
        XCTAssertFalse(snapshot(dashcam: 0, free: RecordingSettings.criticalFreeSpace).isCriticallyLow)
        XCTAssertFalse(snapshot(dashcam: 0, free: RecordingSettings.criticalFreeSpace + 1).isCriticallyLow)
    }

    func testRemainingTimeHalvesWhenTheSecondCameraIsRunning() {
        let snapshot = snapshot(dashcam: 0, free: 100_000_000_000)
        let single = snapshot.estimatedRemainingRecording(quality: .standard, limit: .gb10, dualCamera: false)
        let dual = snapshot.estimatedRemainingRecording(quality: .standard, limit: .gb10, dualCamera: true)
        XCTAssertEqual(single, dual * 2, accuracy: 0.001)
    }

    func testRemainingTimeUsesTheSmallerOfCapAndDisk() {
        // 10 GB cap with an empty library, 8 Mb/s per camera, two cameras -> 2 MB/s.
        let snapshot = snapshot(dashcam: 0, free: 100_000_000_000)
        let seconds = snapshot.estimatedRemainingRecording(quality: .standard, limit: .gb10, dualCamera: true)
        XCTAssertEqual(seconds, 10_000_000_000 / 2_000_000, accuracy: 1)
    }

    func testQualityEstimatesAreOrderedAndCoverTwoCameras() {
        XCTAssertLessThan(VideoQuality.eco.gigabytesPerHour, VideoQuality.standard.gigabytesPerHour)
        XCTAssertLessThan(VideoQuality.standard.gigabytesPerHour, VideoQuality.high.gigabytesPerHour)
        // 8 Mb/s x 2 cameras x 3600 s = 7.2 GB.
        XCTAssertEqual(VideoQuality.standard.gigabytesPerHour, 7.2, accuracy: 0.01)
    }

    func testDegradationWalksDownToEcoAndStops() {
        XCTAssertEqual(VideoQuality.high.degraded, .standard)
        XCTAssertEqual(VideoQuality.standard.degraded, .eco)
        XCTAssertNil(VideoQuality.eco.degraded)
    }
}
