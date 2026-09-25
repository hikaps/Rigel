import SwiftUI
import ComposeApp

@MainActor
protocol JellyfinClientFacade {
    func authenticate(base: String, username: String, password: String, deviceId: String) async -> JellyfinAuth?
    func browse(base: String, token: String, userId: String, parentId: String?) async throws -> [JellyfinItem]
    func search(base: String, token: String, userId: String, term: String) async throws -> [JellyfinItem]
    func itemSubtitleTracks(base: String, token: String, userId: String, itemId: String) async throws -> [SubtitleTrack]
}

@MainActor
protocol JellyfinSettingsFacade {
    func jellyfinServer() -> String
    func setJellyfinServer(v: String)
    func jellyfinToken() -> String
    func setJellyfinToken(v: String) -> Bool
    func jellyfinUserId() -> String
    func setJellyfinUserId(v: String)
    func jellyfinUsername() -> String
    func setJellyfinUsername(v: String)
}

@MainActor
private struct DefaultJellyfinClientFacade: JellyfinClientFacade {
    let client: JellyfinClient

    func authenticate(base: String, username: String, password: String, deviceId: String) async -> JellyfinAuth? {
        await client.authenticateAsync(base: base, username: username, password: password, deviceId: deviceId)
    }

    func browse(base: String, token: String, userId: String, parentId: String?) async throws -> [JellyfinItem] {
        try await client.browseAsync(base: base, token: token, userId: userId, parentId: parentId)
    }

    func search(base: String, token: String, userId: String, term: String) async throws -> [JellyfinItem] {
        try await client.searchAsync(base: base, token: token, userId: userId, term: term)
    }

    func itemSubtitleTracks(base: String, token: String, userId: String, itemId: String) async throws -> [SubtitleTrack] {
        try await client.itemSubtitleTracksAsync(base: base, token: token, userId: userId, itemId: itemId)
    }
}

@MainActor
private struct DefaultJellyfinSettingsFacade: JellyfinSettingsFacade {
    let store: SettingsStore

    func jellyfinServer() -> String { store.jellyfinServer() }
    func setJellyfinServer(v: String) { store.setJellyfinServer(v: v) }
    func jellyfinToken() -> String { store.jellyfinToken() }
    func setJellyfinToken(v: String) -> Bool { store.setJellyfinToken(v: v) }
    func jellyfinUserId() -> String { store.jellyfinUserId() }
    func setJellyfinUserId(v: String) { store.setJellyfinUserId(v: v) }
    func jellyfinUsername() -> String { store.jellyfinUsername() }
    func setJellyfinUsername(v: String) { store.setJellyfinUsername(v: v) }
}

/// State for the Jellyfin source screen: connect, browse the library, search,
/// and push items to logged-in client sessions. One task handle per operation
/// kind — a new request cancels its predecessor and disconnect cancels
/// everything. The abandoned Kotlin request still runs to completion, but its
/// result is dropped (Task.isCancelled checks after each await), which is the
/// same staleness semantics the generation counters used to provide.
@MainActor
final class JellyfinViewModel: ObservableObject {
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""

    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false

    @Published private(set) var items: [JellyfinItem] = []
    @Published private(set) var parentId: String?
    @Published private(set) var parentName: String?
    @Published private(set) var loadedOnce = false
    @Published private(set) var libraryError: String?

    @Published var searchText = ""
    @Published private(set) var searchResults: [JellyfinItem] = []
    @Published private(set) var searchPerformed = false
    @Published private(set) var searchBusy = false
    @Published private(set) var searchError: String?


    private var connectTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?

    private let jellyfin: JellyfinClientFacade
    private let settings: JellyfinSettingsFacade

    init(jellyfin: JellyfinClientFacade? = nil, settings: JellyfinSettingsFacade? = nil) {
        self.jellyfin = jellyfin ?? DefaultJellyfinClientFacade(client: RigelCore.shared.jellyfin)
        self.settings = settings ?? DefaultJellyfinSettingsFacade(store: RigelCore.shared.settings)
    }

    var connected: Bool { !settings.jellyfinToken().isEmpty }
    var base: String { settings.jellyfinServer() }
    private var token: String { settings.jellyfinToken() }
    private var userId: String { settings.jellyfinUserId() }

