import Foundation
import SwiftUI

/// The 24-hour satisfaction prompt.
///
/// Twenty-four hours after install the app asks one question with two answers. A happy
/// user is sent to the App Store review page; an unhappy one is sent to the support page,
/// where the complaint can turn into a fix instead of a one-star review.
@MainActor
final class ReviewPrompter: ObservableObject {
    /// Drives the sheet in `RootView`.
    @Published var isPrompting = false

    private enum Key {
        static let asked = "review.asked"
        static let answeredHappy = "review.answeredHappy"
    }

    private let defaults: UserDefaults
    private let installDate: Date
    private let configuration: AppConfiguration
    private let delay: TimeInterval

    init(
        installDate: Date,
        configuration: AppConfiguration,
        defaults: UserDefaults = .standard,
        delay: TimeInterval = 24 * 3600
    ) {
        self.installDate = installDate
        self.configuration = configuration
        self.defaults = defaults
        self.delay = delay
    }

    var hasBeenAsked: Bool { defaults.bool(forKey: Key.asked) }

    /// Pure enough to test: the decision depends only on the install date, the clock and
    /// the "already asked" flag.
    func shouldPrompt(now: Date = Date()) -> Bool {
        guard !hasBeenAsked else { return false }
        return now.timeIntervalSince(installDate) >= delay
    }

    /// Called when the app becomes active. Never interrupts a recording.
    func evaluate(now: Date = Date(), isRecording: Bool) {
        guard !isRecording, shouldPrompt(now: now) else { return }
        isPrompting = true
    }

    func answerHappy(openURL: (URL) -> Void) {
        markAsked(happy: true)
        if let url = configuration.reviewURL { openURL(url) }
    }

    func answerUnhappy(openURL: (URL) -> Void) {
        markAsked(happy: false)
        if let url = configuration.supportURL { openURL(url) }
    }

    func dismiss() {
        // Dismissing without answering is not an answer: ask again on a later launch
        // rather than burning the single prompt this app is allowed.
        isPrompting = false
    }

    private func markAsked(happy: Bool) {
        defaults.set(true, forKey: Key.asked)
        defaults.set(happy, forKey: Key.answeredHappy)
        isPrompting = false
    }
}
