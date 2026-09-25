import Foundation
import XCTest
import ComposeApp
@testable import Rigel

@MainActor
private final class DeferredJellyfinFacade: JellyfinClientFacade {
    private var pendingAuthentication: [String: CheckedContinuation<JellyfinAuth?, Never>] = [:]
    private var authenticationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func authenticate(base: String, username: String, password: String, deviceId: String) async -> JellyfinAuth? {
        await withCheckedContinuation { continuation in
            pendingAuthentication[base] = continuation
            let waiters = authenticationWaiters.removeValue(forKey: base) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    func waitForAuthentication(base: String) async {
        if pendingAuthentication[base] != nil { return }
        await withCheckedContinuation { continuation in
            authenticationWaiters[base, default: []].append(continuation)
        }
    }

    func resolveAuthentication(base: String, with auth: JellyfinAuth?) {
        pendingAuthentication.removeValue(forKey: base)?.resume(returning: auth)
    }

    func browse(base: String, token: String, userId: String, parentId: String?) async throws -> [JellyfinItem] {
        []
    }

    func search(base: String, token: String, userId: String, term: String) async throws -> [JellyfinItem] {
        []
    }

    func itemSubtitleTracks(base: String, token: String, userId: String, itemId: String) async throws -> [SubtitleTrack] {
        []
    }
}

@MainActor
private final class InMemoryJellyfinSettingsFacade: JellyfinSettingsFacade {
    var server = ""
    var token = ""
    var userId = ""
    var username = ""

    func jellyfinServer() -> String { server }
    func setJellyfinServer(v: String) { server = v }
    func jellyfinToken() -> String { token }
    func setJellyfinToken(v: String) -> Bool {
        token = v
        return true
    }
    func jellyfinUserId() -> String { userId }
    func setJellyfinUserId(v: String) { userId = v }
    func jellyfinUsername() -> String { username }
    func setJellyfinUsername(v: String) { username = v }
}

/// A disconnect during in-flight Jellyfin requests cancels the tasks, and a
/// cancelled task returns before clearing its own flag. disconnect() must
/// therefore reset the activity flags itself, or the UI stays latched busy.
@MainActor
final class JellyfinViewModelTests: XCTestCase {

    func testDisconnectResetsActivityFlagsWhileRequestsInFlight() {
        let settings = InMemoryJellyfinSettingsFacade()
        let model = JellyfinViewModel(jellyfin: DeferredJellyfinFacade(), settings: settings)
        model.loadLibrary(at: nil)
        model.searchText = "star"
        model.search()
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.searchBusy)

        model.disconnect()

        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.searchBusy)
    }

    func testProductionJellyfinTokenStoreRoundTrips() {
        let settings = RigelCore.shared.settings
        let originalToken = settings.jellyfinToken()
        defer {
            XCTAssertTrue(
                settings.setJellyfinToken(v: originalToken),
                "failed to restore the pre-test Jellyfin token"
            )
            XCTAssertEqual(originalToken, settings.jellyfinToken(), "restored Jellyfin token did not round-trip")
        }

        let token = "swift-keychain-\(UUID().uuidString)"
        XCTAssertTrue(settings.setJellyfinToken(v: token), "secure token write was rejected")
        XCTAssertEqual(token, settings.jellyfinToken(), "secure token read did not return the written token")
        XCTAssertTrue(settings.setJellyfinToken(v: ""), "secure token clear was rejected")
        XCTAssertEqual("", settings.jellyfinToken(), "secure token remained after clear")
    }

    func testSupersededConnectDropsStaleAuthentication() async {
        let facade = DeferredJellyfinFacade()
        let settings = InMemoryJellyfinSettingsFacade()
        let model = JellyfinViewModel(jellyfin: facade, settings: settings)
        model.disconnect()

        model.server = "https://old.example"
        model.username = "alice"
        model.password = "old-password"
        model.connect()
        await facade.waitForAuthentication(base: "https://old.example")

        model.server = "https://new.example"
        model.password = "new-password"
        model.connect()
        await facade.waitForAuthentication(base: "https://new.example")

        facade.resolveAuthentication(
            base: "https://old.example",
            with: JellyfinAuth(token: "stale-token", userId: "stale-user")
        )
        await Task.yield()
        XCTAssertFalse(
            model.connected,
            "stale authentication changed credentials; notice=\(model.notice ?? "<nil>"), busy=\(model.busy)"
        )

        facade.resolveAuthentication(
            base: "https://new.example",
            with: JellyfinAuth(token: "current-token", userId: "current-user")
        )
        for _ in 0..<100 where !model.connected {
            await Task.yield()
        }
        XCTAssertTrue(
            model.connected,
            "current authentication did not persist credentials; notice=\(model.notice ?? "<nil>"), busy=\(model.busy)"
        )
    }
}
