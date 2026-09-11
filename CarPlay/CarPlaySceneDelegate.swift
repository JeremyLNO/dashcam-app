import Foundation
#if canImport(CarPlay)
import CarPlay
import UIKit

/// Bridges the CarPlay template scene to `CarPlayManager`.
///
/// Referenced from `Info.plist` by name. If Apple has not granted the Driving Task
/// entitlement the scene is never instantiated, so this class simply never runs — that is
/// the whole isolation story, and it is why nothing else in the app links against it.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            AppEnvironment.shared?.carPlay.connect(interfaceController)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            AppEnvironment.shared?.carPlay.disconnect()
        }
    }
}
#endif
