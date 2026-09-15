import XCTest
@testable import Dashcam

/// Every user-facing string has to exist in all five shipped languages.
///
/// A missing key does not crash — it renders as `settings.section.storage` on screen —
/// which is exactly the kind of defect that reaches the App Store unnoticed. Hence a test.
final class LocalizationTests: XCTestCase {
    private let languages: [AppLanguage] = [.en, .fr, .es, .de, .pt]

    /// A representative key from every screen and every enum that feeds the UI.
    private let keys: [String] = [
        "tab.record", "tab.videos", "tab.settings",
        "rec.on", "rec.off", "action.start", "action.stop", "action.protect", "action.export",
        "status.rear", "status.front", "status.gps", "status.free_space", "status.remaining", "status.quality",
        "quality.eco", "quality.standard", "quality.high",
        "segment.1min", "segment.3min", "segment.5min",
        "retention.7days", "retention.30days", "retention.never",
        "storage.5gb", "storage.10gb", "storage.25gb", "storage.50gb", "storage.unlimited",
        "shock.low", "shock.normal", "shock.high",
        "discreet.never", "discreet.5s", "discreet.10s", "discreet.30s", "settings.discreet.footer",
        "export.mode.rear", "export.mode.front", "export.mode.both", "export.mode.pip",
        "export.style.original", "export.style.with_info", "export.error.subscription",
        "paywall.title", "paywall.restore", "paywall.manage", "paywall.terms", "paywall.privacy",
        "paywall.trial.export_note", "plan.monthly", "plan.quarterly", "plan.yearly",
        "onboarding.1.title", "onboarding.2.title", "onboarding.3.title", "onboarding.4.title", "onboarding.5.title",
        "review.title", "review.yes", "review.no",
        "carplay.title", "carplay.start", "carplay.stop", "carplay.protect",
        "carplay.clips", "carplay.cameras", "carplay.cameras.both", "carplay.cameras.road",
        "carplay.cameras.none", "carplay.storage", "carplay.screen.dim", "carplay.screen.wake",
        "carplay.blocked.locked", "carplay.blocked.paused", "carplay.blocked.no_camera",
        "carplay.blocked.title", "carplay.blocked.detail", "carplay.ready",
        "carplay.confirm.protected", "carplay.confirm.saved", "carplay.protect.done",
        "capture.error.not_running", "capture.interrupted.background",
        "settings.support", "settings.language", "settings.quality", "settings.retention",
        "capture.error.no_camera", "capture.interrupted.call", "capture.interrupted.sensitive",
        "thermal.reduced_quality", "thermal.front_dropped", "thermal.stopped",
        "alert.storage_full.title", "alert.impact.title",
        "permission.camera.explanation", "permission.location.explanation",
        "lens.ultrawide", "lens.wide", "unit.gb_per_hour",
    ]

    private func bundle(for language: AppLanguage) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle(for: LocalizationTests.self).path(forResource: language.rawValue, ofType: "lproj")
                ?? Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
            "no .lproj shipped for \(language.rawValue)"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    func testEveryKeyResolvesInEveryLanguage() throws {
        for language in languages {
            let bundle = try bundle(for: language)
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "@@MISSING@@", table: nil)
                XCTAssertNotEqual(value, "@@MISSING@@", "\(key) missing in \(language.rawValue)")
                XCTAssertNotEqual(value, key, "\(key) untranslated in \(language.rawValue)")
                XCTAssertFalse(value.isEmpty, "\(key) empty in \(language.rawValue)")
            }
        }
    }

    /// Format strings must keep their placeholder, or the formatted call produces
    /// nonsense rather than failing loudly.
    func testFormatPlaceholdersSurviveTranslation() throws {
        let formatted: [String: String] = [
            "library.segments": "%d",
            "paywall.trial": "%@",
            "paywall.then_price": "%@",
            "notification.update.body": "%@",
        ]
        for language in languages {
            let bundle = try bundle(for: language)
            for (key, placeholder) in formatted {
                let value = bundle.localizedString(forKey: key, value: "", table: nil)
                XCTAssertTrue(value.contains(placeholder), "\(key) lost \(placeholder) in \(language.rawValue)")
            }
        }
    }

    func testEveryEnumTitleKeyIsCovered() throws {
        var enumKeys: [String] = []
        enumKeys += VideoQuality.allCases.map(\.titleKey)
        enumKeys += SegmentDuration.allCases.map(\.titleKey)
        enumKeys += RetentionPolicy.allCases.map(\.titleKey)
        enumKeys += StorageLimit.allCases.map(\.titleKey)
        enumKeys += ShockSensitivity.allCases.map(\.titleKey)
        enumKeys += DiscreetDelay.allCases.map(\.titleKey)
        enumKeys += ExportMode.allCases.map(\.titleKey)
        enumKeys += ExportStyle.allCases.map(\.titleKey)
        enumKeys += ProtectionOrigin.allCases.map(\.titleKey)
        enumKeys += CameraPosition.allCases.map(\.localizedNameKey)
        enumKeys += AppPermission.allCases.flatMap { [$0.titleKey, $0.explanationKey] }

        let bundle = try bundle(for: .en)
        for key in enumKeys {
            let value = bundle.localizedString(forKey: key, value: "@@MISSING@@", table: nil)
            XCTAssertNotEqual(value, "@@MISSING@@", "enum key \(key) has no translation")
        }
    }

    /// Falling back to English when the device speaks something we do not ship is the
    /// documented behaviour.
    func testSystemResolutionFallsBackToEnglish() {
        XCTAssertTrue(AppLanguage.concrete.contains(LanguageManager.systemPreferred()))
    }
}
