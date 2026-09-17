import SwiftUI
import UIKit
import AVFAudio
import ComposeApp

@MainActor
final class AirPlayRouteMonitor: NSObject {
    private let session = AVAudioSession.sharedInstance()
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        sync()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func sync() {
        let airPlay = session.currentRoute.outputs.first { $0.portType == .airPlay }
        let selection = SwiftOutputSelection.shared.snapshot()
        let playerState = SwiftPlayer.shared.snapshot()
        let activePlayback = playerState.phase != .idle &&
            playerState.phase != .error &&
            playerState.sourceUrl != nil
        let livePositionMs = SwiftPlayer.shared.currentPositionMs()
        if let airPlay {
            SwiftOutputSelection.shared.selectAirPlay(
                routeId: airPlay.uid,
                name: airPlay.portName
            )
            if activePlayback {
                SwiftPlayer.shared.selectAirPlay(
                    routeId: airPlay.uid,
                    name: airPlay.portName,
                    positionMs: livePositionMs
                )
            }
        } else if selection.kind == .airplay {
            if activePlayback {
                SwiftPlayer.shared.selectLocal(positionMs: livePositionMs)
            } else {
                SwiftOutputSelection.shared.selectLocal()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

@main
struct RigelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player: PlayerModel
    private let airPlayRouteMonitor: AirPlayRouteMonitor

    init() {
        NSLog("[RigelApp] launch pid=%d", getpid())
        BridgeRegistry.register()
        airPlayRouteMonitor = AirPlayRouteMonitor()
        _player = StateObject(wrappedValue: PlayerModel())
        RigelIntake.shared.attach(controller: RigelCore.shared.controller)
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
            RootView()
                .environmentObject(player)
                .onOpenURL { url in
                    NSLog("[RigelApp] openURL %@", url.absoluteString)
                    let handled = RigelIntake.shared.handle(url: url.absoluteString)
                    NSLog("[RigelApp] handle -> %@", handled ? "true" : "false")
                }
        }
    }
}
