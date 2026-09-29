import SwiftUI
import ComposeApp

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

struct JellyfinPlaybackSelection {
    let item: JellyfinItem
    let source: JellyfinMediaSource
    let base: String
    let token: String
    let userId: String
}

struct JellyfinVersionChoice: Identifiable {
    let item: JellyfinItem
    let sources: [JellyfinMediaSource]
    var id: String { item.id }
}

enum JellyfinSearchCategory: String, CaseIterable, Identifiable {
    case all
    case movies
    case series
    case episodes

    var id: String { rawValue }

    var apiFilter: JellyfinSearchFilter {
        switch self {
        case .all: .all
        case .movies: .movies
        case .series: .series
        case .episodes: .episodes
        }
    }
}

/// Owns Jellyfin connection, paged browsing, search, and playback preparation.
@MainActor
final class JellyfinViewModel: ObservableObject {
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""

    @Published private(set) var connectBusy = false
    @Published private(set) var browseBusy = false
    @Published private(set) var browseMoreBusy = false
    @Published private(set) var searchBusy = false
    @Published private(set) var searchMoreBusy = false
    @Published private(set) var playbackBusy = false
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false
    @Published private(set) var playbackError: String?
    @Published private(set) var versionChoice: JellyfinVersionChoice?

    @Published private(set) var libraryItems: [JellyfinItem] = []
    @Published private(set) var browseItems: [JellyfinItem] = []
    @Published private(set) var libraryPath: [JellyfinItem] = []
    @Published private(set) var searchPath: [JellyfinItem] = []
    @Published private(set) var libraryLoadedOnce = false
    @Published private(set) var browseLoadedOnce = false
    @Published private(set) var libraryError: String?
    @Published private(set) var browseError: String?
    @Published private(set) var browseMoreError: String?
    @Published private(set) var browseStalled = false
    @Published private(set) var browseTotalRecordCount: Int32?

    @Published var searchText = "" { didSet { searchInputsChanged() } }
    @Published var searchFilter: JellyfinSearchCategory = .all { didSet { searchInputsChanged() } }
    @Published private(set) var searchResults: [JellyfinItem] = []
    @Published private(set) var searchTotalRecordCount: Int32?
    @Published private(set) var searchError: String?
    @Published private(set) var searchMoreError: String?
    @Published private(set) var searchStalled = false

    private var browseNextOffset: Int32 = 0
    private var browseLastReceivedCount: Int32 = 0
    private var searchNextOffset: Int32 = 0
    private var searchLastReceivedCount: Int32 = 0

    private var connectTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?

    private struct SearchInput: Equatable {
        let term: String
        let filter: JellyfinSearchCategory
    }
    private struct PlaybackLocation: Equatable {
        let isSearch: Bool
        let searchTerm: String?
        let searchFilter: JellyfinSearchCategory?
        let folderIds: [String]
    }

    private struct PendingPlaybackRequest {
        let id: UUID
        let item: JellyfinItem
        let base: String
        let token: String
        let userId: String
        let location: PlaybackLocation
        let open: (JellyfinPlaybackSelection) -> Bool
    }

    private struct PendingSourceChoice {
        let request: PendingPlaybackRequest
        let sources: [JellyfinMediaSource]
    }

    private var lastSearchInput: SearchInput?
    private var searchExecutionInput: SearchInput?
    private var searchRequestIssued = false
    private var suppressSearchInputChanges = false
    private var pendingPlaybackRequest: PendingPlaybackRequest?
    private var pendingSourceChoice: PendingSourceChoice?
    private let jellyfin: any JellyfinServing
    private let settings: JellyfinSettingsFacade
    private let searchDelay: (UInt64) async throws -> Void

    init(
        jellyfin: any JellyfinServing = RigelCore.shared.jellyfin,
        settings: JellyfinSettingsFacade? = nil,
        searchDelay: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.jellyfin = jellyfin
        self.settings = settings ?? DefaultJellyfinSettingsFacade(store: RigelCore.shared.settings)
        self.searchDelay = searchDelay
    }

