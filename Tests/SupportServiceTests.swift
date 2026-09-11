import XCTest
@testable import Dashcam

/// Version comparison, the review prompt, and the overlay schedule.
final class SupportServiceTests: XCTestCase {
    // MARK: Update check

    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertTrue(NotificationManager.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertTrue(NotificationManager.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(NotificationManager.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(NotificationManager.isNewer("1.0", than: "1.0.1"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(NotificationManager.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(NotificationManager.isNewer("1.0", than: "1.0.0"))
    }

    // MARK: Review prompt

    @MainActor
    private func makePrompter(installedAgo: TimeInterval, suiteName: String) -> (ReviewPrompter, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let prompter = ReviewPrompter(
            installDate: Date().addingTimeInterval(-installedAgo),
            configuration: AppConfiguration.load(),
            defaults: defaults
        )
        return (prompter, defaults)
    }

    @MainActor
    func testPromptWaitsExactlyTwentyFourHours() {
        let (justUnder, _) = makePrompter(installedAgo: 24 * 3600 - 1, suiteName: "review.under")
        XCTAssertFalse(justUnder.shouldPrompt())

        let (exactly, _) = makePrompter(installedAgo: 24 * 3600, suiteName: "review.exact")
        XCTAssertTrue(exactly.shouldPrompt(), "the boundary itself must qualify")
    }

    @MainActor
    func testPromptNeverInterruptsARecording() {
        let (prompter, _) = makePrompter(installedAgo: 48 * 3600, suiteName: "review.recording")
        prompter.evaluate(isRecording: true)
        XCTAssertFalse(prompter.isPrompting)

        prompter.evaluate(isRecording: false)
        XCTAssertTrue(prompter.isPrompting)
    }

    @MainActor
    func testAnsweringIsRememberedAndNeverAsksAgain() {
        let (prompter, _) = makePrompter(installedAgo: 48 * 3600, suiteName: "review.answered")
        var opened: [URL] = []
        prompter.answerHappy { opened.append($0) }

        XCTAssertTrue(prompter.hasBeenAsked)
        XCTAssertFalse(prompter.shouldPrompt())
        XCTAssertFalse(prompter.isPrompting)
    }

    /// Dismissing without answering is not an answer — the single prompt is not spent.
    @MainActor
    func testDismissingLeavesThePromptAvailable() {
        let (prompter, _) = makePrompter(installedAgo: 48 * 3600, suiteName: "review.dismissed")
        prompter.evaluate(isRecording: false)
        prompter.dismiss()

        XCTAssertFalse(prompter.hasBeenAsked)
        XCTAssertTrue(prompter.shouldPrompt())
    }

    // MARK: Overlay schedule

    func testOverlayStampsAreCappedRegardlessOfDuration() {
        let stamps = OverlayRenderer.stamps(
            start: Date(), duration: 3 * 3600,
            fields: [.date, .time],
            speedProvider: { _ in nil },
            coordinateProvider: { _ in nil },
            maximumStamps: 1200
        )
        XCTAssertLessThanOrEqual(stamps.count, 1200)
        XCTAssertGreaterThan(stamps.count, 0)
    }

    func testOverlayStampsCoverTheWholeTimelineWithoutOverrunningIt() {
        let duration: TimeInterval = 125
        let stamps = OverlayRenderer.stamps(
            start: Date(), duration: duration,
            fields: [.time],
            speedProvider: { _ in nil },
            coordinateProvider: { _ in nil }
        )
        XCTAssertEqual(stamps.first?.start, 0)
        let last = stamps.last!
        XCTAssertLessThanOrEqual(last.start + last.duration, duration + 0.0001)
    }

    func testNoFieldsMeansNoOverlayAtAll() {
        let stamps = OverlayRenderer.stamps(
            start: Date(), duration: 60, fields: [],
            speedProvider: { _ in 50 }, coordinateProvider: { _ in (1, 2) }
        )
        XCTAssertTrue(stamps.isEmpty)
    }

    func testSpeedAndCoordinatesAppearOnlyWhenTheirFieldIsOn() {
        let withSpeed = OverlayRenderer.stamps(
            start: Date(), duration: 2, fields: [.speed],
            speedProvider: { _ in 90 }, coordinateProvider: { _ in (48.85, 2.35) }
        )
        XCTAssertTrue(withSpeed.first!.text.contains("90"))
        XCTAssertFalse(withSpeed.first!.text.contains("48.85"))

        let withLocation = OverlayRenderer.stamps(
            start: Date(), duration: 2, fields: [.location],
            speedProvider: { _ in 90 }, coordinateProvider: { _ in (48.85, 2.35) }
        )
        XCTAssertTrue(withLocation.first!.text.contains("48.85"))
    }
}
