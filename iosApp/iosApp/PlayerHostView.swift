import SwiftUI
import ComposeApp

/// Full-screen player host. Renders the native AVPlayerViewController when
/// playing; shows probing/proxy/error states while Kotlin prepares the stream.
struct PlayerHostView: View {
    @EnvironmentObject private var player: PlayerModel

    private struct LoadSignature: Equatable {
        let url: String
        let title: String?
        let sender: String?
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .statusBarHidden()
        .onDisappear {
            // Belt-and-braces: if the cover is dismissed by any path other than
            // the back/close buttons, make sure the native player stops.
            if player.phase != .idle {
                player.stop()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch player.phase.name {
        case "IDLE":
            VStack(spacing: 10) {
                Text("Nothing playing")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("Home") { player.showPlayer = false }
                    .buttonStyle(.bordered)
                    .tint(Color.rigelStar)
            }
        case "PROBING", "PREPARING_PROXY":
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                Text(player.phase.name == "PROBING" ? "Probing stream…" : "Preparing local conversion…")
                    .foregroundStyle(.white)
                if !player.routeLabel.isEmpty {
                    Text(player.routeLabel)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        case "PLAYING":
            if let url = player.playableURL {
                PlayerView(
                    url: url,
                    title: player.filename,
                    sender: player.sender,
                    longFormVideoAirPlayEligible: player.longFormVideoAirPlayEligible,
                    onReady: {},
                    onError: { player.reportError($0) },
                    onBack: { player.stop() }
                )
                .ignoresSafeArea()
            }
        default: // ERROR
            VStack(spacing: 16) {
                Text("Playback error")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(player.error ?? "Unknown error")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                HStack(spacing: 12) {
                    Button("Open via proxy") { player.retryWithProxy() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.rigelStar)
                    Button("Close") { player.stop() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
    }
}

/// Hosts RigelPlayerViewController (AVPlayerViewController + native top bar).
/// Load is called only when the URL/title/sender signature actually changes,
/// so SwiftUI state updates never reload the player. The guard lives in the
/// Coordinator (never mutate @State during view updates).
struct PlayerView: UIViewControllerRepresentable {
    let url: String
    let title: String?
    let sender: String?
    let longFormVideoAirPlayEligible: Bool
    let onReady: () -> Void
    let onError: (String) -> Void
    let onBack: () -> Void

    final class Coordinator {
        var loaded: (url: String, title: String?, sender: String?, longFormVideoAirPlayEligible: Bool)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        let events = PlayerEventsImpl(
            onReady: onReady,
            onError: onError,
            onBack: onBack
        )
        return bridge.createPlayerViewController(events: events)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let bridge = PlayerBridgeFactory.shared.create() else { return }
        let loaded = context.coordinator.loaded
        if loaded?.url != url ||
            loaded?.title != title ||
            loaded?.sender != sender ||
            loaded?.longFormVideoAirPlayEligible != longFormVideoAirPlayEligible {
            bridge.load(
                url: url,
                title: title,
                sender: sender,
                longFormVideoAirPlayEligible: longFormVideoAirPlayEligible
            )
            context.coordinator.loaded = (url, title, sender, longFormVideoAirPlayEligible)
        }
    }
}
