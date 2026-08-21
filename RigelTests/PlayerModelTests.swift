import XCTest
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
            subtitleUrls: [],
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
    func testPlayerUsesLongFormVideoAirPlayPolicy() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try RigelPlayerViewController.configureAudioSession(audioSession)
        defer {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }

        XCTAssertEqual(audioSession.category, .playback)
        XCTAssertEqual(audioSession.mode, .moviePlayback)
        XCTAssertEqual(audioSession.routeSharingPolicy, .longFormVideo)
    }
}
