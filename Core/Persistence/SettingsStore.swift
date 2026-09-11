import Foundation
import Combine

/// Single owner of `RecordingSettings`.
///
/// Backed by `UserDefaults` (the platform's preference database) rather than SwiftData:
/// settings are read on every frame of the recording HUD and by the CarPlay scene, both
/// of which want a synchronous, allocation-free read.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let settings = "settings.recording"
        static let onboardingCompleted = "onboarding.completed"
        static let installDate = "install.date"
    }

    @Published var settings: RecordingSettings {
        didSet { persist() }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingCompleted) }
    }

    /// First launch wins; used by the 24-hour satisfaction prompt.
    let installDate: Date

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Key.settings),
           let decoded = try? JSONDecoder().decode(RecordingSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = RecordingSettings()
        }
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingCompleted)

        if let stored = defaults.object(forKey: Key.installDate) as? Date {
            self.installDate = stored
        } else {
            let now = Date()
            defaults.set(now, forKey: Key.installDate)
            self.installDate = now
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Key.settings)
    }

    /// Convenience for the many single-field toggles in Settings.
    func update<Value>(_ keyPath: WritableKeyPath<RecordingSettings, Value>, to value: Value) {
        settings[keyPath: keyPath] = value
    }
}
