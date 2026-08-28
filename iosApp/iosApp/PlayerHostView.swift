import SwiftUI
import UIKit
import ComposeApp

/// Rotates the app while the player cover is up. The window-scene geometry
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

/// Full-screen player host. Renders the native AVPlayerViewController when
/// playing; shows probing/proxy/error states while Kotlin prepares the stream.
struct PlayerHostView: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var showDevicesPicker = false

    private struct LoadSignature: Equatable {
        let url: String
        let title: String?
        let sender: String?
        let probeDurationMs: Double?
        let startPositionMs: Int64
    }


    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .statusBarHidden()
        .onAppear {
            PlayerOrientation.forceLandscape()
        }
        .onDisappear {
            PlayerOrientation.restore()
            // Belt-and-braces: if the cover is dismissed by any path other than
            // the back/close buttons, make sure the native player stops.
            if player.phase != .idle {
                player.stop()
            }
        }
        .sheet(isPresented: $showDevicesPicker) {
            DevicesView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch player.phase.name {
        case "IDLE":
            stateContent {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 42, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.rigelStar)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Nothing playing")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Open a stream from the Rigel home screen.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                Button {
                    player.showPlayer = false
                } label: {
                    Label("Back to Rigel", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.rigelStar)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
        case "PROBING", "PREPARING_PROXY":
            let preparingProxy = player.phase.name == "PREPARING_PROXY"
            stateContent {
                Image(systemName: preparingProxy ? "gearshape.2.fill" : "magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.rigelStar)

                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                    .accessibilityLabel(preparingProxy ? "Preparing playback" : "Checking stream")

                VStack(spacing: 6) {
                    Text(preparingProxy ? "Preparing playback" : "Checking stream")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(preparingProxy
                         ? "Converting this stream for smooth playback."
                         : "Finding the best way to play this link.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                }

                if !player.routeLabel.isEmpty {
                    Label(player.routeLabel, systemImage: "arrow.triangle.branch")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.rigelStar)
                }

                Button("Cancel", role: .cancel) {
                    player.stop()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
        case "PLAYING", "BUFFERING":
            let buffering = player.phase.name == "BUFFERING"
            ZStack {
                if let url = player.playableURL {
                    PlayerView(
                        url: url,
                        title: player.displayTitle,
                        sender: player.sender,
                        subtitleTracks: player.subtitleTracks,
                        longFormVideoAirPlayEligible: player.longFormVideoAirPlayEligible,
                        isProxy: player.proxyUrl != nil,
                        probeDurationMs: player.probeDurationMs,
                        startPositionMs: player.startPositionMs,
                        onReady: {},
                        onError: { player.reportError($0) },
                        onBack: { player.stop() },
                        onDevices: { showDevicesPicker = true },
                        onSeek: {
                            player.seek(
                                positionSeconds: $0,
                                durationSeconds: (player.probeDurationMs ?? 0) / 1000
                            )
                        }
                    )
                    .ignoresSafeArea()
                } else {
                    stateContent {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.large)
                        Text("Loading player")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
                if buffering {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                        .padding(18)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .accessibilityLabel("Buffering")
                        .allowsHitTesting(false)
                }
            }
        default: // ERROR
            stateContent {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Playback error")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(player.error ?? "Unknown error")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    Button {
                        player.retryWithProxy()
                    } label: {
                        Label("Try with proxy", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.rigelStar)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())

                    Button("Close", role: .cancel) {
                        player.stop()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .frame(maxWidth: 280)
            }
        }
    }

    @ViewBuilder
    private func stateContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 20, content: content)
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
    }
}

/// Hosts RigelPlayerViewController (AVPlayerViewController + transparent overlay controls).
/// Load is called only when the media URL or playback configuration changes.
/// The start offset is intentionally excluded from the guard: proxy seeking
/// keeps the current controller mounted until its replacement URL is ready.
/// The guard lives in the Coordinator (never mutate @State during view updates).
struct PlayerView: UIViewControllerRepresentable {
    let url: String
    let title: String?
    let sender: String?
    let subtitleTracks: [SubtitleTrack]
    let longFormVideoAirPlayEligible: Bool
    let isProxy: Bool
    let probeDurationMs: Double?
    let startPositionMs: Int64
    let onReady: () -> Void
    let onError: (String) -> Void
    let onBack: () -> Void
    let onDevices: () -> Void
    let onSeek: (Double) -> Void

    final class Coordinator {
        var loaded: (
            url: String,
            title: String?,
            sender: String?,
            subtitleTracks: [SubtitleTrack],
            longFormVideoAirPlayEligible: Bool,
            isProxy: Bool,
            probeDurationMs: Double?
        )?
        /// Strongly retains the error origin so the closure's weak capture
        /// outlives makeUIViewController; otherwise the box deallocates and
        /// every error forwards unconditionally.
        var errorOrigin: PlayerErrorOrigin?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        // SwiftUI removes this representable for initial proxy preparation or
        // error. Dispose only this concrete controller;
        // the bridge may already retain a newer replacement.
        if let player = uiViewController as? RigelPlayerViewController,
           let bridge = PlayerBridgeFactory.shared.create() as? RigelPlayerBridge {
            bridge.stop(viewController: player)
        } else {
            (uiViewController as? RigelPlayerViewController)?.stopPlayback()
        }
    }
    func makeUIViewController(context: Context) -> UIViewController {
        guard let bridge = PlayerBridgeFactory.shared.create() else {
            let vc = UIViewController()
            let label = UILabel()
            label.text = "Player bridge not registered"
            label.textColor = .white
            label.textAlignment = .center
            vc.view.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
            ])
            return vc
        }
        // Bind the error path to the concrete controller created below. The
        // coordinator retains the origin box strongly; the closure forwards
        // the error only when that controller is still current. Do not stop it
        // here: a proxy seek can make the old item fail while the controller
        // must remain mounted for the replacement proxy URL.
        let origin = PlayerErrorOrigin()
        let events = PlayerEventsImpl(
            onReady: onReady,
            onError: { [weak origin] message in
                guard let origin, let controller = origin.controller else {
                    onError(message)
                    return
                }
                guard let currentBridge = PlayerBridgeFactory.shared.create() as? RigelPlayerBridge else {
                    onError(message)
                    return
                }
                guard currentBridge.isCurrent(viewController: controller) else {
                    return
                }
                onError(message)
            },
            onBack: onBack
        )
        let created = bridge.createPlayerViewController(events: events)
        if let player = created as? RigelPlayerViewController {
            player.onDevicesRequested = onDevices
            player.onSeekRequested = onSeek
        }
        origin.controller = created as? RigelPlayerViewController
        context.coordinator.errorOrigin = origin
        return created
    }

    final class PlayerErrorOrigin {
        weak var controller: RigelPlayerViewController?
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let player = uiViewController as? RigelPlayerViewController {
            player.onSeekRequested = onSeek
        }
        guard let bridge = PlayerBridgeFactory.shared.create() else { return }
        let loaded = context.coordinator.loaded
        if loaded?.url != url ||
            loaded?.title != title ||
            loaded?.sender != sender ||
            loaded?.subtitleTracks != subtitleTracks ||
            loaded?.longFormVideoAirPlayEligible != longFormVideoAirPlayEligible ||
            loaded?.isProxy != isProxy ||
            loaded?.probeDurationMs != probeDurationMs {
            bridge.load(
                url: url,
                title: title,
                sender: sender,
                longFormVideoAirPlayEligible: longFormVideoAirPlayEligible,
                subtitleTracks: subtitleTracks,
                durationMs: probeDurationMs.map { KotlinLong(longLong: Int64($0)) },
                isProxy: isProxy,
                startOffsetMs: startPositionMs
            )
            context.coordinator.loaded = (
                url,
                title,
                sender,
                subtitleTracks,
                longFormVideoAirPlayEligible,
                isProxy,
                probeDurationMs
            )
        }
    }
}