    var connected: Bool { !settings.jellyfinToken().isEmpty }
    var base: String { settings.jellyfinServer() }
    private var token: String { settings.jellyfinToken() }
    private var userId: String { settings.jellyfinUserId() }
    var busy: Bool { connectBusy || browseBusy || browseMoreBusy || playbackBusy }
    var loadedOnce: Bool { libraryLoadedOnce }
    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canRetryPlayback: Bool { pendingPlaybackRequest != nil }
    var isShowingSearchResults: Bool { isSearchActive && searchPath.isEmpty }
    var currentItems: [JellyfinItem] {
        if !isSearchActive { return libraryItems }
        return searchPath.isEmpty ? searchResults : browseItems
    }
    var currentPath: [JellyfinItem] { isSearchActive ? searchPath : libraryPath }
    var currentFolderName: String { currentPath.last?.name ?? (isSearchActive ? "Search results" : "Library") }
    var currentPathNames: [String] { currentPath.map(\.name) }
    var parentId: String? { currentPath.last?.id }
    var parentName: String? { currentPath.last?.name }
    var searchPerformed: Bool { isSearchActive }
    var canLoadMoreLibrary: Bool {
        !isShowingSearchResults && !browseStalled && browseLoadedOnce &&
            (browseTotalRecordCount.map { browseNextOffset < $0 } ?? (browseLastReceivedCount >= 50))
    }
    var canLoadMoreSearch: Bool {
        isShowingSearchResults && !searchBusy && !searchMoreBusy && !searchStalled && !searchResults.isEmpty &&
            (searchTotalRecordCount.map { searchNextOffset < $0 } ?? (searchLastReceivedCount >= 50))
    }
    var searchStalledWithRemainingItems: Bool {
        searchStalled && (searchTotalRecordCount.map { searchNextOffset < $0 } ?? false)
    }
    var browseStalledWithRemainingItems: Bool {
        browseStalled && (browseTotalRecordCount.map { browseNextOffset < $0 } ?? false)
    }

    var displayServer: String {
        base.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
    var displayUsername: String { username.isEmpty ? settings.jellyfinUsername() : username }

    func prepareForm() {
        server = settings.jellyfinServer()
        username = settings.jellyfinUsername()
    }

    func connect() {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        invalidateInFlight()
        connectBusy = true
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
            connectBusy = false
            connectTask = nil
            guard let auth else {
                notice = "Authentication failed — check the server URL and credentials"
                noticeIsError = true
                return
            }

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
            suppressSearchInputChanges = true
            searchText = ""
            searchFilter = .all
            suppressSearchInputChanges = false
            lastSearchInput = nil
            resetSearchResults()
            libraryPath = []
            searchPath = []
            libraryItems = []
            browseItems = []
            libraryLoadedOnce = false
            browseLoadedOnce = false
            libraryError = nil
            browseError = nil
            notice = nil
            loadLibraryIfNeeded()
        }
    }

    func disconnect() {
        invalidateInFlight()
        connectBusy = false
        browseBusy = false
        browseMoreBusy = false
        searchBusy = false
        searchMoreBusy = false
        playbackBusy = false
        guard settings.setJellyfinToken(v: "") else {
            notice = "Unable to securely clear Jellyfin credentials"
            noticeIsError = true
            return
        }
        SwiftOutputSelection.shared.clearJellyfinServer(serverBase: settings.jellyfinServer())
        password = ""
        suppressSearchInputChanges = true
        searchText = ""
        searchFilter = .all
        suppressSearchInputChanges = false
        lastSearchInput = nil
        libraryItems = []
        browseItems = []
        libraryPath = []
        searchPath = []
        libraryLoadedOnce = false
        browseLoadedOnce = false
        libraryError = nil
        browseError = nil
        browseMoreError = nil
        resetSearchResults()
        notice = nil
        noticeIsError = false
    }

    func loadLibraryIfNeeded() {
        guard connected, !libraryLoadedOnce, !browseBusy else { return }
        loadBrowsePage()
    }

    func refreshLibrary() {
        guard connected else { return }
        loadBrowsePage(reset: true)
    }

