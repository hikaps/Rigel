import Foundation
import Combine
import ComposeApp

/// SwiftUI-facing playback state, mirrored from Kotlin's PlayerUiState via
/// SwiftPlayer observation. Kotlin owns all playback logic; this model only
/// renders it and forwards user actions.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var phase: PlayerPhase = .idle
    @Published var sourceUrl: String?
    @Published var filename: String?
    @Published var route: PlaybackRoute?
    @Published var proxyUrl: String?
    @Published var error: String?
    @Published var sender: String?
    @Published var castActive = false
    @Published var showPlayer = false

    init() {
        SwiftPlayer.shared.observe { [weak self] state in
            Task { @MainActor [weak self] in
                self?.apply(state)
            }
        }
        apply(SwiftPlayer.shared.snapshot())
    }

    var playableURL: String? { proxyUrl ?? sourceUrl }

    var routeLabel: String { route?.name ?? "" }

    var isPlaying: Bool { phase == .playing }

    func apply(_ state: PlayerUiState) {
        phase = state.phase
        sourceUrl = state.sourceUrl
        filename = state.filename
        route = state.route
        proxyUrl = state.proxyUrl
        error = state.error
        sender = state.sender
        castActive = state.castActive
        showPlayer = state.phase != .idle
    }

    @discardableResult
    func open(url: String) -> Bool {
        SwiftPlayer.shared.loadRaw(url: url)
    }

    func stop() {
        SwiftPlayer.shared.stop()
    }

    func retryWithProxy() {
        SwiftPlayer.shared.retryWithProxy()
    }

    func reportError(_ message: String) {
        SwiftPlayer.shared.reportError(message: message)
    }
}

/// Conforms the Kotlin PlayerEvents protocol (implemented by the native
/// AVPlayerViewController host) to this model's closures.
final class PlayerEventsImpl: NSObject, PlayerEvents {
    private let readyHandler: () -> Void
    private let errorHandler: (String) -> Void
    private let backHandler: () -> Void

    init(onReady: @escaping () -> Void, onError: @escaping (String) -> Void, onBack: @escaping () -> Void) {
        self.readyHandler = onReady
        self.errorHandler = onError
        self.backHandler = onBack
    }

    func onReady() {
        readyHandler()
    }

    func onError(message: String) {
        errorHandler(message)
    }

    func onBack() {
        backHandler()
    }
}
