import SwiftUI
import UIKit

/// Turns the display down while the app keeps filming.
///
/// The discreet screen already stops drawing the cameras, and that was only half the
/// problem: it removes the picture, not the backlight. At night a phone on the windscreen
/// is a lamp pointed at the driver and a reflection in the glass ahead of them, whatever
/// it happens to be showing.
///
/// One rule governs everything here: **the driver's brightness is theirs**. It is read
/// once, on the way down, and put back exactly. Reading it again while already dimmed
/// would remember the dimmed value — and the user would get their phone back at 5 %,
/// with nothing in the app admitting responsibility.
@MainActor
final class ScreenDimmer: ObservableObject {
    /// Low enough to vanish from the windscreen, high enough that the screen still
    /// visibly exists. Zero is available and deliberately not used: a driver who reads a
    /// black phone as a crashed app will stop the car to check, which is the opposite of
    /// what a discreet mode is for.
    static let dimmedLevel: CGFloat = 0.05

    /// The *decision* to be discreet, which outlives the backlight being borrowed.
    ///
    /// The two are deliberately separate. Leaving the app hands the brightness straight
    /// back — whatever takes the foreground next is not part of this bargain — but the
    /// driver never asked to leave the discreet screen, so coming back has to find it
    /// still chosen. Collapsing the two into one flag is how « I dimmed it, iOS showed a
    /// notification, and now the screen is bright again » happens.
    @Published private(set) var isDiscreet = false

    /// Whether the backlight is borrowed at this instant.
    @Published private(set) var isDimmed = false

    /// What to hand back, captured before the first change and kept until it is handed
    /// back. `nil` means "we have not touched anything", which is what makes a second
    /// `dim()` harmless and a stray `restore()` a no-op.
    private var restoreLevel: CGFloat?
    private let display: BrightnessControlling

    /// The default is built inside, not in the signature: a default argument is evaluated
    /// where the call is written, and `SystemDisplay` only exists on the main actor.
    init(display: BrightnessControlling? = nil) {
        self.display = display ?? SystemDisplay()
    }

    /// The gesture: the moon button on the phone, or the button on the car's screen.
    ///
    /// The rule lives here rather than at the two call sites, because a rule with two call
    /// sites has two chances to be forgotten — and the second one was added months after
    /// the first, by which time the first is the documentation.
    func enter(whileRecording isRecording: Bool) {
        guard !isDiscreet, Self.mayGoDiscreet(isRecording: isRecording) else { return }
        isDiscreet = true
        dim()
    }

    /// A touch, an impact, the end of a drive, or the button pressed again.
    func exit() {
        isDiscreet = false
        restore()
    }

    func dim() {
        if restoreLevel == nil { restoreLevel = display.brightness }
        display.brightness = Self.target(from: display.brightness)
        isDimmed = true
    }

    /// Puts the screen back and forgets. Safe to call from anywhere that ends the
    /// discreet state — a tap, an impact, the end of a drive, the app losing the
    /// foreground — because calling it twice costs nothing.
    func restore() {
        isDimmed = false
        guard let restoreLevel else { return }
        display.brightness = restoreLevel
        self.restoreLevel = nil
    }

    /// Never brighter than what is already there: someone driving at 2 % asked for 2 %,
    /// and "dimming" that to 5 % would be the opposite of the request.
    static func target(from current: CGFloat) -> CGFloat {
        min(current, dimmedLevel)
    }

    /// Whether the screen may go dark at all, and after how long.
    ///
    /// Both answers turn on the same fact — **a drive is running** — and that is the whole
    /// rule. A discreet screen exists to stop a phone lighting the cabin *while it films*;
    /// outside a recording there is nothing to keep discreet, and a driver who parks, looks
    /// away for five seconds and finds a black screen has been given a defect, not a
    /// feature. It also hides the one control that matters at that moment, which is Start.
    ///
    /// The countdown is deliberately *derived* rather than paused and resumed: asking for
    /// it at the start of each recording is what makes the delay mean « after five seconds
    /// of this drive », not « five seconds after whatever happened last ».
    static func countdown(delay: DiscreetDelay, isRecording: Bool) -> TimeInterval? {
        guard isRecording else { return nil }
        return delay.interval
    }

    /// The same rule for the button. Kept separate because the two differ for `.never`:
    /// a driver who turned the countdown off can still go discreet by hand, and taking the
    /// button away would read as a broken control rather than as a setting.
    static func mayGoDiscreet(isRecording: Bool) -> Bool { isRecording }

    /// Which protections pull the screen back up.
    ///
    /// The sensors do; the driver does not. Pressing Protect while dimmed is a decision
    /// to keep the screen dark and mark the moment anyway — undoing it would punish the
    /// one gesture the discreet screen keeps within reach. A collision, and the heavy
    /// braking that so often precedes one, are the opposite case: something happened that
    /// the driver did not ask for, and whatever the app has to say about it (starting
    /// with the alert it raises) cannot be said on an unreadable screen.
    static func wakes(_ origin: ProtectionOrigin) -> Bool {
        switch origin {
        case .impact, .harshBraking: return true
        case .manual, .carPlay: return false
        }
    }
}

/// The one thing this needs from the hardware, so the rule above can be tested without
/// one — and so no test run ever leaves the machine's own display turned down.
@MainActor
protocol BrightnessControlling: AnyObject {
    var brightness: CGFloat { get set }
}

@MainActor
final class SystemDisplay: BrightnessControlling {
    var brightness: CGFloat {
        get { UIScreen.main.brightness }
        // Out of range is not an error iOS reports; it is one it clamps silently, which
        // would make a restore land somewhere other than where it started.
        set { UIScreen.main.brightness = min(max(newValue, 0), 1) }
    }
}