    func loadMoreLibrary() {
        guard canLoadMoreLibrary, !browseMoreBusy else { return }
        loadBrowsePage(append: true)
    }

    func refreshCurrentLocation() {
        if isShowingSearchResults {
            searchNow()
        } else {
            loadBrowsePage(reset: true)
        }
    }

    func openFolder(_ item: JellyfinItem) {
        guard item.isFolder, connected else { return }
        invalidatePendingPlayback()
        if isSearchActive {
            searchTask?.cancel()
            searchTask = nil
            searchBusy = false
            searchMoreBusy = false
            searchRequestIssued = false
            searchExecutionInput = nil
            searchPath.append(item)
        } else {
            libraryPath.append(item)
        }
        browseLoadedOnce = false
        loadBrowsePage(reset: true)
    }

    func goBack() {
        guard !currentPath.isEmpty else { return }
        invalidatePendingPlayback()
        if isSearchActive {
            if searchPath.count == 1 {
                searchPath = []
                browseTask?.cancel()
                browseTask = nil
                browseBusy = false
                browseMoreBusy = false
                browseLoadedOnce = false
                browseItems = []
                browseError = nil
                return
            }
            searchPath.removeLast()
        } else {
            libraryPath.removeLast()
        }
        browseLoadedOnce = false
        loadBrowsePage(reset: true)
    }

    func backToRoot() {
        guard !currentPath.isEmpty else { return }
        invalidatePendingPlayback()
        if isSearchActive {
            searchPath = []
            browseTask?.cancel()
            browseTask = nil
            browseBusy = false
            browseMoreBusy = false
            browseLoadedOnce = false
            browseItems = []
            browseError = nil
            return
        }
        libraryPath = []
        refreshLibrary()
    }

    func clearSearch() {
        searchText = ""
        if lastSearchInput == nil { resetSearchResults() }
    }

    func searchNow() {
        guard let input = currentSearchInput, connected else { return }
        if searchExecutionInput == input && searchRequestIssued && (searchBusy || searchMoreBusy) { return }
        startSearchPage(input, startIndex: 0, append: false, debounce: false)
    }

    func loadMoreSearch() {
        guard canLoadMoreSearch else { return }
        guard let input = currentSearchInput else { return }
        startSearchPage(input, startIndex: searchNextOffset, append: true, debounce: false)
    }

    private var currentSearchInput: SearchInput? {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? nil : SearchInput(term: term, filter: searchFilter)
    }

    private func searchInputsChanged() {
        guard !suppressSearchInputChanges else { return }
        let input = currentSearchInput
        guard input != lastSearchInput else { return }
        let wasSearching = lastSearchInput != nil
        lastSearchInput = input
        invalidatePendingPlayback()
        searchTask?.cancel()
        searchTask = nil
        searchBusy = false
        searchMoreBusy = false
        searchRequestIssued = false
        searchExecutionInput = nil
        searchPath = []
        searchError = nil
        searchMoreError = nil
        searchStalled = false
        searchResults = []
        searchNextOffset = 0
        searchLastReceivedCount = 0
        searchTotalRecordCount = nil

        if let input {
            browseTask?.cancel()
            browseTask = nil
            browseBusy = false
            browseMoreBusy = false
            browseLoadedOnce = false
            browseItems = []
            browseError = nil
            browseMoreError = nil
            browseStalled = false
            searchBusy = true
            startSearchPage(input, startIndex: 0, append: false, debounce: true)
        } else if wasSearching && connected {
            browseTask?.cancel()
            browseTask = nil
            browseBusy = false
            browseMoreBusy = false
            libraryItems = []
            libraryLoadedOnce = false
            browseLoadedOnce = false
            browseError = nil
            loadBrowsePage(reset: true)
        }
    }