    var displayServer: String {
        base.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    func prepareForm() {
        server = settings.jellyfinServer()
        username = settings.jellyfinUsername()
    }

    func connect() {
        let server = server.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        let password = password
        invalidateInFlight()
        busy = true
        notice = nil
        noticeIsError = false
        connectTask = Task {
            let auth = await jellyfin.authenticate(
                base: server,
                username: username,
                password: password,
                deviceId: "rigel-ios"
            )
            guard !Task.isCancelled else { return }
            busy = false
            if let auth {
                guard settings.setJellyfinToken(v: auth.token) else {
                    notice = "Unable to securely store Jellyfin credentials"
                    noticeIsError = true
                    return
                }
                let previousServer = settings.jellyfinServer()
                if previousServer != server { SwiftOutputSelection.shared.clearJellyfinServer(serverBase: previousServer) }
                settings.setJellyfinServer(v: server)
                settings.setJellyfinUsername(v: username)
                settings.setJellyfinUserId(v: auth.userId)
                self.password = ""
                loadedOnce = false
                items = []
                searchResults = []
                searchPerformed = false
                searchError = nil
                libraryError = nil
                loadLibrary(at: nil)
            } else {
                notice = "Authentication failed — check the server URL and credentials"
                noticeIsError = true
            }
        }
    }

    func disconnect() {
        invalidateInFlight()
        busy = false
        searchBusy = false
        guard settings.setJellyfinToken(v: "") else {
            notice = "Unable to securely clear Jellyfin credentials"
            noticeIsError = true
            return
        }
        SwiftOutputSelection.shared.clearJellyfinServer(serverBase: settings.jellyfinServer())
        password = ""
        items = []
        parentId = nil
        parentName = nil
        loadedOnce = false
        searchResults = []
        searchPerformed = false
        searchText = ""
        searchError = nil
        libraryError = nil
        notice = nil
        noticeIsError = false
    }

    func loadLibrary(at parentId: String?) {
        busy = true
        libraryError = nil
        browseTask?.cancel()
        browseTask = Task {
            do {
                let found = try await jellyfin.browse(
                    base: base,
                    token: token,
                    userId: userId,
                    parentId: parentId
                )
                guard !Task.isCancelled else { return }
                busy = false
                loadedOnce = true
                items = found
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !JellyfinCancellation.isCancellation(error) else { return }
                busy = false
                loadedOnce = true
                items = []
                libraryError = Self.errorMessage(error)
            }
        }
    }

    func openFolder(_ item: JellyfinItem) {
        parentId = item.id
        parentName = item.name
        items = []
        loadedOnce = false
        searchTask?.cancel()
        searchBusy = false
        searchResults = []
        searchPerformed = false
        searchError = nil
        loadLibrary(at: item.id)
    }

    func backToRoot() {
        parentId = nil
        parentName = nil
        items = []
        loadedOnce = false
        searchTask?.cancel()
        searchBusy = false
        searchResults = []
        searchPerformed = false
        searchError = nil
        loadLibrary(at: nil)
    }

    func search() {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchBusy = true
        searchPerformed = true
        searchResults = []
        searchError = nil
        notice = nil
        searchTask?.cancel()
        searchTask = Task {
            do {
                let found = try await jellyfin.search(
                    base: base,
                    token: token,
                    userId: userId,
                    term: term
                )
                guard !Task.isCancelled else { return }
                searchBusy = false
                searchResults = found
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !JellyfinCancellation.isCancellation(error) else { return }
                searchBusy = false
                searchResults = []
                searchError = Self.errorMessage(error)
            }
        }
    }

    /// Resolves the playback payload for an item and hands it to `open`.
    /// Subtitle lookup failure plays the item without tracks (logged), and a
    /// superseded play never opens the player.
    func play(_ item: JellyfinItem, open: @escaping (String, String, [SubtitleTrack], String, String, String, String) -> Void) {
        let url = JellyfinApi.shared.streamUrl(base: base, itemId: item.id, token: token)
        busy = true
        playbackTask?.cancel()
        playbackTask = Task {
            var tracks: [SubtitleTrack] = []
            do {
                tracks = try await jellyfin.itemSubtitleTracks(
                    base: base,
                    token: token,
                    userId: userId,
                    itemId: item.id
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !JellyfinCancellation.isCancellation(error) else { return }
                NSLog("[Rigel] Jellyfin subtitle lookup failed: %@", error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            busy = false
            open(url, item.name, tracks, base, token, userId, item.id)
        }
    }



    private func invalidateInFlight() {
        connectTask?.cancel()
        connectTask = nil
        browseTask?.cancel()
        searchTask?.cancel()
        playbackTask?.cancel()
    }

    private static func errorMessage(_ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Jellyfin request failed" : "Jellyfin request failed: \(detail)"
    }
}
