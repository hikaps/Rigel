import SwiftUI
import ComposeApp

/// Jellyfin source screen. Rendering only — state and requests live in
/// [JellyfinViewModel]; playback opens through the shared PlayerModel.
struct SourcesView: View {
    @EnvironmentObject private var player: PlayerModel
    @StateObject private var model = JellyfinViewModel()
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            Group {
                if model.connected {
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
                TextField("Server URL", text: $model.server)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $model.username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    if showPassword {
                        TextField("Password", text: $model.password)
                    } else {
                        SecureField("Password", text: $model.password)
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

            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(model.noticeIsError ? .red : Color.rigelStar)
                }
            }

            Section {
                Button {
                    model.connect()
                } label: {
                    HStack {
                        Spacer()
                        if model.busy {
                            ProgressView()
                        } else {
                            Text("Connect").font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(model.busy || model.server.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(Color.rigelStar)
                .listRowBackground(Color.clear)
            }
        }
        .onAppear {
            model.prepareForm()
        }
    }

    private var connectedList: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayServer)
                            .font(.headline)
                            .lineLimit(1)
                        Text(model.username)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.borderless)
                }
            }

            Section {
                HStack {
                    Text(model.parentName ?? "Library")
                        .font(.headline)
                    Spacer()
                    if model.parentId != nil {
                        Button {
                            model.backToRoot()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        model.loadLibrary(at: model.parentId)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.busy)
                }
                if model.busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading library…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let libraryError = model.libraryError {
                    Text(libraryError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !model.loadedOnce && model.items.isEmpty && !model.busy && model.libraryError == nil {
                    Button("Load library") { model.loadLibrary(at: model.parentId) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.rigelStar)
                        .listRowBackground(Color.clear)
                }
            }

            Section("Search Jellyfin") {
                HStack(spacing: 8) {
                    TextField("Movies, shows, or episodes", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { model.search() }
                    Button {
                        model.search()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.searchBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching Jellyfin…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if model.searchPerformed {
                Section("Search results") {
                    if let searchError = model.searchError {
                        Text(searchError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if !model.searchBusy && model.searchResults.isEmpty {
                        Text("No matches")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.searchResults, id: \.id) { item in
                        LibraryRow(item: item) {
                            model.openFolder(item)
                        } onPlay: {
                            play(item)
                        }
                    }
                }
            }

            Section("Library") {
                ForEach(model.items, id: \.id) { item in
                    LibraryRow(item: item) {
                        model.openFolder(item)
                    } onPlay: {
                        play(item)
                    }
                }
            }


            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(model.noticeIsError ? .red : Color.rigelStar)
                }
            }

            Section {
                Text("Choose a Jellyfin client in Playback Destination before playing a library item. Arbitrary URLs cannot be pushed to Jellyfin clients.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func play(_ item: JellyfinItem) {
        model.play(item) { url, title, tracks, base, token, userId, itemId in
            if player.futureDestinationAcceptsUrls {
                _ = player.open(url: url, title: title, subtitleTracks: tracks)
            } else {
                _ = player.openJellyfin(
                    url: url,
                    title: title,
                    subtitleTracks: [],
                    baseUrl: base,
                    token: token,
                    userId: userId,
                    itemId: itemId
                )
            }
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
