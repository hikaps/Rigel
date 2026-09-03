import SwiftUI
import UIKit

/// request only succeeds when the app-level mask (AppDelegate) allows it.
enum PlayerOrientation {
    static func forceLandscape() {
        AppDelegate.orientationLock = .landscape
        request(.landscapeRight)
    }

    static func restore() {
        AppDelegate.orientationLock = .allButUpsideDown
        request(.portrait)
    }

    private static func request(_ orientation: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
    }
}