    private func startSearchPage(_ input: SearchInput, startIndex: Int32, append: Bool, debounce: Bool) {
        guard connected else { return }
        searchTask?.cancel()
        searchTask = nil
        searchExecutionInput = input
        searchRequestIssued = !debounce
        if append {
            searchMoreBusy = true
            searchMoreError = nil
        } else {
            searchBusy = true
            searchError = nil
            searchMoreError = nil
            searchResults = []
            searchTotalRecordCount = nil
            searchNextOffset = 0
            searchLastReceivedCount = 0
            searchStalled = false
        }
        let requestBase = base
        let requestToken = token
        let requestUserId = userId
        searchTask = Task {
            do {
                if debounce {
                    try await searchDelay(300_000_000)
                    guard !Task.isCancelled, currentSearchInput == input, searchPath.isEmpty else { return }
                    searchRequestIssued = true
                }
                let page = try await jellyfin.searchAsync(
                    base: requestBase,
                    token: requestToken,
                    userId: requestUserId,
                    term: input.term,
                    filter: input.filter.apiFilter,
                    startIndex: startIndex,
                    limit: 50
                )
                guard !Task.isCancelled, currentSearchInput == input, searchPath.isEmpty else { return }
                let merged = Self.merge(page.items, into: append ? searchResults : [])
                searchResults = merged.items
                searchNextOffset = Self.nextOffset(startIndex, page.receivedCount)
                searchLastReceivedCount = page.receivedCount
                searchTotalRecordCount = page.totalRecordCount?.int32Value
                searchStalled = page.receivedCount == 0 || (append && merged.addedCount == 0)
                searchBusy = false
                searchMoreBusy = false
                searchRequestIssued = false
                searchExecutionInput = nil
                searchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !JellyfinCancellation.isCancellation(error),
                      currentSearchInput == input,
                      isCurrentAccount(base: requestBase, token: requestToken, userId: requestUserId)
                else { return }
                if JellyfinCancellation.httpStatusCode(error) == 401 {
                    expireSession(base: requestBase, token: requestToken, userId: requestUserId)
                    return
                }
                searchBusy = false
                searchMoreBusy = false
                searchRequestIssued = false
                searchExecutionInput = nil
                searchTask = nil
                if append {
                    searchMoreError = Self.safeErrorMessage(error)
                } else {
                    searchError = Self.safeErrorMessage(error)
                }
            }
        }
    }

    private struct BrowseTarget: Equatable {
        let isSearchFolder: Bool
        let parentId: String?
    }

    private var activeBrowseTarget: BrowseTarget {
        BrowseTarget(isSearchFolder: isSearchActive && !searchPath.isEmpty, parentId: currentPath.last?.id)
    }

    private var activeBrowseOrder: JellyfinBrowseOrder {
        let parentType = currentPath.last?.type.lowercased()
        return parentType == "series" || parentType == "season" ? .episode : .name
    }

    private func loadBrowsePage(append: Bool = false, reset: Bool = false) {
        guard connected else { return }
        let target = activeBrowseTarget
        let parentId = target.parentId
        let order = activeBrowseOrder
        let startIndex = append ? browseNextOffset : 0
        if reset || !append {
            browseTask?.cancel()
            browseItems = target.isSearchFolder ? [] : browseItems
            if !target.isSearchFolder { libraryItems = [] }
            browseLoadedOnce = false
            browseNextOffset = 0
            browseLastReceivedCount = 0
            browseTotalRecordCount = nil
            browseStalled = false
            browseError = nil
            browseMoreError = nil
        }
        browseTask?.cancel()
        browseMoreBusy = append
        browseBusy = !append
        if append { browseMoreError = nil } else { browseError = nil }
        let requestBase = base
        let requestToken = token
        let requestUserId = userId
        browseTask = Task {
            do {
                let page = try await jellyfin.browseAsync(
                    base: requestBase,
                    token: requestToken,
                    userId: requestUserId,
                    parentId: parentId,
                    startIndex: startIndex,
                    limit: 50,
                    order: order
                )
                guard !Task.isCancelled, target == activeBrowseTarget else { return }
                let existing = target.isSearchFolder ? browseItems : libraryItems
                let merged = Self.merge(page.items, into: append ? existing : [])
                if target.isSearchFolder {
                    browseItems = merged.items
                    browseError = nil
                } else {
                    libraryItems = merged.items
                    libraryLoadedOnce = true
                    libraryError = nil
                }
                browseNextOffset = Self.nextOffset(startIndex, page.receivedCount)
                browseLastReceivedCount = page.receivedCount
                browseTotalRecordCount = page.totalRecordCount?.int32Value
                    ?? (append ? browseTotalRecordCount : nil)
                browseStalled = page.receivedCount == 0 || (append && merged.addedCount == 0)
                browseLoadedOnce = true
                browseBusy = false
                browseMoreBusy = false
                browseTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !JellyfinCancellation.isCancellation(error),
                      target == activeBrowseTarget,
                      isCurrentAccount(base: requestBase, token: requestToken, userId: requestUserId)
                else { return }
                if JellyfinCancellation.httpStatusCode(error) == 401 {
                    expireSession(base: requestBase, token: requestToken, userId: requestUserId)
                    return
                }
                browseBusy = false
                browseMoreBusy = false
                browseTask = nil
                if append {
                    browseMoreError = Self.safeErrorMessage(error)
                } else if target.isSearchFolder {
                    browseError = Self.safeErrorMessage(error)
                } else {
                    libraryLoadedOnce = true
                    libraryError = Self.safeErrorMessage(error)
                }
            }
        }
    }

