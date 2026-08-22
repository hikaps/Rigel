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
            VStack(spacing: 18) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.rigelStar)
                VStack(spacing: 6) {
                    Text("Nothing playing")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Open a stream from the Rigel home screen.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Button {
                    player.showPlayer = false
                } label: {
                    Label("Back to Rigel", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .tint(Color.rigelStar)
            }
            .padding(28)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(24)
        case "PROBING", "PREPARING_PROXY":
            VStack(spacing: 18) {
                Image(systemName: player.phase.name == "PROBING" ? "magnifyingglass" : "gearshape.2.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.rigelStar)
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                VStack(spacing: 6) {
                    Text(player.phase.name == "PROBING" ? "Checking stream" : "Preparing playback")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(player.phase.name == "PROBING"
                         ? "Finding the best way to play this link."
                         : "Converting this stream for smooth playback.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if !player.routeLabel.isEmpty {
                    Text(player.routeLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .padding(28)
            .frame(maxWidth: 360)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(24)
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
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                VStack(spacing: 6) {
                    Text("Playback error")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(player.error ?? "Unknown error")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                }
                HStack(spacing: 12) {
                    Button {
                        player.retryWithProxy()
                    } label: {
                        Label("Try proxy", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rigelStar)

                    Button {
                        player.stop()
                    } label: {
                        Text("Close")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(24)
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
