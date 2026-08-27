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
    @Published var subtitleUrls: [String] = []
    @Published var castActive = false
    @Published var longFormVideoAirPlayEligible = false
    @Published var probeDurationMs: Double?
    @Published var showPlayer = false
    private var requestedTitle: String?
    private var requestedTitleURL: String?

    private var observeJob: Kotlinx_coroutines_coreJob?

    init() {
        observeJob = SwiftPlayer.shared.observe { [weak self] state in
            Task { @MainActor [weak self] in
                self?.apply(state)
            }
        }
        apply(SwiftPlayer.shared.snapshot())
    }

    deinit {
        observeJob?.cancel(cause: nil)
    }

    var displayTitle: String? {
        if let filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filename
        }
        if let requestedTitle, !requestedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return requestedTitle
        }
        return nil
    }

    var playableURL: String? { proxyUrl ?? sourceUrl }

    var routeLabel: String { route?.name ?? "" }

    var isPlaying: Bool { phase == .playing }

    func apply(_ state: PlayerUiState) {
        if state.phase == .idle ||
            (requestedTitleURL != nil && requestedTitleURL != state.sourceUrl) {
            requestedTitle = nil
            requestedTitleURL = nil
        }
        phase = state.phase
        sourceUrl = state.sourceUrl
        filename = state.filename
        route = state.route
        proxyUrl = state.proxyUrl
        error = state.error
        sender = state.sender
        subtitleUrls = state.subtitleUrls
        castActive = state.castActive
        longFormVideoAirPlayEligible = state.longFormVideoAirPlayEligible
        probeDurationMs = state.probe?.durationMs?.doubleValue
        showPlayer = state.phase != .idle
    }

    @discardableResult
    func open(url: String) -> Bool {
        open(url: url, title: nil)
    }

    @discardableResult
    func open(url: String, title: String?) -> Bool {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedTitle = trimmedTitle.flatMap { $0.isEmpty ? nil : $0 }
        requestedTitleURL = url
        let accepted = SwiftPlayer.shared.loadRaw(url: url, title: trimmedTitle)
        if !accepted {
            requestedTitle = nil
            requestedTitleURL = nil
        }
        return accepted
    }

    func stop() {
        // Native AVPlayer must stop too, or playback (and its poll timer)
        // keeps running after the player UI is dismissed.
        PlayerBridgeFactory.shared.create()?.stop()
        SwiftPlayer.shared.stop()
    }

    func retryWithProxy() {
        SwiftPlayer.shared.retryWithProxy()
    }

    func reportError(_ message: String) {
        // Native teardown is bound to the originating controller in
        // PlayerView.makeUIViewController: a stale .failed from a dismantled
        // player must not stop the bridge's current (possibly newer)
        // controller. Only forward the error; Kotlin rejects stale state.
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