    private func resetSearchResults() {
        searchResults = []
        searchNextOffset = 0
        searchLastReceivedCount = 0
        searchTotalRecordCount = nil
        searchError = nil
        searchMoreError = nil
        searchStalled = false
        searchBusy = false
        searchMoreBusy = false
    }

    private static func merge(_ incoming: [JellyfinItem], into existing: [JellyfinItem]) -> (items: [JellyfinItem], addedCount: Int) {
        var seen = Set(existing.map(\.id))
        let unique = incoming.filter { seen.insert($0.id).inserted }
        return (existing + unique, unique.count)
    }

    private static func nextOffset(_ start: Int32, _ received: Int32) -> Int32 {
        Int32(min(Int64(Int32.max), Int64(start) + Int64(received)))
    }

    func play(_ item: JellyfinItem, open: @escaping (JellyfinPlaybackSelection) -> Bool) {
        guard connected, !token.isEmpty, !userId.isEmpty, !base.isEmpty else { return }
        invalidatePendingPlayback()
        let request = PendingPlaybackRequest(
            id: UUID(),
            item: item,
            base: base,
            token: token,
            userId: userId,
            location: currentPlaybackLocation,
            open: open
        )
        pendingPlaybackRequest = request
        loadMediaSources(for: request)
    }

    func retryPlayback() {
        guard let request = pendingPlaybackRequest else { return }
        guard isCurrent(request) else {
            invalidatePendingPlayback()
            playbackError = "This version is no longer available. Reload versions and try again."
            return
        }
        pendingSourceChoice = nil
        versionChoice = nil
        loadMediaSources(for: request)
    }

    func chooseVersion(sourceId: String) {
        guard let pending = pendingSourceChoice else {
            playbackError = "This version is no longer available. Reload versions and try again."
            return
        }
        guard isCurrent(pending.request) else {
            invalidatePendingPlayback()
            playbackError = "This version is no longer available. Reload versions and try again."
            return
        }
        guard let source = pending.sources.first(where: { $0.id == sourceId }) else {
            pendingSourceChoice = nil
            versionChoice = nil
            playbackError = "This version is no longer available. Reload versions and try again."
            return
        }
        pendingSourceChoice = nil
        pendingPlaybackRequest = nil
        versionChoice = nil
        playbackError = nil
        if !pending.request.open(
            JellyfinPlaybackSelection(
                item: pending.request.item,
                source: source,
                base: pending.request.base,
                token: pending.request.token,
                userId: pending.request.userId
            )
        ) {
            playbackError = "Unable to open this Jellyfin item."
        }
    }

    func dismissVersionChoice() {
        guard pendingSourceChoice != nil else { return }
        invalidatePendingPlayback()
    }

