import SwiftUI
import ComposeApp

@main
struct RigelApp: App {
    init() {
        BridgeRegistry.register()
        // Test/automation hook: accept a rigel:// URL as a launch argument
        // (avoids the system scheme-confirmation dialog in headless e2e runs).
        for arg in ProcessInfo.processInfo.arguments {
            if arg.hasPrefix("rigel://") {
                NSLog("[RigelApp] launch-arg %@", arg)
                _ = RigelIntake.shared.handle(url: arg)
            }
            if arg == "-rigel-renderer" {
                NSLog("[RigelApp] starting DLNA renderer (launch arg)")
                let error = RendererBridgeFactory.shared.create()?.start(events: RendererEventsImpl.shared)
                if let error { NSLog("[RigelApp] renderer start failed: %@", error) }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    NSLog("[RigelApp] openURL %@", url.absoluteString)
                    let handled = RigelIntake.shared.handle(url: url.absoluteString)
                    NSLog("[RigelApp] handle -> %@", handled ? "true" : "false")
                }
        }
    }
}
