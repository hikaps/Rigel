import XCTest
import UIKit
import SwiftUI
import ComposeApp
import AVFoundation
@testable import Rigel

private extension PlayerUiState {
    convenience init(
        phase: PlayerPhase,
        sourceUrl: String?,
        filename: String?,
        subtitleTracks: [SubtitleTrack],
        selectedExternalSubtitleUrl: String?,
        route: PlaybackRoute?,
        proxyUrl: String?,
        probe: ProbeResult?,
        error: String?,
        castActive: Bool,
        startPositionMs: Int64,
        sender: String?
    ) {
        self.init(
            phase: phase, sourceUrl: sourceUrl, filename: filename, title: nil,
            subtitleTracks: subtitleTracks,
            selectedExternalSubtitleUrl: selectedExternalSubtitleUrl,
            route: route, proxyUrl: proxyUrl, probe: probe, error: error,
            castActive: castActive, startPositionMs: startPositionMs, sender: sender,
            destinationKind: .local, destinationName: "This iPhone", destinationId: "local:iphone",
            remotePlayback: false, planDetail: nil
        )
    }
}

private extension ProbeResult {
    convenience init(
        container: String,
        videoCodec: String?,
        audioCodecs: [String],
        subtitleCodecs: [String],
        durationMs: KotlinLong?,
        isLive: Bool,
        pixFmt: String?,
        width: Int32,
        height: Int32
    ) {
        self.init(
            container: container, videoCodec: videoCodec, audioCodecs: audioCodecs,
            subtitleCodecs: subtitleCodecs, durationMs: durationMs, isLive: isLive,
            pixFmt: pixFmt, width: width, height: height,
            videoProfile: nil, videoLevel: nil, frameRate: nil, bitRate: nil,
            maxAudioChannels: 0
        )
    }
}

/// Guards the Kotlin→SwiftUI state mapping: PlayerModel must mirror
/// PlayerUiState exactly, and showPlayer must track phase != idle.
final class PlayerModelTests: XCTestCase {

    @MainActor
    func testAirPlayRouteIdentitySkipsUnchangedHandoff() {
        XCTAssertFalse(AirPlayRouteMonitor.routeChanged(currentIdentity: "airplay:route-1", routeId: "route-1"))
        XCTAssertTrue(AirPlayRouteMonitor.routeChanged(currentIdentity: "airplay:route-1", routeId: "route-2"))
    }

