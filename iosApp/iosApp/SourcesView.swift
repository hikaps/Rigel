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
    @State private var sessions: [JellyfinSession] = []
    @State private var parentId: String?
    @State private var parentName: String?
    @State private var loadedOnce = false

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
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        loadLibrary()
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
                if !loadedOnce && items.isEmpty && !busy {
                    Button("Load library") { loadLibrary() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.rigelStar)
                        .listRowBackground(Color.clear)
                }
            }

            Section("Library") {
                ForEach(items, id: \.id) { item in
                    LibraryRow(item: item) {
                        parentId = item.id
                        parentName = item.name
                        loadLibrary()
                    } onPlay: {
                        let url = JellyfinApi.shared.streamUrl(base: base, itemId: item.id, token: token)
                        _ = player.open(url: url)
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
        busy = true
        notice = nil
        jellyfin.authenticate(
            base: server.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            deviceId: "rigel-ios"
        ) { auth, _ in
            busy = false
            if let auth {
                settings.setJellyfinServer(v: server.trimmingCharacters(in: .whitespaces))
                settings.setJellyfinUsername(v: username.trimmingCharacters(in: .whitespaces))
                settings.setJellyfinToken(v: auth.token)
                settings.setJellyfinUserId(v: auth.userId)
                password = ""
                loadedOnce = false
                items = []
                sessions = []
                loadLibrary()
            } else {
                notice = "Authentication failed — check the server URL and credentials"
                noticeIsError = true
            }
        }
    }

    private func disconnect() {
        settings.setJellyfinToken(v: "")
        items = []
        sessions = []
        parentId = nil
        parentName = nil
        loadedOnce = false
        notice = nil
    }

    private func loadLibrary() {
        busy = true
        jellyfin.browse(base: base, token: token, userId: userId, parentId: parentId) { found, _ in
            items = found ?? []
            busy = false
            loadedOnce = true
            if sessions.isEmpty {
                jellyfin.sessions(base: base, token: token) { list, _ in
                    sessions = list ?? []
                }
            }
        }
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
            busy = false
            notice = ok?.boolValue == true ? "Sent to \(session.deviceName)" : "Cast failed"
            noticeIsError = ok?.boolValue != true
        }
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
