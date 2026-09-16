import SwiftUI
import SwiftData
import UIKit
import WidgetKit
import XCTest
@testable import Dashcam

/// What the home screen is told, and whether it can be looked at.
///
/// The widget exists for one case and one only: **the answer being no.** A drive that
/// recorded nothing, a week with no drive at all, a protected moment still sitting
/// unexported. Everything below is a way of making sure that case survives the trip from
/// the database to the glass.
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    private var container: ModelContainer!
    private var index: SessionIndex!
    private var feeder: WidgetFeeder!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// The render tests use the real clock: `Text(_, style: .relative)` measures against
    /// *now*, so a fixed 2023 date draws « 2 yrs, 10 mths » and says nothing about the
    /// line a driver actually sees.
    private let rendered = Date()

    override func setUpWithError() throws {
        let store = TestSupport.makeStore()
        container = store.container
        index = store.index
        feeder = WidgetFeeder(index: index, storage: StorageManager(index: index), settingsStore: SettingsStore())
    }

    // MARK: - The rules

    /// A car left at the station Monday to Friday is not a broken dashcam; a fortnight of
    /// silence is. The threshold has to sit between the two.
    func testTheAlarmWaitsOutAnOrdinaryWeekAndThenFires() {
        let lastDrive = now
        XCTAssertFalse(DashcamStatusRules.isStale(lastDriveEndedAt: lastDrive, now: now.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertTrue(DashcamStatusRules.isStale(lastDriveEndedAt: lastDrive, now: now.addingTimeInterval(8 * 24 * 3600)))
    }

    /// Never having recorded anything is the loudest version of the same answer.
    func testAPhoneThatHasNeverRecordedIsAlreadyStale() {
        XCTAssertTrue(DashcamStatusRules.isStale(lastDriveEndedAt: nil, now: now))
    }

    func testTheHoursLeftFollowTheQualityInUse() {
        // 100 GB free, 10 GB/h → ten hours.
        XCTAssertEqual(
            DashcamStatusRules.hoursRemaining(freeBytes: 100_000_000_000, gigabytesPerHour: 10),
            10, accuracy: 0.01
        )
        XCTAssertEqual(DashcamStatusRules.hoursRemaining(freeBytes: 0, gigabytesPerHour: 10), 0)
        XCTAssertEqual(
            DashcamStatusRules.hoursRemaining(freeBytes: 100_000_000_000, gigabytesPerHour: 0), 0,
            "a rate of zero is a division, not an infinity"
        )
    }

    // MARK: - What the app writes

    private func drive(clips: Int, endedAt: Date, protected: Bool = false) -> UUID {
        let sessionID = UUID()
        index.beginSession(id: sessionID, startedAt: endedAt.addingTimeInterval(-600), quality: .standard)
        for segmentIndex in 0..<clips {
            _ = TestSupport.addSegment(to: index, sessionID: sessionID, segmentIndex: segmentIndex,
                                       start: endedAt.addingTimeInterval(-600 + Double(segmentIndex) * 60))
        }
        if protected {
            index.insertProtectedEvent(sessionID: sessionID, triggerDate: endedAt.addingTimeInterval(-120),
                                       origin: .manual, magnitude: 2)
        }
        index.endSession(id: sessionID, endedAt: endedAt)
        return sessionID
    }

    func testAnEmptyLibrarySaysSoRatherThanShowingNothing() {
        let snapshot = feeder.makeSnapshot(now: now)
        XCTAssertNil(snapshot.lastDriveEndedAt)
        XCTAssertFalse(snapshot.lastDriveClips.isEmpty, "a blank widget is indistinguishable from a broken one")
        XCTAssertFalse(snapshot.stateStale.isEmpty)
        XCTAssertNil(snapshot.protectedWaiting)
    }

    /// The line the whole widget is for. A drive that declared itself and wrote nothing
    /// reads « 0 clips » instead of looking like every other drive in the list.
    func testADriveThatRecordedNothingSaysZeroClips() throws {
        let sessionID = drive(clips: 0, endedAt: now)
        defer { TestSupport.removeSessionFiles(sessionID) }

        let snapshot = feeder.makeSnapshot(now: now)
        XCTAssertEqual(snapshot.lastDriveEndedAt, now)
        XCTAssertTrue(snapshot.lastDriveClips.contains("0"), "got \(snapshot.lastDriveClips)")
    }

    func testTheSummaryCarriesTheClipCount() throws {
        let sessionID = drive(clips: 3, endedAt: now)
        defer { TestSupport.removeSessionFiles(sessionID) }

        XCTAssertTrue(feeder.makeSnapshot(now: now).lastDriveClips.contains("3"))
    }

    /// A protected moment is evidence with a deadline: the retention sweep will not touch
    /// it, which is exactly why it is forgotten. Nothing else in the app brings it back up.
    func testAProtectedMomentIsSurfaced() throws {
        let sessionID = drive(clips: 2, endedAt: now, protected: true)
        defer { TestSupport.removeSessionFiles(sessionID) }

        let line = try XCTUnwrap(feeder.makeSnapshot(now: now).protectedWaiting)
        XCTAssertFalse(line.isEmpty)
    }

    /// Only the drive that has *ended*: one still being written has no final figures, and
    /// showing it would make a recording in progress look like a finished trip.
    func testADriveStillRunningIsNotReportedAsTheLastOne() throws {
        let finished = drive(clips: 2, endedAt: now.addingTimeInterval(-3600))
        defer { TestSupport.removeSessionFiles(finished) }
        let running = UUID()
        index.beginSession(id: running, startedAt: now, quality: .standard)

        XCTAssertEqual(feeder.makeSnapshot(now: now).lastDriveEndedAt, now.addingTimeInterval(-3600))
    }

    // MARK: - And whether it can be read

    /// Renders the widget and looks at the pixels.
    ///
    /// A widget cannot be reached by a UI test and cannot be opened on this machine, so
    /// the only way to know it is not a blank rectangle is to draw it and count what came
    /// out. The images are written to the build folder as well, because the fastest way to
    /// find a layout that overflows is still to look at it.
    private func render(_ snapshot: DashcamSnapshot, family: WidgetFamily, size: CGSize, name: String) throws -> UIImage {
        let view = DashcamStatusView(snapshot: snapshot, family: family, now: rendered,
                                     stillLoader: fakeStill)
            .padding(14)
            .frame(width: size.width, height: size.height)
            .background(WidgetPalette.background)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "the widget rendered to nothing at all")
        if let data = image.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(name).png")
            try? data.write(to: url)
            print("widget render: \(url.path)")
        }
        return image
    }

    /// Proportion of pixels that differ from the background. A widget that draws nothing
    /// renders a flat rectangle, which is exactly the failure that no assertion about
    /// strings can catch.
    private func inkCoverage(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var inked = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            // The ground is very dark now, so what counts as drawn is what is lighter
            // than it — the inverse of the old test, and the same question.
            if Int(pixels[offset]) > 60 { inked += 1 }
        }
        return Double(inked) / Double(width * height)
    }

    private var populated: DashcamSnapshot {
        DashcamSnapshot(
            lastDriveEndedAt: rendered.addingTimeInterval(-3600),
            state: "PRÊT", stateStale: "AUCUN TRAJET RÉCENT",
            lastDriveDuration: "34 min",
            lastDriveClips: "12 clips enregistrés",
            storageFree: "128 Go libres",
            storageUsedFraction: 0.68,
            autonomy: "≈ 9 h d'enregistrement",
            protectedWaiting: "3 moments protégés · 14 sept. 2026",
            protectedShort: "3 moments protégés",
            lastDriveStill: "road.jpg",
            protectedStills: ["a.jpg", "b.jpg", "c.jpg"],
            writtenAt: now
        )
    }

    /// Stands in for the frames on disk, so the layout can be judged with pictures in it —
    /// a still that fails to load takes a very different amount of room from one that does.
    private func fakeStill(_ name: String?) -> Image? {
        guard name != nil else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 135))
        let image = renderer.image { context in
            UIColor(red: 0.22, green: 0.28, blue: 0.42, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 135))
            UIColor(white: 0.75, alpha: 1).setFill()
            context.fill(CGRect(x: 100, y: 60, width: 40, height: 75))
        }
        return Image(uiImage: image)
    }

    func testEveryFamilyDrawsSomething() throws {
        for (family, size, name) in [
            (WidgetFamily.systemSmall, CGSize(width: 158, height: 158), "small"),
            (WidgetFamily.systemMedium, CGSize(width: 338, height: 158), "medium"),
            (WidgetFamily.systemLarge, CGSize(width: 338, height: 354), "large"),
            (WidgetFamily.accessoryRectangular, CGSize(width: 160, height: 72), "lock"),
        ] {
            let coverage = inkCoverage(try render(populated, family: family, size: size, name: name))
            XCTAssertGreaterThan(coverage, 0.01, "\(name) drew almost nothing: \(coverage)")
            XCTAssertLessThan(coverage, 0.6, "\(name) is a solid block, not a layout: \(coverage)")
        }
    }

    /// The alarming state has to look different, not merely say something different — it
    /// is read at arm's length, on a home screen, in passing.
    func testTheAlarmingStateDoesNotLookLikeTheHealthyOne() throws {
        let stale = DashcamSnapshot(
            lastDriveEndedAt: nil, state: "PRÊT", stateStale: "JAMAIS ENREGISTRÉ",
            lastDriveDuration: "", lastDriveClips: "Aucun trajet enregistré",
            storageFree: "128 Go libres", storageUsedFraction: 0.68,
            autonomy: "≈ 9 h d'enregistrement", protectedWaiting: nil, protectedShort: nil,
            lastDriveStill: nil, protectedStills: [], writtenAt: now
        )
        let healthy = try render(populated, family: .systemMedium, size: CGSize(width: 338, height: 158), name: "medium")
        let alarming = try render(stale, family: .systemMedium, size: CGSize(width: 338, height: 158), name: "medium-stale")
        XCTAssertNotEqual(healthy.pngData(), alarming.pngData())
    }
}
