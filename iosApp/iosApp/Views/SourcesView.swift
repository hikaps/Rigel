import SwiftUI
import ComposeApp

/// Jellyfin source screen. Rendering only — state and requests live in
/// [JellyfinViewModel]; playback opens through the shared PlayerModel.
struct SourcesView: View {
    @EnvironmentObject private var player: PlayerModel
    @StateObject private var model = JellyfinViewModel()
    @State private var showPassword = false
    @State private var showVersionPicker = false

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
        .sheet(isPresented: $showVersionPicker, onDismiss: { model.dismissVersionChoice() }) {
            versionPicker
        }
        .onChange(of: model.versionChoice?.id) { itemId in
            showVersionPicker = itemId != nil
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
                        if model.connectBusy {
                            ProgressView()
                        } else {
                            Text("Connect").font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(model.connectBusy || model.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                        Text(model.displayUsername)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.borderless)
                }
            }

            if !model.searchPath.isEmpty {
                Section {
                    HStack {
                        Button("Back") { model.goBack() }
                            .buttonStyle(.borderless)
                        Text(model.currentPathNames.joined(separator: "  ›  "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Search results") { model.backToSearchResults() }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section("Search Jellyfin") {
                HStack(spacing: 8) {
                    TextField("Movies, shows, or episodes", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { model.searchNow() }
                    if !model.searchText.isEmpty {
                        Button("Clear") { model.clearSearch() }
                            .buttonStyle(.borderless)
                    }
                    Button {
                        model.searchNow()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Picker("Type", selection: $model.searchFilter) {
                    ForEach(JellyfinSearchCategory.allCases) { filter in
                        Text(filter.rawValue.capitalized).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                if model.searchBusy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching Jellyfin…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.isShowingSearchResults, let total = model.searchTotalRecordCount {
                    Text("\(model.searchResults.count) of \(total) results")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isSearchActive {
                Section(model.currentFolderName) {
                    if model.isShowingSearchResults {
                        if let error = model.searchError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                            Button("Retry search") { model.searchNow() }
                        } else if !model.searchBusy && model.searchResults.isEmpty {
                            Text("No matches")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = model.browseError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                        Button("Retry folder") { model.refreshCurrentLocation() }
                    } else if model.browseBusy && model.browseItems.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading folder…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if model.browseLoadedOnce && model.browseItems.isEmpty {
                        Text("This folder is empty")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.currentItems, id: \.id) { item in
                        JellyfinItemRow(item: item) {
                            model.openFolder(item)
                        } onPlay: {
                            play(item)
                        }
                    }

                    if model.isShowingSearchResults {
                        if let error = model.searchMoreError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if model.canLoadMoreSearch || model.searchMoreError != nil {
                            Button(model.searchMoreError == nil ? "Load more results" : "Retry loading results") {
                                model.loadMoreSearch()
                            }
                            .disabled(model.searchMoreBusy)
                        }
                        if model.searchStalledWithRemainingItems {
                            Text("Jellyfin returned no additional items. Refresh to try again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if let error = model.browseMoreError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if model.canLoadMoreBrowse || model.browseMoreError != nil {
                            Button(model.browseMoreError == nil ? "Load more" : "Retry loading more") {
                                model.loadMoreBrowse()
                            }
                            .disabled(model.browseMoreBusy)
                        }
                        if model.browseStalledWithRemainingItems {
                            Text("Jellyfin returned no additional items. Refresh to try again.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.searchMoreBusy || model.browseMoreBusy {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                feedSection(
                    title: "Continue Watching",
                    items: model.continueWatchingItems,
                    isLoading: model.continueWatchingBusy,
                    loadedOnce: model.continueWatchingLoadedOnce,
                    error: model.continueWatchingError,
                    retryTitle: "Retry Continue Watching",
                    retry: model.retryContinueWatching
                )
                feedSection(
                    title: "Next Up",
                    items: model.nextUpItems,
                    isLoading: model.nextUpBusy,
                    loadedOnce: model.nextUpLoadedOnce,
                    error: model.nextUpError,
                    retryTitle: "Retry Next Up",
                    retry: model.retryNextUp
                )
            }

            if model.playbackBusy {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing playback…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.playbackError {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    if model.canRetryPlayback {
                        Button("Reload versions") { model.retryPlayback() }
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
                HStack {
                    Button("Refresh") { model.refreshCurrentLocation() }
                        .disabled(model.searchBusy || model.browseBusy || model.connectBusy)
                    Spacer()
                    Text("Playback Destination controls where playable items open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.loadHomeIfNeeded() }
    }

    private func feedSection(
        title: String,
        items: [JellyfinItem],
        isLoading: Bool,
        loadedOnce: Bool,
        error: String?,
        retryTitle: String,
        retry: @escaping () -> Void
    ) -> some View {
        Section(title) {
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button(retryTitle, action: retry)
            }
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(items.isEmpty ? "Loading…" : "Refreshing…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if error == nil && loadedOnce && items.isEmpty {
                Text("Nothing here yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items, id: \.id) { item in
                JellyfinItemRow(item: item) {
                    model.openFolder(item)
                } onPlay: {
                    play(item)
                }
            }
        }
    }

    private func play(_ item: JellyfinItem) {
        model.play(item) { selection in
            player.openJellyfin(
                title: selection.item.name,
                subtitleTracks: selection.source.subtitleTracks,
                baseUrl: selection.base,
                token: selection.token,
                userId: selection.userId,
                itemId: selection.item.id,
                mediaSourceId: selection.source.id
            )
        }
    }

    private var versionPicker: some View {
        NavigationStack {
            List {
                if let choice = model.versionChoice {
                    ForEach(choice.sources.indices, id: \.self) { index in
                        let source = choice.sources[index]
                        Button {
                            model.chooseVersion(sourceId: source.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(versionTitle(source, index: index))
                                    .font(.headline)
                                if let details = versionDetails(source, disambiguate: isDuplicate(source, choice: choice)) {
                                    Text(details)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose version")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showVersionPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func versionTitle(_ source: JellyfinMediaSource, index: Int) -> String {
        nonEmpty(source.name) ?? "Version \(index + 1)"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isDuplicate(_ source: JellyfinMediaSource, choice: JellyfinVersionChoice) -> Bool {
        let title = nonEmpty(source.name)
        let details = versionDetails(source, disambiguate: false)
        return choice.sources.filter {
            nonEmpty($0.name) == title && versionDetails($0, disambiguate: false) == details
        }.count > 1
    }

    private func versionDetails(_ source: JellyfinMediaSource, disambiguate: Bool) -> String? {
        var details: [String] = []
        if let width = source.width?.intValue, let height = source.height?.intValue {
            details.append("\(width)×\(height)")
        }
        if let container = nonEmpty(source.container) { details.append(container.uppercased()) }
        let codecs = [nonEmpty(source.videoCodec), nonEmpty(source.audioCodec)].compactMap { $0?.uppercased() }
        if !codecs.isEmpty { details.append(codecs.joined(separator: " / ")) }
        if let channels = source.audioChannels?.intValue, channels > 0 { details.append("\(channels) ch") }
        if let size = source.sizeBytes?.int64Value, size > 0 {
            details.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if disambiguate { details.append("ID \(source.id)") }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

}

private struct JellyfinItemRow: View {
    let item: JellyfinItem
    let onOpenFolder: () -> Void
    let onPlay: () -> Void

    private var metadata: String? {
        var details: [String] = []
        let knownType = ["Movie", "Series", "Season", "Episode", "Video"].first {
            $0.caseInsensitiveCompare(item.type) == .orderedSame
        }
        if let knownType { details.append(knownType) }
        if item.type.caseInsensitiveCompare("Episode") == .orderedSame {
            if let series = item.seriesName, !series.isEmpty { details.append(series) }
            if let season = item.parentIndexNumber?.intValue, let episode = item.indexNumber?.intValue {
                details.append(String(format: "S%02dE%02d", season, episode))
            }
        }
        if let year = item.productionYear?.intValue, year > 0 { details.append(String(year)) }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isFolder ? "folder" : "film")
                .foregroundStyle(item.isFolder ? Color.rigelSteel : Color.rigelStar)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(2)
                if let metadata {
                    Text(metadata)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
