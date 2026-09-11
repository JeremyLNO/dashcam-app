import Foundation
import SwiftUI

/// The languages the app ships. `system` follows the device; anything else is an
/// explicit user choice that outranks the device setting and survives relaunch.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case en
    case fr
    case es
    case de
    case pt

    var id: String { rawValue }

    /// Written in the language itself — a language picker in a language you cannot read
    /// is useless.
    var nativeName: String {
        switch self {
        case .system: return ""   // resolved through the string catalog instead
        case .en: return "English"
        case .fr: return "Français"
        case .es: return "Español"
        case .de: return "Deutsch"
        case .pt: return "Português"
        }
    }

    static var selectable: [AppLanguage] { allCases }
    static var concrete: [AppLanguage] { allCases.filter { $0 != .system } }
}

/// Owns the language choice and the bundle every string is read from.
///
/// Rather than relying on `AppleLanguages` (which only takes effect on the *next*
/// launch), the resolved `.lproj` bundle is swapped in memory and the view tree is
/// rebuilt, so a language change is immediate.
@MainActor
final class LanguageManager: ObservableObject {
    private enum Key { static let language = "settings.language" }

    static let shared = LanguageManager()

    @Published private(set) var language: AppLanguage
    @Published private(set) var bundle: Bundle

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, mainBundle: Bundle = .main) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.language = stored
        self.bundle = LanguageManager.resolveBundle(for: stored, in: mainBundle)
        L10n.bundleProvider = { [weak self] in self?.bundle ?? .main }
    }

    /// The concrete language currently in effect, with `.system` already resolved.
    var effectiveLanguage: AppLanguage {
        language == .system ? LanguageManager.systemPreferred() : language
    }

    func select(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        defaults.set(language.rawValue, forKey: Key.language)
        bundle = LanguageManager.resolveBundle(for: language, in: .main)
    }

    /// First device-preferred language we actually ship, English otherwise.
    nonisolated static func systemPreferred() -> AppLanguage {
        for identifier in Locale.preferredLanguages {
            let base = String(identifier.prefix(2)).lowercased()
            if let match = AppLanguage(rawValue: base), match != .system { return match }
        }
        return .en
    }

    nonisolated private static func resolveBundle(for language: AppLanguage, in mainBundle: Bundle) -> Bundle {
        let code = (language == .system ? systemPreferred() : language).rawValue
        guard let path = mainBundle.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path)
        else {
            // Shipping without the .lproj for a listed language would be a packaging
            // bug; falling back to the main bundle keeps the app readable in English
            // instead of rendering raw keys.
            return mainBundle
        }
        return localized
    }
}

/// String lookup that honours the in-app language override.
///
/// Views never embed user-facing literals; they call `L10n.t("some.key")`. The keys and
/// all five translations live in `Resources/Localizable.xcstrings`.
enum L10n {
    /// Set by `LanguageManager` at init. A plain closure rather than a stored bundle so
    /// a language switch is picked up without any re-registration.
    nonisolated(unsafe) static var bundleProvider: () -> Bundle = { .main }

    static func t(_ key: String) -> String {
        bundleProvider().localizedString(forKey: key, value: key, table: nil)
    }

    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: bundleProvider().localizedString(forKey: key, value: key, table: nil),
               locale: Locale.current,
               arguments: arguments)
    }
}

extension Text {
    /// `Text(key: "...")` reads through `L10n`, so it follows the in-app language.
    init(key: String) {
        self.init(verbatim: L10n.t(key))
    }
}