    private var currentPlaybackLocation: PlaybackLocation {
        let search = currentSearchInput
        return PlaybackLocation(
            isSearch: isSearchActive,
            searchTerm: search?.term,
            searchFilter: search?.filter,
            folderIds: currentPath.map(\.id)
        )
    }

    private func isCurrent(_ request: PendingPlaybackRequest) -> Bool {
        connected && base == request.base && token == request.token && userId == request.userId &&
            currentPlaybackLocation == request.location && pendingPlaybackRequest?.id == request.id
    }

    private func loadMediaSources(for request: PendingPlaybackRequest) {
        guard isCurrent(request) else { return }
        playbackTask?.cancel()
        playbackBusy = true
        playbackError = nil
        playbackTask = Task {
            do {
                let sources = try await jellyfin.itemMediaSourcesAsync(
                    base: request.base,
                    token: request.token,
                    userId: request.userId,
                    itemId: request.item.id
                )
                guard !Task.isCancelled else { return }
                guard isCurrent(request) else {
                    invalidatePendingPlayback()
                    playbackError = "This version is no longer available. Reload versions and try again."
                    return
                }
                playbackBusy = false
                playbackTask = nil
                guard !sources.isEmpty else {
                    playbackError = "No playable versions are available for this item."
                    return
                }
                if sources.count == 1 {
                    pendingPlaybackRequest = nil
                    if !request.open(
                        JellyfinPlaybackSelection(
                            item: request.item,
                            source: sources[0],
                            base: request.base,
                            token: request.token,
                            userId: request.userId
                        )
                    ) {
                        playbackError = "Unable to open this Jellyfin item."
                    }
                    return
                }
                pendingSourceChoice = PendingSourceChoice(request: request, sources: sources)
                versionChoice = JellyfinVersionChoice(item: request.item, sources: sources)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !JellyfinCancellation.isCancellation(error), isCurrent(request) else { return }
                if JellyfinCancellation.httpStatusCode(error) == 401 {
                    expireSession(base: request.base, token: request.token, userId: request.userId)
                    return
                }
                playbackBusy = false
                playbackTask = nil
                playbackError = Self.safeErrorMessage(error)
            }
        }
    }

    private func invalidatePendingPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackBusy = false
        pendingPlaybackRequest = nil
        pendingSourceChoice = nil
        versionChoice = nil
        playbackError = nil
    }

    private func invalidateInFlight() {
        connectTask?.cancel()

        browseTask?.cancel()
        searchTask?.cancel()
        connectTask = nil
        browseTask = nil
        searchTask = nil
        connectBusy = false
        browseBusy = false
        browseMoreBusy = false
        searchBusy = false
        searchMoreBusy = false
        searchRequestIssued = false
        searchExecutionInput = nil
        invalidatePendingPlayback()
    }

    private func isCurrentAccount(base: String, token: String, userId: String) -> Bool {
        connected && self.base == base && self.token == token && self.userId == userId
    }

    private func expireSession(base: String, token: String, userId: String) {
        guard isCurrentAccount(base: base, token: token, userId: userId) else { return }
        guard settings.setJellyfinToken(v: "") else {
            invalidateInFlight()
            notice = "Unable to securely clear Jellyfin credentials"
            noticeIsError = true
            return
        }
        SwiftOutputSelection.shared.clearJellyfinServer(serverBase: base)
        invalidateInFlight()
        password = ""
        suppressSearchInputChanges = true
        searchText = ""
        searchFilter = .all
        suppressSearchInputChanges = false
        lastSearchInput = nil
        libraryItems = []
        browseItems = []
        libraryPath = []
        searchPath = []
        libraryLoadedOnce = false
        browseLoadedOnce = false
        libraryError = nil
        browseError = nil
        browseMoreError = nil
        resetSearchResults()
        notice = "Session expired. Sign in again."
        noticeIsError = true
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let statusCode = JellyfinCancellation.httpStatusCode(error) {
            if statusCode == 403 { return "You do not have permission to access this item." }
            return "Jellyfin request failed (" + String(statusCode) + ")"
        }
        return "Could not load Jellyfin data. Try again."
    }
}