    @MainActor
    func testPlayingStateMapsAndPresentsPlayer() {
        let model = PlayerModel()
        let state = PlayerUiState(
            phase: PlayerPhase.playing,
            sourceUrl: "http://origin/v.mkv",
            filename: nil,
            subtitleTracks: [SubtitleTrack(url: "https://origin/en.vtt", language: nil, title: nil)],
            selectedExternalSubtitleUrl: "https://origin/en.vtt",
            route: PlaybackRoute.direct,
            proxyUrl: nil,
            probe: nil,
            error: nil,
            castActive: false,
            startPositionMs: 0,
            sender: "kodi-remote"
        )
        model.apply(state)

        XCTAssertEqual(model.phase, PlayerPhase.playing)
        XCTAssertEqual(model.sourceUrl, "http://origin/v.mkv")
        XCTAssertEqual(model.sender, "kodi-remote")
        XCTAssertEqual(model.selectedExternalSubtitleUrl, "https://origin/en.vtt")
        XCTAssertEqual(model.subtitleTracks, [SubtitleTrack(url: "https://origin/en.vtt", language: nil, title: nil)])
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
            subtitleTracks: [],
            selectedExternalSubtitleUrl: nil,
            route: PlaybackRoute.remux,
            proxyUrl: "http://127.0.0.1:12345/session-x/index.m3u8",
            probe: nil,
            error: nil,
            castActive: true,
            startPositionMs: 45_000,
            sender: nil
        ))

        XCTAssertEqual(model.route, PlaybackRoute.remux)
        XCTAssertEqual(model.playableURL, "http://127.0.0.1:12345/session-x/index.m3u8")
        XCTAssertTrue(model.castActive)
        XCTAssertEqual(model.startPositionMs, 45_000)
    }

    @MainActor
    func testProxySkipForwardsAbsoluteMediaPosition() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        var requested: Double?
        controller.onSeekRequested = { requested = $0 }
        controller.load(
            url: "http://127.0.0.1/session/index.m3u8",
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false,
            durationSeconds: 600,
            isProxy: true,
            startOffsetSeconds: 120
        )
        defer { controller.stopPlayback() }

        let skipForward = view(controller.view, withAccessibilityLabel: "Forward 15 seconds")
        (skipForward as? UIButton)?.sendActions(for: .touchUpInside)

        XCTAssertEqual(requested ?? -1, 135, accuracy: 0.001)
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
    func testHlsPlayerExposesSeparateTrackAndDeviceControls() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.load(
            url: "http://127.0.0.1/session/index.m3u8",
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false
        )
        defer { controller.stopPlayback() }
        controller.view.layoutIfNeeded()

        let close = view(controller.view, withAccessibilityLabel: "Close player")
        let audio = view(controller.view, withAccessibilityLabel: "Audio track")
        let subtitles = view(controller.view, withAccessibilityLabel: "Subtitles")
        let skipBackward = view(controller.view, withAccessibilityLabel: "Back 15 seconds")
        let skipForward = view(controller.view, withAccessibilityLabel: "Forward 15 seconds")
        let slider = view(controller.view, withAccessibilityIdentifier: "player.progressSlider")
        let topBar = view(controller.view, withAccessibilityIdentifier: "player.topBar")
        let bottomBar = view(controller.view, withAccessibilityIdentifier: "player.bottomBar")
        let playPause = view(controller.view, withAccessibilityLabel: "Play")
        let devices = view(controller.view, withAccessibilityLabel: "Playback destinations")
        XCTAssertNotNil(close)
        XCTAssertNotNil(audio)
        XCTAssertNotNil(subtitles)
        XCTAssertNotNil(skipBackward)
        XCTAssertNotNil(skipForward)
        XCTAssertNotNil(slider)
        XCTAssertEqual(slider?.accessibilityLabel, "Playback position")
        XCTAssertEqual(slider?.accessibilityHint, "Adjust playback position")
        XCTAssertNotNil(topBar)
        XCTAssertNotNil(bottomBar)
        XCTAssertNotNil(playPause)
        XCTAssertNotNil(devices)
        if let audio, let subtitles, let devices {
            XCTAssertLessThan(audio.frame.maxX, subtitles.frame.minX)
            XCTAssertLessThan(subtitles.frame.maxX, devices.frame.minX)
        }
        XCTAssertEqual(topBar?.backgroundColor, .clear)
        XCTAssertEqual(bottomBar?.backgroundColor, .clear)
        XCTAssertEqual(topBar?.layer.cornerRadius, 0)
        XCTAssertEqual(bottomBar?.layer.cornerRadius, 0)
        XCTAssertEqual((close as? UIButton)?.configuration?.background.backgroundColor, .clear)
        XCTAssertEqual((playPause as? UIButton)?.configuration?.background.backgroundColor, .clear)
        XCTAssertFalse(audio?.isHidden == true)
        XCTAssertFalse(subtitles?.isHidden == true)
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


    @MainActor
    func testOpenSubtitlePickerRefreshesWhenSidecarArrives() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let fixture = Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4")!
        var selectedTrack: SubtitleTrack?
        var selectedPosition: Double?
        controller.onExternalSubtitleSelected = { track, position in
            selectedTrack = track
            selectedPosition = position
        }
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.load(
            url: fixture.absoluteString,
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false
        )
        defer {
            controller.stopPlayback()
            window.isHidden = true
        }

        let subtitles = view(controller.view, withAccessibilityLabel: "Subtitles")
        XCTAssertNotNil(subtitles)
        (subtitles as? UIButton)?.sendActions(for: .touchUpInside)
        let sheet = waitUntil("presented subtitle picker") { controller.presentedViewController as? UIHostingController<TrackPickerSheet> }
        XCTAssertNotNil(sheet)

        let track = SubtitleTrack(url: "file:///tmp/fixture_sidecar.vtt", language: nil, title: "Delayed English")
        controller.installLoadedSidecar(
            track: track,
            order: 0,
            cues: [.init(start: 0, end: 10, text: "Delayed English")]
        )

        let refreshed = waitUntil("refreshed picker options") {
            sheet?.rootView.model.options.first { $0.title == "Delayed English" }
        }
        XCTAssertNotNil(refreshed, "already-open picker must gain the late sidecar row")

        refreshed?.select()
        XCTAssertEqual(selectedTrack, track)
        let off = sheet?.rootView.model.options.first { $0.id == "subtitles-off" }
        XCTAssertNotNil(off)
        off?.select()
        XCTAssertNil(selectedTrack)
    }

    /// Creates a controller whose native discovery results are captured for
    /// manual delivery, plus a key window so sheets can present. The box is
    /// a reference so completions appended later are visible to the test.
    @MainActor
    private final class CompletionBox {
        var items: [RigelPlayerViewController.TrackGroupLoaderCompletion] = []
    }

    @MainActor
    private func makeLoaderBackedController(
        events: PlayerEvents
    ) -> (RigelPlayerViewController, CompletionBox) {
        let completions = CompletionBox()
        let controller = RigelPlayerViewController(events: events) { _, completion in
            completions.items.append(completion)
        }
        return (controller, completions)
    }

    @MainActor
    func testOpenPickerSettlesToLoadedWithoutTracks() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let (controller, completionsBox) = makeLoaderBackedController(events: events)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.load(
            url: Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4")!.absoluteString,
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false
        )
        defer {
            controller.stopPlayback()
            window.isHidden = true
        }

        let audio = view(controller.view, withAccessibilityLabel: "Audio track") as? UIButton
        XCTAssertEqual(audio?.accessibilityValue, "Loading audio tracks")

        audio?.sendActions(for: .touchUpInside)
        let sheet = waitUntil("presented audio picker") { controller.presentedViewController as? UIHostingController<TrackPickerSheet> }
        XCTAssertEqual(sheet?.rootView.model.loadState, .loading)

        XCTAssertEqual(completionsBox.items.count, 1, "discovery must start exactly once per load")
        completionsBox.items[0](.success((nil, nil)))

        let settled = waitUntil("picker settles to loaded") {
            sheet?.rootView.model.loadState == .loaded  ? Optional(true) : nil
        }
        XCTAssertNotNil(settled, "already-open picker must settle when discovery succeeds")
        XCTAssertEqual(sheet?.rootView.model.loadState, .loaded)
        XCTAssertEqual(audio?.accessibilityValue, "No alternate audio tracks")
    }

    @MainActor
    func testFailedDiscoveryShowsFailedAndKeepsSidecarsSelectable() {
        var playbackError: String?
        let failingEvents = PlayerEventsImpl(onReady: {}, onError: { playbackError = $0 }, onBack: {})
        let (controller, completions) = makeLoaderBackedController(events: failingEvents)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.load(
            url: Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4")!.absoluteString,
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false
        )
        defer {
            controller.stopPlayback()
            window.isHidden = true
        }

        let subtitles = view(controller.view, withAccessibilityLabel: "Subtitles") as? UIButton
        subtitles?.sendActions(for: .touchUpInside)
        let sheet = waitUntil("presented subtitle picker") { controller.presentedViewController as? UIHostingController<TrackPickerSheet> }
        XCTAssertNotNil(sheet)

        completions.items[0](.failure(NSError(domain: "test", code: 7)))

        let settled = waitUntil("picker settles to failed") {
            sheet?.rootView.model.loadState == .failed  ? Optional(true) : nil
        }
        XCTAssertNotNil(settled, "already-open picker must show terminal failure")
        XCTAssertNil(playbackError, "track metadata failure must not fail playback")

        let track = SubtitleTrack(url: "file:///tmp/fixture_sidecar.vtt", language: nil, title: "Fallback English")
        var selectedTrack: SubtitleTrack?
        controller.onExternalSubtitleSelected = { track, _ in selectedTrack = track }
        controller.installLoadedSidecar(
            track: track,
            order: 0,
            cues: [.init(start: 0, end: 10, text: "Fallback English")]
        )
        XCTAssertEqual(sheet?.rootView.model.loadState, .failed)
        let row = sheet?.rootView.model.options.first { $0.title == "Fallback English" }
        XCTAssertNotNil(row, "sidecar must stay selectable after native discovery fails")
        row?.select()
        XCTAssertEqual(selectedTrack, track)
    }

    @MainActor
    func testReplacementMediaIgnoresStaleDiscoveryAndOldRowActions() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let (controller, completionsBox) = makeLoaderBackedController(events: events)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.load(
            url: Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4")!.absoluteString,
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false
        )
        defer {
            controller.stopPlayback()
            window.isHidden = true
        }

        XCTAssertEqual(completionsBox.items.count, 1)
        let oldCompletion = completionsBox.items[0]

        // Give item A a sidecar and capture its picker's Off action so we can
        // invoke it after B replaces A.
        let oldTrack = SubtitleTrack(url: "file:///tmp/old.vtt", language: nil, title: "Old Subtitles")
        controller.installLoadedSidecar(track: oldTrack, order: 0, cues: [.init(start: 0, end: 1, text: "Old")])
        var forwarded: SubtitleTrack?
        controller.onExternalSubtitleSelected = { track, _ in forwarded = track }
        let subtitlesA = view(controller.view, withAccessibilityLabel: "Subtitles") as? UIButton
        subtitlesA?.sendActions(for: .touchUpInside)
        let sheetA = waitUntil("presented picker for A") { controller.presentedViewController as? UIHostingController<TrackPickerSheet> }
        XCTAssertNotNil(sheetA)
        let oldOffAction = sheetA?.rootView.model.options.first { $0.id == "subtitles-off" }?.select
        XCTAssertNotNil(oldOffAction)
        // Close A's sheet so B's picker can present.
        sheetA?.dismiss(animated: false)
        waitUntil("sheet A dismissed") { controller.presentedViewController == nil ? true : nil }

        controller.load(
            url: Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4")!.absoluteString,
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false
        )
        XCTAssertEqual(completionsBox.items.count, 2)

        let subtitles = view(controller.view, withAccessibilityLabel: "Subtitles") as? UIButton
        subtitles?.sendActions(for: .touchUpInside)
        let sheet = waitUntil("presented replacement picker") { controller.presentedViewController as? UIHostingController<TrackPickerSheet> }
        XCTAssertEqual(sheet?.rootView.model.loadState, .loading)

        // Failing the replaced item A must not touch B's picker.
        oldCompletion(.failure(NSError(domain: "test", code: 8)))
        XCTAssertEqual(sheet?.rootView.model.loadState, .loading)

        // Succeeding B settles the open picker.
        completionsBox.items[1](.success((nil, nil)))
        let settled = waitUntil("replacement picker settles") {
            sheet?.rootView.model.loadState == .loaded  ? Optional(true) : nil
        }
        XCTAssertNotNil(settled)

        // An action captured from A's sheet must not forward a selection
        // once B is the current item.
        forwarded = nil
        oldOffAction?()
        XCTAssertNil(forwarded, "stale row action must be rejected after replacement")

        // A completion delivered after stopPlayback must not repopulate state.
        controller.stopPlayback()
        completionsBox.items[1](.success((nil, nil)))
        let dismissed = waitUntil("picker dismissal") {
            controller.presentedViewController == nil ? true : nil
        }
        XCTAssertNotNil(dismissed, "teardown must dismiss the open track picker")
        XCTAssertEqual(
            view(controller.view, withAccessibilityLabel: "Subtitles")?.accessibilityValue,
            nil
        )
    }

    /// Polls the main queue for up to two seconds until `check` returns a
    /// non-nil value, draining async UI work without fixed sleeps.
    @MainActor
    private func waitUntil<T>(_ what: String, _ check: @MainActor () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(2)
        var result: T?
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            result = check()
        } while result == nil && Date() < deadline
        if result == nil {
            NSLog("waitUntil(%@) timed out", what as NSString)
        }
        return result
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
            subtitleTracks: [],
            selectedExternalSubtitleUrl: nil,
            route: nil,
            proxyUrl: nil,
            probe: nil,
            error: nil,
            castActive: false,
            startPositionMs: 0,
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
            subtitleTracks: [],
            selectedExternalSubtitleUrl: nil,
            route: nil,
            proxyUrl: nil,
            probe: nil,
            error: "probe failed",
            castActive: false,
            startPositionMs: 0,
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

    @MainActor
    func testBufferingStateKeepsPlayerPresented() {
        let model = PlayerModel()
        let proxy = "http://127.0.0.1/session-x/index.m3u8"
        model.apply(state(
            phase: .buffering,
            route: .remux,
            proxyUrl: proxy,
            probe: probe()
        ))

        XCTAssertTrue(model.showPlayer)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playableURL, proxy)
    }

    @MainActor
    func testNativeControllerTracksInstalledItemURL() {
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        let oldURL = "http://127.0.0.1/session-old/index.m3u8"
        let newURL = "http://127.0.0.1/session-new/index.m3u8"

        controller.load(
            url: oldURL,
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false,
            durationSeconds: 600,
            isProxy: true
        )
        XCTAssertEqual(controller.loadedURL, oldURL)

        controller.load(
            url: newURL,
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false,
            durationSeconds: 600,
            isProxy: true
        )
        XCTAssertEqual(controller.loadedURL, newURL)

        controller.stopPlayback()
        XCTAssertNil(controller.loadedURL)
    }

    func testNativeProxySeekTargetRequiresCoveredRange() {
        XCTAssertNil(
            RigelPlayerViewController.nativeProxySeekTarget(
                absoluteTarget: 30, startOffsetSeconds: 120, seekableEndSeconds: nil
            ),
            "no published range must rebuild"
        )
        XCTAssertNil(
            RigelPlayerViewController.nativeProxySeekTarget(
                absoluteTarget: 30, startOffsetSeconds: 10, seekableEndSeconds: 1.5
            ),
            "a range under 2 s must rebuild"
        )
        XCTAssertNil(
            RigelPlayerViewController.nativeProxySeekTarget(
                absoluteTarget: 50, startOffsetSeconds: 120, seekableEndSeconds: 60
            ),
            "targets before the session start must rebuild"
        )
        XCTAssertNil(
            RigelPlayerViewController.nativeProxySeekTarget(
                absoluteTarget: 180, startOffsetSeconds: 120, seekableEndSeconds: 60
            ),
            "targets past the published edge must rebuild"
        )
        XCTAssertEqual(
            RigelPlayerViewController.nativeProxySeekTarget(
                absoluteTarget: 150, startOffsetSeconds: 120, seekableEndSeconds: 60
            )!,
            30
        )
    }

    func testAirPlayStartupWatchdogTimesOutWithoutExternalProgress() {
        var watchdog = AirPlayStartupWatchdog()

        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        for tick in 1...59 {
            XCTAssertFalse(watchdog.update(
                now: Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: false,
                positionSeconds: 0,
                rate: 1
            ))
        }
        XCTAssertTrue(watchdog.update(
            now: 15, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 15.25, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))

        watchdog.reset()
        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0, rate: 1
        ))
        for tick in 1...59 {
            XCTAssertFalse(watchdog.update(
                now: Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: true,
                positionSeconds: 0,
                rate: 1
            ))
        }
        XCTAssertTrue(watchdog.update(
            now: 15, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0, rate: 1
        ))
    }

    func testAirPlayStartupWatchdogAcceptsAdvancingExternalPlayback() {
        var watchdog = AirPlayStartupWatchdog()

        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 0.25, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0.25, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 16, eligible: true, paused: false, externalPlaying: true, positionSeconds: 16, rate: 1
        ))

        var localOnly = AirPlayStartupWatchdog()
        XCTAssertFalse(localOnly.update(
            now: 0, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        for tick in 1...59 {
            XCTAssertFalse(localOnly.update(
                now: Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: false,
                positionSeconds: Double(tick) * 0.25,
                rate: 1
            ))
        }
        XCTAssertTrue(localOnly.update(
            now: 15, eligible: true, paused: false, externalPlaying: false, positionSeconds: 15, rate: 1
        ))
    }

    func testAirPlayStartupWatchdogPausingStartsFreshWindow() {
        var watchdog = AirPlayStartupWatchdog()

        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        for tick in 1...39 {
            XCTAssertFalse(watchdog.update(
                now: Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: false,
                positionSeconds: 0,
                rate: 1
            ))
        }
        XCTAssertFalse(watchdog.update(
            now: 10, eligible: true, paused: true, externalPlaying: false, positionSeconds: 0, rate: 0
        ))
        XCTAssertFalse(watchdog.update(
            now: 30, eligible: true, paused: true, externalPlaying: false, positionSeconds: 0, rate: 0
        ))
        XCTAssertFalse(watchdog.update(
            now: 30, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        for tick in 1...59 {
            XCTAssertFalse(watchdog.update(
                now: 30 + Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: false,
                positionSeconds: 0,
                rate: 1
            ))
        }
        XCTAssertTrue(watchdog.update(
            now: 45, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
    }

    func testAirPlayStartupWatchdogIgnoresIneligibleLoadsAndSeekJump() {
        var watchdog = AirPlayStartupWatchdog()

        XCTAssertFalse(watchdog.update(
            now: 0, eligible: false, paused: false, externalPlaying: true, positionSeconds: 0, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 0.25, eligible: true, paused: false, externalPlaying: true, positionSeconds: 120, rate: 1
        ))
        for tick in 2...59 {
            XCTAssertFalse(watchdog.update(
                now: Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: true,
                positionSeconds: 120,
                rate: 1
            ))
        }
        XCTAssertTrue(watchdog.update(
            now: 15, eligible: true, paused: false, externalPlaying: true, positionSeconds: 120, rate: 1
        ))

        var progressingAfterJump = AirPlayStartupWatchdog()
        XCTAssertFalse(progressingAfterJump.update(
            now: 0, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0, rate: 1
        ))
        XCTAssertFalse(progressingAfterJump.update(
            now: 0.25, eligible: true, paused: false, externalPlaying: true, positionSeconds: 120, rate: 1
        ))
        XCTAssertFalse(progressingAfterJump.update(
            now: 0.5, eligible: true, paused: false, externalPlaying: true, positionSeconds: 120.25, rate: 1
        ))
        XCTAssertFalse(progressingAfterJump.update(
            now: 15, eligible: true, paused: false, externalPlaying: true, positionSeconds: 120.25, rate: 1
        ))

        var nanPosition = AirPlayStartupWatchdog()
        XCTAssertFalse(nanPosition.update(
            now: 0, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        for tick in 1...59 {
            XCTAssertFalse(nanPosition.update(
                now: Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: false,
                positionSeconds: .nan,
                rate: 1
            ))
        }
        XCTAssertTrue(nanPosition.update(
            now: 15, eligible: true, paused: false, externalPlaying: false, positionSeconds: .nan, rate: 1
        ))
    }

    func testAirPlayStartupWatchdogResetsAfterSuccessfulStartup() {
        var watchdog = AirPlayStartupWatchdog()

        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 0.25, eligible: true, paused: false, externalPlaying: true, positionSeconds: 0.25, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 30, eligible: true, paused: false, externalPlaying: true, positionSeconds: 30, rate: 1
        ))

        watchdog.reset()
        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        for tick in 1...59 {
            XCTAssertFalse(watchdog.update(
                now: Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: false,
                positionSeconds: 0,
                rate: 1
            ))
        }
        XCTAssertTrue(watchdog.update(
            now: 15, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
    }

    func testAirPlayStartupWatchdogRestartsAfterLongSamplingGap() {
        var watchdog = AirPlayStartupWatchdog()

        XCTAssertFalse(watchdog.update(
            now: 0, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        XCTAssertFalse(watchdog.update(
            now: 3, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        for tick in 1...55 {
            XCTAssertFalse(watchdog.update(
                now: 3 + Double(tick) * 0.25,
                eligible: true,
                paused: false,
                externalPlaying: false,
                positionSeconds: 0,
                rate: 1
            ))
        }
        XCTAssertFalse(watchdog.update(
            now: 17, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
        XCTAssertTrue(watchdog.update(
            now: 18, eligible: true, paused: false, externalPlaying: false, positionSeconds: 0, rate: 1
        ))
    }


    func testProxySessionIdExtraction() {
        XCTAssertEqual(
            RigelPlayerViewController.proxySessionId(from: "http://10.0.0.2:49152/session-abc123/index.m3u8"),
            "session-abc123"
        )
        XCTAssertNil(RigelPlayerViewController.proxySessionId(from: nil))
        XCTAssertNil(RigelPlayerViewController.proxySessionId(from: "http://10.0.0.2/video.mp4"))
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
    @MainActor
    func testSubtitleCustomizationModelPersistsImmediateChanges() {
        let originalAppearance = SubtitlePreferences.appearance
        let originalDelay = SubtitlePreferences.delay
        defer {
            SubtitlePreferences.appearance = originalAppearance
            SubtitlePreferences.delay = originalDelay
        }
        var callbackCount = 0
        let model = SubtitleCustomizationModel { appearance, delay in
            callbackCount += 1
            XCTAssertEqual(SubtitlePreferences.appearance, appearance)
            XCTAssertEqual(SubtitlePreferences.delay, delay, accuracy: 0.0001)
        }

        model.updateAppearance {
            $0.fontSizePoints = 30
            $0.textColor = .gold
            $0.textOpacity = 0.6
            $0.backgroundColor = .navy
            $0.backgroundOpacity = 0.5
            $0.outlineEnabled = false
            $0.bottomInset = 200
        }
        model.setDelay(1.2)

        XCTAssertEqual(model.appearance.fontSizePoints, 30)
        XCTAssertEqual(model.appearance.textColor, .gold)
        XCTAssertEqual(model.appearance.textOpacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(model.appearance.backgroundColor, .navy)
        XCTAssertEqual(model.appearance.backgroundOpacity, 0.5, accuracy: 0.0001)
        XCTAssertFalse(model.appearance.outlineEnabled)
        XCTAssertEqual(model.appearance.bottomInset, 200)
        XCTAssertEqual(model.delay, 1.2, accuracy: 0.0001)
        XCTAssertEqual(callbackCount, 2)
    }

    @MainActor
    func testParsedSidecarUsesPersistedStyledLabel() {
        let originalAppearance = SubtitlePreferences.appearance
        let originalDelay = SubtitlePreferences.delay
        defer {
            SubtitlePreferences.appearance = originalAppearance
            SubtitlePreferences.delay = originalDelay
        }
        SubtitlePreferences.appearance = SubtitleAppearance(
            fontSizePoints: 28,
            bold: true,
            textColor: .gold,
            textOpacity: 0.7,
            backgroundColor: .navy,
            backgroundOpacity: 0.5,
            outlineEnabled: true,
            outlineColor: .red,
            bottomInset: 180
        )
        let events = PlayerEventsImpl(onReady: {}, onError: { _ in }, onBack: {})
        let controller = RigelPlayerViewController(events: events)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let track = SubtitleTrack(url: "https://origin/subtitles.srt", language: "en", title: "English")
        controller.load(
            url: "http://127.0.0.1/session/video.mp4",
            title: nil,
            sender: nil,
            longFormVideoAirPlayEligible: false,
            subtitleTracks: [],
            selectedExternalSubtitleUrl: track.url
        )
        controller.installLoadedSidecar(
            track: track,
            order: 0,
            cues: [.init(start: 0, end: 10, text: "Styled subtitle")]
        )
        defer { controller.stopPlayback() }

        let label = view(controller.view, withAccessibilityIdentifier: "player.subtitleLabel") as? UILabel
        XCTAssertEqual(label?.attributedText?.string, "Styled subtitle")
        XCTAssertEqual(label?.font.pointSize ?? 0, 28, accuracy: 0.1)
        XCTAssertEqual(label?.backgroundColor?.cgColor.alpha ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(
            label?.attributedText?.attribute(.strokeWidth, at: 0, effectiveRange: nil) as? NSNumber,
            -3
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
            subtitleTracks: [],
            selectedExternalSubtitleUrl: nil,
            route: route,
            proxyUrl: proxyUrl,
            probe: probe,
            error: nil,
            castActive: false,
            startPositionMs: 0,
            sender: nil
        )
    }
    @MainActor
    func testRemoteDestinationHidesNativePlayerSurface() {
        let model = PlayerModel()
        model.apply(PlayerUiState(
            phase: .playing,
            sourceUrl: "http://origin/movie.mp4",
            filename: "movie.mp4",
            title: "Movie",
            subtitleTracks: [],
            selectedExternalSubtitleUrl: nil,
            route: .direct,
            proxyUrl: nil,
            probe: nil,
            error: nil,
            castActive: true,
            startPositionMs: 0,
            sender: nil,
            destinationKind: .roku,
            destinationName: "Living Room",
            destinationId: "roku:r1",
            remotePlayback: true,
            planDetail: "Direct play on Living Room"
        ))
        XCTAssertTrue(model.remotePlayback)
        XCTAssertFalse(model.rendersNativePlayer)
        XCTAssertEqual(model.destinationName, "Living Room")
    }
}