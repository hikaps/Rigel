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
    @Published var title: String?
    @Published var route: PlaybackRoute?
    @Published var proxyUrl: String?
    @Published var error: String?
    @Published var sender: String?
    @Published var subtitleTracks: [SubtitleTrack] = []
    @Published var selectedExternalSubtitleUrl: String?
    @Published var castActive = false
    @Published var remotePlayback = false
    @Published var destinationName = "This iPhone"
    @Published var destinationId = "local:iphone"
    @Published var planDetail: String?
    @Published var futureDestinationName = "This iPhone"
    @Published var futureDestinationAcceptsUrls = true
    @Published var longFormVideoAirPlayEligible = false
    @Published var probeDurationMs: Double?
    @Published var startPositionMs: Int64 = 0

    @Published var showPlayer = false
    private var observeJob: Kotlinx_coroutines_coreJob?
    private var selectionJob: Kotlinx_coroutines_coreJob?

    init() {
        observeJob = SwiftPlayer.shared.observe { [weak self] state in
            Task { @MainActor [weak self] in
                self?.apply(state)
            }
        }
        selectionJob = SwiftOutputSelection.shared.observe { [weak self] state in
            Task { @MainActor [weak self] in
                self?.applyFutureSelection(state)
            }
        }
        apply(SwiftPlayer.shared.snapshot())
        applyFutureSelection(SwiftOutputSelection.shared.snapshot())
    }

    deinit {
        observeJob?.cancel(cause: nil)
        selectionJob?.cancel(cause: nil)
    }

    var displayTitle: String? {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if let filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filename
        }
        return nil
    }

    var playableURL: String? { proxyUrl ?? sourceUrl }
    var routeLabel: String { route?.name ?? "" }
    var isPlaying: Bool { phase == .playing }
    var rendersNativePlayer: Bool {
        !remotePlayback && (phase == .playing || phase == .buffering)
    }

    func apply(_ state: PlayerUiState) {
        phase = state.phase
        sourceUrl = state.sourceUrl
        filename = state.filename
        title = state.title
        route = state.route
        proxyUrl = state.proxyUrl
        error = state.error
        sender = state.sender
        subtitleTracks = state.subtitleTracks
        selectedExternalSubtitleUrl = state.selectedExternalSubtitleUrl
        castActive = state.castActive
        remotePlayback = state.remotePlayback
        destinationName = state.destinationName
        destinationId = state.destinationId
        planDetail = state.planDetail
        startPositionMs = state.startPositionMs
        longFormVideoAirPlayEligible = state.longFormVideoAirPlayEligible
        if let probe = state.probe, !probe.isLive {
            probeDurationMs = probe.durationMs?.doubleValue
        } else {
            probeDurationMs = nil
        }
        showPlayer = state.phase != .idle
    }

    func applyFutureSelection(_ state: OutputSelectionState) {
        futureDestinationName = state.displayName
        futureDestinationAcceptsUrls = state.acceptsUrl
    }

    @discardableResult
    func open(url: String) -> Bool {
        open(url: url, title: nil, subtitleTracks: [])
    }

    @discardableResult
    func open(url: String, title: String?) -> Bool {
        open(url: url, title: title, subtitleTracks: [])
    }

    @discardableResult
    func open(url: String, title: String?, subtitleTracks: [SubtitleTrack]) -> Bool {
        SwiftPlayer.shared.loadRaw(url: url, title: title, subtitleTracks: subtitleTracks)
    }

    @discardableResult
    func openJellyfin(
        url: String,
        title: String,
        subtitleTracks: [SubtitleTrack],
        baseUrl: String,
        token: String,
        userId: String,
        itemId: String
    ) -> Bool {
        SwiftPlayer.shared.loadJellyfinItem(
            url: url,
            title: title,
            subtitleTracks: subtitleTracks,
            baseUrl: baseUrl,
            token: token,
            userId: userId,
            itemId: itemId
        )
    }

    func selectDestinationLocal() {
        let positionMs = SwiftPlayer.shared.currentPositionMs()
        SwiftPlayer.shared.selectLocal(positionMs: positionMs)
    }

    func selectDestinationAirPlay(routeId: String, name: String) {
        let positionMs = SwiftPlayer.shared.currentPositionMs()
        SwiftPlayer.shared.selectAirPlay(routeId: routeId, name: name, positionMs: positionMs)
    }

    func selectDestinationReceiver(_ target: CastTarget) {
        let positionMs = SwiftPlayer.shared.currentPositionMs()
        SwiftPlayer.shared.selectReceiver(target: target, positionMs: positionMs)
    }

    func seek(positionSeconds: Double, durationSeconds: Double) {
        guard positionSeconds.isFinite, durationSeconds.isFinite, durationSeconds >= 0 else { return }
        SwiftPlayer.shared.seek(
            positionMs: Int64(max(0, positionSeconds * 1000)),
            durationMs: Int64(durationSeconds * 1000)
        )
    }

    func selectExternalSubtitle(_ track: SubtitleTrack?, positionSeconds: Double) {
        let safeSeconds = positionSeconds.isFinite ? max(0, positionSeconds) : 0
        let maxMilliseconds = Double(Int64.max - 1)
        let milliseconds = min(safeSeconds * 1_000, maxMilliseconds)
        let positionMs = Int64(milliseconds.rounded(.down))
        SwiftPlayer.shared.selectExternalSubtitle(track: track, positionMs: positionMs)
    }

    func stop() {
        PlayerBridgeFactory.shared.create()?.stop()
        SwiftPlayer.shared.stop()
    }

    func retryWithProxy() {
        SwiftPlayer.shared.retryWithProxy()
    }

    func reportError(_ message: String) {
        SwiftPlayer.shared.reportError(message: message)
    }
}
