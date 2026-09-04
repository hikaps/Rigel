import SwiftUI
import ComposeApp

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

    @Published private(set) var sessions: [JellyfinSession] = []

    private var connectTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sessionsTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?

    private var settings: SettingsStore { RigelCore.shared.settings }
    private var jellyfin: JellyfinClient { RigelCore.shared.jellyfin }

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
            let auth = await jellyfin.authenticateAsync(
                base: server,
                username: username,
                password: password,
                deviceId: "rigel-ios"
            )
            guard !Task.isCancelled else { return }
            busy = false
            if let auth {
                settings.setJellyfinServer(v: server)
                settings.setJellyfinUsername(v: username)
                settings.setJellyfinToken(v: auth.token)
                settings.setJellyfinUserId(v: auth.userId)
                self.password = ""
                loadedOnce = false
                items = []
                sessions = []
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
        settings.setJellyfinToken(v: "")
        busy = false
        searchBusy = false
        items = []
        sessions = []
        parentId = nil
        parentName = nil
        loadedOnce = false
        searchResults = []
        searchPerformed = false
        searchText = ""
        searchError = nil
        libraryError = nil
        notice = nil
    }

    func loadLibrary(at parentId: String?) {
        busy = true
        libraryError = nil
        browseTask?.cancel()
        browseTask = Task {
            do {
                let found = try await jellyfin.browseAsync(
                    base: base,
                    token: token,
                    userId: userId,
                    parentId: parentId
                )
                guard !Task.isCancelled else { return }
                busy = false
                loadedOnce = true
                items = found
                if sessions.isEmpty {
                    loadSessions()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
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
                let found = try await jellyfin.searchAsync(
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
                guard !Task.isCancelled else { return }
                searchBusy = false
                searchResults = []
                searchError = Self.errorMessage(error)
            }
        }
    }

    /// Resolves the playback payload for an item and hands it to `open`.
    /// Subtitle lookup failure plays the item without tracks (logged), and a
    /// superseded play never opens the player.
    func play(_ item: JellyfinItem, open: @escaping (String, String, [SubtitleTrack]) -> Void) {
        let url = JellyfinApi.shared.streamUrl(base: base, itemId: item.id, token: token)
        busy = true
        playbackTask?.cancel()
        playbackTask = Task {
            var tracks: [SubtitleTrack] = []
            do {
                tracks = try await jellyfin.itemSubtitleTracksAsync(
                    base: base,
                    token: token,
                    userId: userId,
                    itemId: item.id
                )
            } catch is CancellationError {
                return
            } catch {
                NSLog("[Rigel] Jellyfin subtitle lookup failed: %@", error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            busy = false
            open(url, item.name, tracks)
        }
    }

    func castToSession(_ session: JellyfinSession) {
        guard let firstItem = items.first(where: { !$0.isFolder }) else {
            notice = "No playable item loaded"
            noticeIsError = true
            return
        }
        busy = true
        Task {
            let ok = await jellyfin.playToSessionAsync(
                base: base,
                token: token,
                sessionId: session.id,
                itemIds: [firstItem.id]
            )
            guard !Task.isCancelled else { return }
            busy = false
            notice = ok ? "Sent to \(session.deviceName)" : "Cast failed"
            noticeIsError = !ok
        }
    }

    private func loadSessions() {
        sessionsTask?.cancel()
        sessionsTask = Task {
            let list = await jellyfin.sessionsAsync(base: base, token: token)
            guard !Task.isCancelled else { return }
            sessions = list
        }
    }

    private func invalidateInFlight() {
        browseTask?.cancel()
        searchTask?.cancel()
        sessionsTask?.cancel()
        playbackTask?.cancel()
    }

    private static func errorMessage(_ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Jellyfin request failed" : "Jellyfin request failed: \(detail)"
    }
}
