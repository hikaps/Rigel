import SwiftUI
import ComposeApp

/// Jellyfin source: connect, browse the library, play locally or push a
/// library item to a logged-in client session. All calls go to the Kotlin
/// JellyfinClient through completion handlers.
struct SourcesView: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsError = false

    @State private var items: [JellyfinItem] = []
    @State private var searchText = ""
    @State private var searchResults: [JellyfinItem] = []
    @State private var searchPerformed = false
    @State private var searchBusy = false
    @State private var searchError: String?
    @State private var libraryError: String?
    @State private var sessions: [JellyfinSession] = []
    @State private var parentId: String?
    @State private var parentName: String?
    @State private var loadedOnce = false
    @State private var connectionGeneration = 0
    @State private var libraryGeneration = 0
    @State private var searchGeneration = 0
    @State private var sessionGeneration = 0
    @State private var playGeneration = 0


    private var settings: SettingsStore { RigelCore.shared.settings }
    private var jellyfin: JellyfinClient { RigelCore.shared.jellyfin }
    private var connected: Bool { !settings.jellyfinToken().isEmpty }
    private var base: String { settings.jellyfinServer() }
    private var token: String { settings.jellyfinToken() }
    private var userId: String { settings.jellyfinUserId() }

    var body: some View {
        NavigationStack {
            Group {
                if connected {
                    connectedList
                } else {
                    connectForm
                }
            }
            .navigationTitle("Sources")
        }
    }

    private var connectForm: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jellyfin")
                            .font(.headline)
                        Text("Browse your Jellyfin library and play here or push to logged-in clients.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "video")
                        .foregroundStyle(Color.rigelStar)
                }
            }

            Section("Server") {
                TextField("Server URL", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    if showPassword {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(noticeIsError ? .red : Color.rigelStar)
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Spacer()
                        if busy {
                            ProgressView()
                        } else {
                            Text("Connect").font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(busy || server.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(Color.rigelStar)
                .listRowBackground(Color.clear)
            }
        }
        .onAppear {
            server = settings.jellyfinServer()
            username = settings.jellyfinUsername()
        }
    }

    private var connectedList: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayServer)
                            .font(.headline)
                            .lineLimit(1)
                        Text(username)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.borderless)
                }
            }

            Section {
                HStack {
                    Text(parentName ?? "Library")
                        .font(.headline)
                    Spacer()
                    if parentId != nil {
                        Button {
                            parentId = nil
                            parentName = nil
                            items = []
                            loadedOnce = false
                            searchGeneration &+= 1
                            searchBusy = false
                            searchResults = []
                            searchPerformed = false
                            searchError = nil
                            loadLibrary(at: nil)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        loadLibrary(at: parentId)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                }
                if busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading library…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let libraryError {
                    Text(libraryError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !loadedOnce && items.isEmpty && !busy && libraryError == nil {
                    Button("Load library") { loadLibrary(at: parentId) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.rigelStar)
                        .listRowBackground(Color.clear)
                }
            }

            Section("Search Jellyfin") {
                HStack(spacing: 8) {
                    TextField("Movies, shows, or episodes", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { searchLibrary() }
                    Button {
                        searchLibrary()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if searchBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching Jellyfin…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if searchPerformed {
                Section("Search results") {
                    if let searchError {
                        Text(searchError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if !searchBusy && searchResults.isEmpty {
                        Text("No matches")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(searchResults, id: \.id) { item in
                        LibraryRow(item: item) {
                            openFolder(item)
                        } onPlay: {
                            play(item)
                        }
                    }
                }
            }

            Section("Library") {
                ForEach(items, id: \.id) { item in
                    LibraryRow(item: item) {
                        openFolder(item)
                    } onPlay: {
                        play(item)
                    }
                }
            }

            if !sessions.isEmpty {
                Section("Cast library item to a client") {
                    ForEach(sessions, id: \.id) { session in
                        HStack {
                            Image(systemName: "airplayvideo")
                                .foregroundStyle(Color.rigelStar)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.deviceName)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(session.client)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cast") { castToSession(session) }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.rigelStar)
                                .disabled(busy)
                        }
                    }
                }
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(noticeIsError ? .red : Color.rigelStar)
                }
            }

            Section {
                Text("Note: Jellyfin session remote control plays library items only — arbitrary URLs cannot be pushed to Jellyfin clients.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayServer: String {
        base.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func connect() {
        connectionGeneration &+= 1
        libraryGeneration &+= 1
        searchGeneration &+= 1
        sessionGeneration &+= 1
        let requestGeneration = connectionGeneration
        busy = true
        notice = nil
        noticeIsError = false
        jellyfin.authenticate(
            base: server.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            deviceId: "rigel-ios"
        ) { auth, _ in
            Task { @MainActor in
                guard self.connectionGeneration == requestGeneration else { return }
                self.busy = false
                if let auth {
                    self.settings.setJellyfinServer(v: self.server.trimmingCharacters(in: .whitespaces))
                    self.settings.setJellyfinUsername(v: self.username.trimmingCharacters(in: .whitespaces))
                    self.settings.setJellyfinToken(v: auth.token)
                    self.settings.setJellyfinUserId(v: auth.userId)
                    self.password = ""
                    self.loadedOnce = false
                    self.items = []
                    self.sessions = []
                    self.searchResults = []
                    self.searchPerformed = false
                    self.searchError = nil
                    self.libraryError = nil
                    self.loadLibrary(at: nil)
                } else {
                    self.notice = "Authentication failed — check the server URL and credentials"
                    self.noticeIsError = true
                }
            }
        }
    }

    private func disconnect() {
        connectionGeneration &+= 1
        libraryGeneration &+= 1
        searchGeneration &+= 1
        sessionGeneration &+= 1
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

    private func loadLibrary(at requestedParentId: String?) {
        libraryGeneration &+= 1
        let requestGeneration = libraryGeneration
        let connection = connectionGeneration
        let requestBase = base
        let requestToken = token
        let requestUserId = userId
        busy = true
        libraryError = nil
        jellyfin.browse(
            base: requestBase,
            token: requestToken,
            userId: requestUserId,
            parentId: requestedParentId
        ) { found, error in
            Task { @MainActor in
                guard self.connectionGeneration == connection,
                      self.libraryGeneration == requestGeneration else { return }
                self.busy = false
                self.loadedOnce = true
                if let error {
                    guard !isCancellation(error) else { return }
                    self.items = []
                    self.libraryError = self.errorMessage(error)
                    return
                }
                self.libraryError = nil
                self.items = found ?? []
                if self.sessions.isEmpty {
                    self.loadSessions(connection: connection)
                }
            }
        }
    }

    private func loadSessions(connection: Int) {
        sessionGeneration &+= 1
        let requestGeneration = sessionGeneration
        let requestBase = base
        let requestToken = token
        jellyfin.sessions(base: requestBase, token: requestToken) { list, _ in
            Task { @MainActor in
                guard self.connectionGeneration == connection,
                      self.sessionGeneration == requestGeneration else { return }
                self.sessions = list ?? []
            }
        }
    }

    private func searchLibrary() {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchGeneration &+= 1
        let requestGeneration = searchGeneration
        let connection = connectionGeneration
        let requestBase = base
        let requestToken = token
        let requestUserId = userId
        searchBusy = true
        searchPerformed = true
        searchResults = []
        searchError = nil
        notice = nil
        jellyfin.search(
            base: requestBase,
            token: requestToken,
            userId: requestUserId,
            term: term
        ) { found, error in
            Task { @MainActor in
                guard self.connectionGeneration == connection,
                      self.searchGeneration == requestGeneration else { return }
                self.searchBusy = false
                if let error {
                    guard !isCancellation(error) else { return }
                    self.searchResults = []
                    self.searchError = self.errorMessage(error)
                    return
                }
                self.searchError = nil
                self.searchResults = found ?? []
            }
        }
    }

    private func openFolder(_ item: JellyfinItem) {
        parentId = item.id
        parentName = item.name
        items = []
        loadedOnce = false
        searchGeneration &+= 1
        searchBusy = false
        searchResults = []
        searchPerformed = false
        searchError = nil
        loadLibrary(at: item.id)
    }

    private func play(_ item: JellyfinItem) {
        playGeneration &+= 1
        let requestGeneration = playGeneration
        let requestBase = base
        let requestToken = token
        let requestUserId = userId
        let connection = connectionGeneration
        let url = JellyfinApi.shared.streamUrl(
            base: requestBase,
            itemId: item.id,
            token: requestToken
        )
        busy = true
        jellyfin.itemSubtitleTracks(
            base: requestBase,
            token: requestToken,
            userId: requestUserId,
            itemId: item.id
        ) { tracks, error in
            Task { @MainActor in
                guard self.connectionGeneration == connection,
                      self.playGeneration == requestGeneration else { return }
                self.busy = false
                if let error {
                    guard !self.isCancellation(error) else { return }
                    NSLog("[Rigel] Jellyfin subtitle lookup failed: %@", error.localizedDescription)
                    _ = self.player.open(url: url, title: item.name)
                    return
                }
                _ = self.player.open(
                    url: url,
                    title: item.name,
                    subtitleTracks: tracks ?? []
                )
            }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        JellyfinCancellation.isCancellation(error)
    }

    private func errorMessage(_ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Jellyfin request failed" : "Jellyfin request failed: \(detail)"
    }

    private func castToSession(_ session: JellyfinSession) {
        guard let firstItem = items.first(where: { !$0.isFolder }) else {
            notice = "No playable item loaded"
            noticeIsError = true
            return
        }
        busy = true
        jellyfin.playToSession(
            base: base,
            token: token,
            sessionId: session.id,
            itemIds: [firstItem.id]
        ) { ok, _ in
            Task { @MainActor in
                self.busy = false
                self.notice = ok?.boolValue == true ? "Sent to \(session.deviceName)" : "Cast failed"
                self.noticeIsError = ok?.boolValue != true
            }
        }
    }
}

/// Classifies completion-handler errors from the annotated Kotlin/Native
/// bridge. Kotlin exceptions surface as NSError (domain "KotlinException")
/// with the exported KotlinThrowable in userInfo["KotlinException"]; that
/// throwable does not conform to Swift Error, so cancellation is identified
/// by asking Kotlin.
enum JellyfinCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain.contains("CancellationException") { return true }
        let throwable = ns.kotlinException ?? ns.userInfo["KotlinException"]
        guard let kotlinThrowable = throwable as? KotlinThrowable else {
            return false
        }
        return JellyfinInterop.shared.isCancellation(throwable: kotlinThrowable)
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var player: PlayerModel
    let item: JellyfinItem
    let onOpenFolder: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isFolder ? "folder" : "film")
                .foregroundStyle(item.isFolder ? Color.rigelSteel : Color.rigelStar)
                .frame(width: 22)
            Text(item.name)
                .font(.body)
                .lineLimit(1)
            Spacer()
            if item.isFolder {
                Button(action: onOpenFolder) {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else {
                Button("Play", action: onPlay)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rigelStar)
            }
        }
        .padding(.vertical, 2)
    }
}
