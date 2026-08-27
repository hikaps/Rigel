import XCTest
import UIKit
import ComposeApp
import AVFoundation
@testable import Rigel

/// Guards the Kotlin→SwiftUI state mapping: PlayerModel must mirror
/// PlayerUiState exactly, and showPlayer must track phase != idle.
final class PlayerModelTests: XCTestCase {

    @MainActor
    func testPlayingStateMapsAndPresentsPlayer() {
        let model = PlayerModel()
        let state = PlayerUiState(
            phase: PlayerPhase.playing,
            sourceUrl: "http://origin/v.mkv",
            filename: nil,
            subtitleUrls: ["https://origin/en.vtt"],
            route: PlaybackRoute.direct,
            proxyUrl: nil,
            probe: nil,
            error: nil,
            castActive: false,
            sender: "kodi-remote"
        )
        model.apply(state)

        XCTAssertEqual(model.phase, PlayerPhase.playing)
        XCTAssertEqual(model.sourceUrl, "http://origin/v.mkv")
        XCTAssertEqual(model.sender, "kodi-remote")
        XCTAssertEqual(model.subtitleUrls, ["https://origin/en.vtt"])
        XCTAssertTrue(model.showPlayer)
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.playableURL, "http://origin/v.mkv", "direct playback serves the source URL")
    }

    @MainActor
    func testProxyUrlWinsForPlayableURL() {
        let model = PlayerModel()
        model.apply(PlayerUiState(
            phase: PlayerPhase.playing,
            sourceUrl: "http://origin/v.mkv",
            filename: nil,
            subtitleUrls: [],
            route: PlaybackRoute.remux,
            proxyUrl: "http://127.0.0.1:12345/session-x/index.m3u8",
            probe: nil,
            error: nil,
            castActive: true,
            sender: nil
        ))

        XCTAssertEqual(model.route, PlaybackRoute.remux)
        XCTAssertEqual(model.playableURL, "http://127.0.0.1:12345/session-x/index.m3u8")
        XCTAssertTrue(model.castActive)
    }

    @MainActor
    func testProbeDurationMapsToModel() {
        let model = PlayerModel()
        model.apply(state(probe: probe(durationMs: 600_000)))

        XCTAssertEqual(model.probeDurationMs, 600_000.0)

        model.apply(state(probe: probe(durationMs: nil)))
        XCTAssertNil(model.probeDurationMs)
        model.apply(state(probe: probe(durationMs: 600_000, isLive: true)))
        XCTAssertNil(model.probeDurationMs)
    }


    func testGenericProxyPlaylistTitleIsVideo() {
        XCTAssertEqual(
            RigelPlayerViewController.fallbackTitle(for: "http://127.0.0.1/session-x/index.m3u8"),
            "Video"
        )
        XCTAssertEqual(
            RigelPlayerViewController.fallbackTitle(for: "http://origin/Arrival.m3u8"),
            "Arrival"
        )
    }

    @MainActor
    func testHlsPlayerExposesVideoTransportTrackAndDeviceControls() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        controller.load(
            url: "http://127.0.0.1/session/index.m3u8",
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false
        )
        defer { controller.stopPlayback() }

        let close = view(controller.view, withAccessibilityLabel: "Close player")
        let tracks = view(controller.view, withAccessibilityLabel: "Audio and subtitles")
        let skipBackward = view(controller.view, withAccessibilityLabel: "Back 15 seconds")
        let skipForward = view(controller.view, withAccessibilityLabel: "Forward 15 seconds")
        let slider = view(controller.view, withAccessibilityIdentifier: "player.progressSlider")
        let topBar = view(controller.view, withAccessibilityIdentifier: "player.topBar")
        let bottomBar = view(controller.view, withAccessibilityIdentifier: "player.bottomBar")
        let playPause = view(controller.view, withAccessibilityLabel: "Play")
        let devices = view(controller.view, withAccessibilityLabel: "Playback destinations")
        XCTAssertNotNil(close)
        XCTAssertNotNil(tracks)
        XCTAssertNotNil(skipBackward)
        XCTAssertNotNil(skipForward)
        XCTAssertNotNil(slider)
        XCTAssertEqual(slider?.accessibilityLabel, "Playback position")
        XCTAssertEqual(slider?.accessibilityHint, "Adjust playback position")
        XCTAssertNotNil(topBar)
        XCTAssertNotNil(bottomBar)
        XCTAssertNotNil(playPause)
        XCTAssertNotNil(devices)
        XCTAssertEqual(topBar?.backgroundColor, .clear)
        XCTAssertEqual(bottomBar?.backgroundColor, .clear)
        XCTAssertEqual(topBar?.layer.cornerRadius, 0)
        XCTAssertEqual(bottomBar?.layer.cornerRadius, 0)
        XCTAssertEqual((close as? UIButton)?.configuration?.background.backgroundColor, .clear)
        XCTAssertEqual((playPause as? UIButton)?.configuration?.background.backgroundColor, .clear)
        XCTAssertFalse(tracks?.isHidden == true)
        var devicesRequested = false
        controller.onDevicesRequested = { devicesRequested = true }
        (devices as? UIButton)?.sendActions(for: .touchUpInside)
        XCTAssertTrue(devicesRequested)

        controller.hideControls()
        XCTAssertTrue(topBar?.alpha == 0)
        XCTAssertTrue(bottomBar?.alpha == 0)
        controller.showControls()
        XCTAssertFalse(topBar?.isHidden == true)
        XCTAssertTrue(bottomBar?.isHidden == false)
    }

    @MainActor
    func testProxyLoadWithKnownDurationShowsSeekTimeline() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        controller.load(
            url: "http://127.0.0.1/session/index.m3u8",
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false,
            durationSeconds: 600,
            isProxy: true
        )
        defer { controller.stopPlayback() }

        let slider = view(controller.view, withAccessibilityIdentifier: "player.progressSlider") as? UISlider
        let elapsed = label(controller.view, withText: "00:00")
        let duration = label(controller.view, withText: "10:00")
        XCTAssertNotNil(slider)
        XCTAssertFalse(slider?.isHidden ?? true)
        XCTAssertEqual(slider?.value ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(elapsed?.text, "00:00")
        XCTAssertEqual(duration?.text, "10:00")
        XCTAssertEqual(slider?.accessibilityValue, "00:00 of 10:00")
    }

    @MainActor
    func testDirectHlsLoadKeepsNativeDurationBehavior() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        controller.load(
            url: "http://127.0.0.1/session/index.m3u8",
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false,
            durationSeconds: 600,
            isProxy: false
        )
        defer { controller.stopPlayback() }

        let slider = view(controller.view, withAccessibilityIdentifier: "player.progressSlider") as? UISlider
        let duration = label(controller.view, withText: "—")
        XCTAssertNotNil(slider)
        XCTAssertTrue(slider?.isHidden ?? false)
        XCTAssertEqual(duration?.text, "—")
    }


    @MainActor
    func testProxyLoadWithoutKnownDurationHidesSeekTimeline() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        controller.load(
            url: "http://127.0.0.1/session/index.m3u8",
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false,
            isProxy: true
        )
        defer { controller.stopPlayback() }

        let slider = view(controller.view, withAccessibilityIdentifier: "player.progressSlider") as? UISlider
        let duration = label(controller.view, withText: "—")
        XCTAssertNotNil(slider)
        XCTAssertTrue(slider?.isHidden ?? false)
        XCTAssertEqual(duration?.text, "—")
    }


    private func view(_ root: UIView, withAccessibilityLabel label: String) -> UIView? {
        if root.accessibilityLabel == label { return root }
        for child in root.subviews {
            if let match = view(child, withAccessibilityLabel: label) {
                return match
            }
        }
        return nil
    }


    private func label(_ root: UIView, withText text: String) -> UILabel? {
        if let label = root as? UILabel, label.text == text { return label }
        for child in root.subviews {
            if let match = label(child, withText: text) {
                return match
            }
        }
        return nil
    }
    private func view(_ root: UIView, withAccessibilityIdentifier identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = view(child, withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }

    @MainActor
    func testIdleStateHidesPlayer() {
        let model = PlayerModel()
        model.apply(PlayerUiState(
            phase: PlayerPhase.idle,
            sourceUrl: nil,
            filename: nil,
            subtitleUrls: [],
            route: nil,
            proxyUrl: nil,
            probe: nil,
            error: nil,
            castActive: false,
            sender: nil
        ))
        XCTAssertFalse(model.showPlayer)
    }

    @MainActor
    func testErrorStateKeepsPlayerVisibleForRetry() {
        let model = PlayerModel()
        model.apply(PlayerUiState(
            phase: PlayerPhase.error,
            sourceUrl: "http://origin/v.mkv",
            filename: nil,
            subtitleUrls: [],
            route: nil,
            proxyUrl: nil,
            probe: nil,
            error: "probe failed",
            castActive: false,
            sender: nil
        ))
        XCTAssertTrue(model.showPlayer, "error phase must keep the full-screen host up for retry/close")
        XCTAssertEqual(model.error, "probe failed")
    }

    @MainActor
    func testLongFormEligibilityForKnownDirectVideo() {
        let model = PlayerModel()
        model.apply(state(probe: probe(durationMs: 600_000)))

        XCTAssertTrue(model.longFormVideoAirPlayEligible)
    }

    @MainActor
    func testShortVideoDoesNotUseLongFormAirPlayPolicy() {
        let model = PlayerModel()
        model.apply(state(probe: probe(durationMs: 30_000)))

        XCTAssertFalse(model.longFormVideoAirPlayEligible)
    }

    @MainActor
    func testAudioOnlyDoesNotUseLongFormAirPlayPolicy() {
        let model = PlayerModel()
        model.apply(state(probe: probe(videoCodec: nil)))

        XCTAssertFalse(model.longFormVideoAirPlayEligible)
    }

    @MainActor
    func testHlsAndProxyPlaybackDoNotUseLongFormAirPlayPolicy() {
        let model = PlayerModel()
        model.apply(state(probe: probe(container: "m3u8")))
        XCTAssertFalse(model.longFormVideoAirPlayEligible)

        model.apply(state(
            route: .remux,
            proxyUrl: "http://192.168.1.50:8090/session-x/index.m3u8",
            probe: probe()
        ))
        XCTAssertFalse(model.longFormVideoAirPlayEligible)
    }

    @MainActor
    func testUnknownDurationAndFailedPlaybackDoNotUseLongFormAirPlayPolicy() {
        let model = PlayerModel()
        model.apply(state(probe: probe(durationMs: nil)))
        XCTAssertFalse(model.longFormVideoAirPlayEligible)

        model.apply(state(probe: probe(isLive: true)))
        XCTAssertFalse(model.longFormVideoAirPlayEligible)

        model.apply(state(phase: .error, probe: probe(durationMs: 600_000)))
        XCTAssertFalse(model.longFormVideoAirPlayEligible)
    }

    @MainActor
    func testPlayerUsesLongFormVideoOnlyWhenEligible() throws {
        let audioSession = AVAudioSession.sharedInstance()
        defer {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }

        try RigelPlayerViewController.configureAudioSession(
            audioSession,
            longFormVideoAirPlayEligible: true
        )
        XCTAssertEqual(audioSession.routeSharingPolicy, .longFormVideo)

        try RigelPlayerViewController.configureAudioSession(
            audioSession,
            longFormVideoAirPlayEligible: false
        )
        XCTAssertEqual(audioSession.routeSharingPolicy, .default)
    }

    private func probe(
        container: String = "mp4",
        videoCodec: String? = "h264",
        durationMs: Int64? = 600_000,
        isLive: Bool = false
    ) -> ProbeResult {
        ProbeResult(
            container: container,
            videoCodec: videoCodec,
            audioCodecs: ["aac"],
            subtitleCodecs: [],
            durationMs: durationMs.map { KotlinLong(longLong: $0) },
            isLive: isLive,
            pixFmt: "yuv420p",
            width: 1920,
            height: 1080
        )
    }

    private func state(
        phase: PlayerPhase = .playing,
        route: PlaybackRoute = .direct,
        proxyUrl: String? = nil,
        probe: ProbeResult
    ) -> PlayerUiState {
        PlayerUiState(
            phase: phase,
            sourceUrl: "http://origin/video",
            filename: "video.mp4",
            subtitleUrls: [],
            route: route,
            proxyUrl: proxyUrl,
            probe: probe,
            error: nil,
            castActive: false,
            sender: nil
        )
    }
}
