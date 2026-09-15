import XCTest
@testable import Dashcam

/// Turning the screen down is easy; giving it back is where this goes wrong.
///
/// The failure that matters is not visible in the app at all: the brightness belongs to
/// the phone, so a dimmer that forgets what it borrowed leaves the *user* at 5 % in every
/// other app, with nothing pointing back here. Every test below exists to pin one way of
/// forgetting.
@MainActor
final class ScreenDimmerTests: XCTestCase {
    private final class FakeDisplay: BrightnessControlling {
        var brightness: CGFloat
        init(_ brightness: CGFloat) { self.brightness = brightness }
    }

    func testDimmingTurnsTheDisplayDownAndRestoringGivesItBack() {
        let display = FakeDisplay(0.8)
        let dimmer = ScreenDimmer(display: display)

        dimmer.dim()
        XCTAssertEqual(display.brightness, ScreenDimmer.dimmedLevel, accuracy: 0.0001)
        XCTAssertTrue(dimmer.isDimmed)

        dimmer.restore()
        XCTAssertEqual(display.brightness, 0.8, accuracy: 0.0001)
        XCTAssertFalse(dimmer.isDimmed)
    }

    /// The one that costs a user their brightness: dim twice, and a dimmer that re-reads
    /// the screen remembers 0.05 as "what they had".
    func testASecondDimDoesNotOverwriteWhatWasBorrowed() {
        let display = FakeDisplay(0.7)
        let dimmer = ScreenDimmer(display: display)

        dimmer.dim()
        dimmer.dim()
        dimmer.restore()

        XCTAssertEqual(display.brightness, 0.7, accuracy: 0.0001,
                       "the driver's own brightness, not the dimmed one")
    }

    /// `restore()` is called from a tap, an impact, the end of a drive and the app losing
    /// the foreground — several of which happen together. Calling it twice, or before any
    /// dim, must change nothing.
    func testRestoringWithoutDimmingLeavesTheDisplayAlone() {
        let display = FakeDisplay(0.42)
        let dimmer = ScreenDimmer(display: display)

        dimmer.restore()
        XCTAssertEqual(display.brightness, 0.42, accuracy: 0.0001)

        dimmer.dim()
        dimmer.restore()
        display.brightness = 0.9   // the user reaches for Control Center afterwards
        dimmer.restore()
        XCTAssertEqual(display.brightness, 0.9, accuracy: 0.0001,
                       "a spent restore must not undo what the user did next")
    }

    /// Someone already driving at 2 % asked for 2 %. "Dimming" that to 5 % would light
    /// the cabin up in the name of dimming it.
    func testDimmingNeverRaisesTheBrightness() {
        let darker = ScreenDimmer.dimmedLevel / 2
        let display = FakeDisplay(darker)
        let dimmer = ScreenDimmer(display: display)

        dimmer.dim()

        XCTAssertEqual(display.brightness, darker, accuracy: 0.0001)
        XCTAssertEqual(ScreenDimmer.target(from: darker), darker, accuracy: 0.0001)
        XCTAssertEqual(ScreenDimmer.target(from: 1.0), ScreenDimmer.dimmedLevel, accuracy: 0.0001)
    }

    /// Not zero, on purpose: a screen that looks off reads as an app that crashed, and a
    /// driver who believes the recording stopped stops the car to check.
    func testTheDimmedLevelStaysVisible() {
        XCTAssertGreaterThan(ScreenDimmer.dimmedLevel, 0)
        XCTAssertLessThan(ScreenDimmer.dimmedLevel, 0.15)
    }

    // MARK: - When the screen is allowed to go dark

    /// The rule Jeremy asked for on 2026-09-15, after finding the screen going dark while
    /// parked: the discreet screen belongs to a drive, and to nothing else.
    func testNothingGoesDiscreetWhileNoDriveIsRunning() {
        for delay in DiscreetDelay.allCases {
            XCTAssertNil(
                ScreenDimmer.countdown(delay: delay, isRecording: false),
                "\(delay) armed a countdown outside a recording"
            )
        }
        XCTAssertFalse(ScreenDimmer.mayGoDiscreet(isRecording: false),
                       "the button must not be able to dim a phone that is filming nothing")
    }

    /// And while one *is* running, the delay is exactly the one the driver chose.
    func testTheChosenDelayGovernsWhileRecording() {
        XCTAssertEqual(ScreenDimmer.countdown(delay: .fiveSeconds, isRecording: true), 5)
        XCTAssertEqual(ScreenDimmer.countdown(delay: .tenSeconds, isRecording: true), 10)
        XCTAssertEqual(ScreenDimmer.countdown(delay: .thirtySeconds, isRecording: true), 30)
        XCTAssertTrue(ScreenDimmer.mayGoDiscreet(isRecording: true))
    }

    /// « Never » is about the countdown, not about the button. Turning the automatic delay
    /// off must not confiscate the moon button from someone driving at night.
    func testNeverSilencesTheCountdownAndLeavesTheButton() {
        XCTAssertNil(ScreenDimmer.countdown(delay: .never, isRecording: true))
        XCTAssertTrue(ScreenDimmer.mayGoDiscreet(isRecording: true))
    }

    /// What the car does wakes the screen; what the driver does does not. Pressing
    /// Protect from the discreet screen is a decision to stay dark.
    func testOnlyTheSensorsWakeTheScreen() {
        XCTAssertTrue(ScreenDimmer.wakes(.impact))
        XCTAssertTrue(ScreenDimmer.wakes(.harshBraking),
                      "it raises an alert, and an alert on an unreadable screen is worse than waking")
        XCTAssertFalse(ScreenDimmer.wakes(.manual))
        XCTAssertFalse(ScreenDimmer.wakes(.carPlay))
    }
}
