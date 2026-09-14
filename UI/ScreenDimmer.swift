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
