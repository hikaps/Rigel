import Foundation
import XCTest
import ComposeApp
@testable import Rigel

@MainActor
private final class InMemoryJellyfinSettingsFacade: JellyfinSettingsFacade {
    var server = ""
    var token = ""
    var userId = ""
    var username = ""
    var tokenWriteSucceeds = true

    func jellyfinServer() -> String { server }
    func setJellyfinServer(v: String) { server = v }
    func jellyfinToken() -> String { token }
    func setJellyfinToken(v: String) -> Bool {
        guard tokenWriteSucceeds else { return false }
        token = v
        return true
    }
    func jellyfinUserId() -> String { userId }
    func setJellyfinUserId(v: String) { userId = v }
    func jellyfinUsername() -> String { username }
    func setJellyfinUsername(v: String) { username = v }
}
@MainActor
private final class ControlledJellyfin: JellyfinServing {
    struct SearchRequest {
        let term: String
        let filter: JellyfinSearchFilter
        let startIndex: Int32
        let limit: Int32
    }

    private(set) var searchRequests: [SearchRequest] = []
    private(set) var browseRequests: [(parentId: String?, startIndex: Int32, order: JellyfinBrowseOrder)] = []
    var browsePages: [String: JellyfinItemPage] = [:]
    var browseError: Error?
    var deferBrowse = false
    private var pendingBrowses: [Int: CheckedContinuation<JellyfinItemPage, Error>] = [:]
    private var pendingSearches: [Int: CheckedContinuation<JellyfinItemPage, Error>] = [:]
    private(set) var mediaSourceRequests: [String] = []
    private var pendingMediaSources: [String: CheckedContinuation<[JellyfinMediaSource], Error>] = [:]
    private var pendingAuthentication: [String: CheckedContinuation<JellyfinAuth?, Never>] = [:]
    private var authenticationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var authenticationError: Error?
    var authenticationPending: Bool { !pendingAuthentication.isEmpty }
    func authenticateAsync(base: String, username: String, password: String, deviceId: String) async throws -> JellyfinAuth? {
        if let error = authenticationError {
            authenticationError = nil
            throw error
        }
        return await withCheckedContinuation { continuation in
            pendingAuthentication[base] = continuation
            let waiters = authenticationWaiters.removeValue(forKey: base) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    func browseAsync(
        base: String,
        token: String,
        userId: String,
        parentId: String?,
        startIndex: Int32,
        limit: Int32,
        order: JellyfinBrowseOrder
    ) async throws -> JellyfinItemPage {
        let requestId = browseRequests.count
        browseRequests.append((parentId, startIndex, order))
        if deferBrowse {
            return try await withCheckedThrowingContinuation { pendingBrowses[requestId] = $0 }
        }
        if let browseError { throw browseError }
        return browsePages[parentId ?? "<root>"] ?? JellyfinItemPage(
            items: [], totalRecordCount: nil, startIndex: startIndex, receivedCount: 0
        )
    }

    func searchAsync(
        base: String,
        token: String,
        userId: String,
        term: String,
        filter: JellyfinSearchFilter,
        startIndex: Int32,
        limit: Int32
    ) async throws -> JellyfinItemPage {
        let requestId = searchRequests.count
        searchRequests.append(SearchRequest(term: term, filter: filter, startIndex: startIndex, limit: limit))
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JellyfinItemPage, Error>) in
            pendingSearches[requestId] = continuation
        }
    }
    func itemMediaSourcesAsync(base: String, token: String, userId: String, itemId: String) async throws -> [JellyfinMediaSource] {
        mediaSourceRequests.append(itemId)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[JellyfinMediaSource], Error>) in
            pendingMediaSources[itemId] = continuation
        }
    }

    func resolveSearch(term: String, filter: JellyfinSearchFilter = .all, startIndex: Int32, page: JellyfinItemPage) {
        guard let requestId = searchRequests.lastIndex(where: { $0.term == term && $0.filter == filter && $0.startIndex == startIndex }) else { return }
        pendingSearches.removeValue(forKey: requestId)?.resume(returning: page)
    }

    func failSearch(term: String, filter: JellyfinSearchFilter = .all, startIndex: Int32, error: Error = CancellationError()) {
        guard let requestId = searchRequests.lastIndex(where: { $0.term == term && $0.filter == filter && $0.startIndex == startIndex }) else { return }
        pendingSearches.removeValue(forKey: requestId)?.resume(throwing: error)
    }
    func resolveMediaSources(itemId: String, sources: [JellyfinMediaSource]) {
        pendingMediaSources.removeValue(forKey: itemId)?.resume(returning: sources)
    }

    func resolveBrowse(requestId: Int, result: Result<JellyfinItemPage, Error>) {
        pendingBrowses.removeValue(forKey: requestId)?.resume(with: result)
    }

    func failMediaSources(itemId: String, error: Error = CancellationError()) {
        pendingMediaSources.removeValue(forKey: itemId)?.resume(throwing: error)
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

    func resolveAuthentication(_ auth: JellyfinAuth?) {
        guard let base = pendingAuthentication.keys.first else { return }
        resolveAuthentication(base: base, with: auth)
    }

    func cancelPending() {
        for continuation in pendingBrowses.values {
            continuation.resume(throwing: CancellationError())
        }
        pendingBrowses.removeAll()
        for continuation in pendingSearches.values {
            continuation.resume(throwing: CancellationError())
        }
        pendingSearches.removeAll()
        for continuation in pendingMediaSources.values {
            continuation.resume(throwing: CancellationError())
        }
        pendingMediaSources.removeAll()
        for continuation in pendingAuthentication.values {
            continuation.resume(returning: nil)
        }
        pendingAuthentication.removeAll()
    }
}

@MainActor
private final class SearchDelayGate {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    var count: Int { waiters.count }

    func wait(_ nanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

@MainActor
final class JellyfinViewModelTests: XCTestCase {
    private struct SavedSettings {
        let server: String
        let username: String
        let token: String
        let userId: String
    }

    private func connectedModel(
        _ service: ControlledJellyfin,
        searchDelay: @escaping (UInt64) async throws -> Void = { _ in }
    ) -> (JellyfinViewModel, InMemoryJellyfinSettingsFacade, SavedSettings, any PlaybackDestination) {
        let settings = InMemoryJellyfinSettingsFacade()
        let saved = SavedSettings(
            server: settings.jellyfinServer(),
            username: settings.jellyfinUsername(),
            token: settings.jellyfinToken(),
            userId: settings.jellyfinUserId()
        )
        let destination = SwiftOutputSelection.shared.snapshot().destination
        settings.setJellyfinServer(v: "http://jellyfin-test.invalid")
        settings.setJellyfinUsername(v: "test-user")
        settings.setJellyfinToken(v: "test-token")
        settings.setJellyfinUserId(v: "test-user-id")
        let model = JellyfinViewModel(jellyfin: service, settings: settings, searchDelay: searchDelay)
        return (model, settings, saved, destination)
    }

    private func restore(
        model: JellyfinViewModel,
        service: ControlledJellyfin,
        settings: InMemoryJellyfinSettingsFacade,
        saved: SavedSettings,
        destination: any PlaybackDestination
    ) {
        settings.tokenWriteSucceeds = true
        model.disconnect()
        service.cancelPending()
        settings.setJellyfinServer(v: saved.server)
        settings.setJellyfinUsername(v: saved.username)
        settings.setJellyfinToken(v: saved.token)
        settings.setJellyfinUserId(v: saved.userId)
        if destination is PlaybackDestinationLocal {
            SwiftOutputSelection.shared.selectLocal()
        } else if let airPlay = destination as? PlaybackDestinationAirPlay {
            SwiftOutputSelection.shared.selectAirPlay(routeId: airPlay.routeId, name: airPlay.name)
        } else if let receiver = destination as? PlaybackDestinationReceiver {
            SwiftOutputSelection.shared.selectReceiver(target: receiver.target)
        }
    }

    private func item(_ id: String, _ name: String, folder: Bool = false, type: String = "Movie") -> JellyfinItem {
        JellyfinItem(
            id: id,
            name: name,
            isFolder: folder,
            type: type,
            productionYear: nil,
            seriesName: nil,
            parentIndexNumber: nil,
            indexNumber: nil
        )
    }
    private func mediaSource(_ id: String, name: String, subtitles: [SubtitleTrack] = []) -> JellyfinMediaSource {
        JellyfinMediaSource(
            id: id,
            name: name,
            container: "mkv",
            width: nil,
            height: nil,
            videoCodec: nil,
            audioCodec: nil,
            audioChannels: nil,
            sizeBytes: nil,
            subtitleTracks: subtitles
        )
    }

    private func page(_ items: [JellyfinItem], total: Int32?, start: Int32, received: Int32) -> JellyfinItemPage {
        JellyfinItemPage(items: items, totalRecordCount: total.map { KotlinInt(int: $0) }, startIndex: start, receivedCount: received)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
    }

    func testDisconnectResetsActivityFlagsWhileRequestsAreInFlight() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.server = "https://pending.example"
        model.username = "new-user"
        model.connect()
        await service.waitForAuthentication(base: "https://pending.example")

        model.searchText = "star"
        await waitUntil { service.searchRequests.count == 1 }
        model.play(item("movie", "Film")) { _ in true }
        await waitUntil { service.mediaSourceRequests == ["movie"] }
        XCTAssertTrue(model.connectBusy)
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.searchBusy)

        model.disconnect()

        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.connectBusy)
        XCTAssertFalse(model.searchBusy)
        XCTAssertFalse(model.searchMoreBusy)
        XCTAssertFalse(model.playbackBusy)
        service.cancelPending()
    }

    func testConnectReportsSecureTokenWriteFailure() async {
        let service = ControlledJellyfin()
        let settings = InMemoryJellyfinSettingsFacade()
        let model = JellyfinViewModel(jellyfin: service, settings: settings)
        defer {
            settings.tokenWriteSucceeds = true
            model.disconnect()
            service.cancelPending()
        }
        settings.tokenWriteSucceeds = false
        model.server = "https://jellyfin.example"
        model.username = "alice"
        model.password = "secret"
        model.connect()
        await service.waitForAuthentication(base: "https://jellyfin.example")
        service.resolveAuthentication(
            base: "https://jellyfin.example",
            with: JellyfinAuth(token: "new-token", userId: "user")
        )
        await waitUntil { model.notice == "Unable to securely store Jellyfin credentials" }

        XCTAssertFalse(model.connected)
        XCTAssertEqual(settings.jellyfinToken(), "")
        XCTAssertEqual(settings.jellyfinServer(), "")
        XCTAssertTrue(model.noticeIsError)
    }

    func testDisconnectKeepsSessionWhenSecureTokenClearFails() {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
        settings.tokenWriteSucceeds = false

        model.disconnect()

        XCTAssertTrue(model.connected)
        XCTAssertEqual(settings.jellyfinToken(), "test-token")
        XCTAssertEqual(model.notice, "Unable to securely clear Jellyfin credentials")
        XCTAssertTrue(model.noticeIsError)
    }

    func testExpiredSessionRemainsVisibleWhenSecureTokenClearFails() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
        settings.tokenWriteSucceeds = false

        model.searchText = "expired"
        await waitUntil { service.searchRequests.count == 1 }
        service.failSearch(
            term: "expired",
            startIndex: 0,
            error: JellyfinInterop.shared.makeRequestException(statusCode: 401).asError()
        )
        await waitUntil { model.notice == "Unable to securely clear Jellyfin credentials" }

        XCTAssertTrue(model.connected)
        XCTAssertEqual(settings.jellyfinToken(), "test-token")
        XCTAssertFalse(model.searchBusy)
        XCTAssertTrue(model.noticeIsError)
    }

    func testLiveSearchKeepsOnlyNewestQueryAfterOutOfOrderResponses() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "older query"
        await waitUntil { service.searchRequests.contains { $0.term == "older query" } }
        model.searchText = "newer query"
        await waitUntil { service.searchRequests.contains { $0.term == "newer query" } }

        service.resolveSearch(term: "newer query", startIndex: 0, page: page([item("new", "New result")], total: 1, start: 0, received: 1))
        await waitUntil { model.searchResults.map(\.id) == ["new"] }
        service.resolveSearch(term: "older query", startIndex: 0, page: page([item("old", "Old result")], total: 1, start: 0, received: 1))
        await waitUntil { service.searchRequests.count == 2 }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(model.searchResults.map(\.id), ["new"])
    }

    func testChangingFilterForSameInFlightTermKeepsOnlyNewFilterResults() async {
        let service = ControlledJellyfin()
        let gate = SearchDelayGate()
        let (model, settings, saved, destination) = connectedModel(service) { delay in try await gate.wait(delay) }
        defer {
            gate.releaseAll()
            restore(model: model, service: service, settings: settings, saved: saved, destination: destination)
        }

        model.searchText = "same term"
        await waitUntil { gate.count == 1 }
        gate.releaseAll()
        await waitUntil { service.searchRequests.count == 1 }
        XCTAssertEqual(service.searchRequests[0].filter, .all)

        model.searchFilter = .movies
        await waitUntil { gate.count == 1 }
        gate.releaseAll()
        await waitUntil { service.searchRequests.count == 2 }
        XCTAssertEqual(service.searchRequests[1].filter, .movies)

        service.resolveSearch(term: "same term", filter: .movies, startIndex: 0, page: page([item("movie", "Movie")], total: 1, start: 0, received: 1))
        await waitUntil { model.searchResults.map(\.id) == ["movie"] }
        service.resolveSearch(term: "same term", filter: .all, startIndex: 0, page: page([item("stale", "Stale")], total: 1, start: 0, received: 1))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(model.searchFilter, .movies)
        XCTAssertEqual(model.searchResults.map(\.id), ["movie"])
    }
    func testFilteredSearchAppendsPagesWithoutLosingResults() async {
        var delays: [UInt64] = []
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service) { delay in delays.append(delay) }
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchFilter = .movies
        model.searchText = "Amélie & friends"
        await waitUntil { service.searchRequests.count == 1 }
        XCTAssertEqual(delays, [300_000_000])
        XCTAssertEqual(service.searchRequests[0].term, "Amélie & friends")
        XCTAssertEqual(service.searchRequests[0].filter, .movies)
        XCTAssertEqual(service.searchRequests[0].startIndex, 0)
        XCTAssertEqual(service.searchRequests[0].limit, 50)

        service.resolveSearch(term: "Amélie & friends", filter: .movies, startIndex: 0, page: page([item("one", "First")], total: 100, start: 0, received: 50))
        await waitUntil { model.searchResults.count == 1 }
        model.loadMoreSearch()
        await waitUntil { service.searchRequests.count == 2 }
        XCTAssertEqual(service.searchRequests[1].startIndex, 50)
        service.resolveSearch(term: "Amélie & friends", filter: .movies, startIndex: 50, page: page([item("two", "Second")], total: 100, start: 50, received: 50))
        await waitUntil { model.searchResults.count == 2 }

        XCTAssertEqual(model.searchResults.map(\.id), ["one", "two"])
    }

    func testSearchCanPagePastAnEmptyMappedFirstPage() async {
        for total: Int32? in [51, nil] {
            let service = ControlledJellyfin()
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
            model.searchText = "skipped entries"
            await waitUntil { service.searchRequests.count == 1 }
            XCTAssertFalse(model.canLoadMoreSearch)
            service.resolveSearch(term: "skipped entries", startIndex: 0, page: page([], total: total, start: 0, received: 50))
            await waitUntil { !model.searchBusy }
            XCTAssertTrue(model.searchResults.isEmpty)
            XCTAssertTrue(model.canLoadMoreSearch)
            model.loadMoreSearch()
            await waitUntil { service.searchRequests.count == 2 }
            XCTAssertEqual(service.searchRequests.last?.startIndex, 50)
            service.resolveSearch(term: "skipped entries", startIndex: 50, page: page([item("valid", "Valid result")], total: total, start: 50, received: 1))
            await waitUntil { !model.searchMoreBusy }
            XCTAssertEqual(model.searchResults.map(\.id), ["valid"])
            XCTAssertFalse(model.canLoadMoreSearch)
        }
    }

    func testSearchContinuesPastEmptyIntermediatePagesAndStopsNonProgress() async {
        for duplicate in [false, true] {
            let service = ControlledJellyfin()
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
            model.searchText = "intermediate"
            await waitUntil { service.searchRequests.count == 1 }
            service.resolveSearch(term: "intermediate", startIndex: 0, page: page([item("first", "First")], total: 151, start: 0, received: 50))
            await waitUntil { !model.searchBusy }
            model.loadMoreSearch()
            await waitUntil { service.searchRequests.count == 2 }
            service.resolveSearch(term: "intermediate", startIndex: 50, page: page([], total: 151, start: 50, received: 50))
            await waitUntil { !model.searchMoreBusy }
            XCTAssertTrue(model.canLoadMoreSearch)
            XCTAssertFalse(model.searchStalled)
            XCTAssertEqual(model.searchResults.map(\.id), ["first"])
            model.loadMoreSearch()
            await waitUntil { service.searchRequests.count == 3 }
            XCTAssertEqual(service.searchRequests.last?.startIndex, 100)
            service.resolveSearch(term: "intermediate", startIndex: 100, page: page([item("later", "Later")], total: 151, start: 100, received: 1))
            await waitUntil { !model.searchMoreBusy }
            XCTAssertEqual(model.searchResults.map(\.id), ["first", "later"])
            model.loadMoreSearch()
            await waitUntil { service.searchRequests.count == 4 }
            service.resolveSearch(term: "intermediate", startIndex: 101, page: page(duplicate ? [item("later", "Repeated")] : [], total: 151, start: 101, received: duplicate ? 50 : 0))
            await waitUntil { !model.searchMoreBusy }
            XCTAssertTrue(model.searchStalled)
            XCTAssertFalse(model.canLoadMoreSearch)
            XCTAssertEqual(model.searchResults.map(\.id), ["first", "later"])
        }
    }

    func testBrowseContinuesPastEmptyIntermediatePagesAndStopsNonProgress() async {
        for duplicate in [false, true] {
            let service = ControlledJellyfin()
            service.deferBrowse = true
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
            model.loadLibraryIfNeeded()
            await waitUntil { service.browseRequests.count == 1 }
            service.resolveBrowse(requestId: 0, result: .success(page([item("first", "First")], total: 151, start: 0, received: 50)))
            await waitUntil { !model.browseBusy }
            model.loadMoreLibrary()
            await waitUntil { service.browseRequests.count == 2 }
            service.resolveBrowse(requestId: 1, result: .success(page([], total: 151, start: 50, received: 50)))
            await waitUntil { !model.browseMoreBusy }
            XCTAssertTrue(model.canLoadMoreLibrary)
            XCTAssertFalse(model.browseStalled)
            XCTAssertEqual(model.libraryItems.map(\.id), ["first"])
            model.loadMoreLibrary()
            await waitUntil { service.browseRequests.count == 3 }
            XCTAssertEqual(service.browseRequests.last?.startIndex, 100)
            service.resolveBrowse(requestId: 2, result: .success(page([item("later", "Later")], total: 151, start: 100, received: 1)))
            await waitUntil { !model.browseMoreBusy }
            XCTAssertEqual(model.libraryItems.map(\.id), ["first", "later"])
            model.loadMoreLibrary()
            await waitUntil { service.browseRequests.count == 4 }
            service.resolveBrowse(requestId: 3, result: .success(page(duplicate ? [item("later", "Repeated")] : [], total: 151, start: 101, received: duplicate ? 50 : 0)))
            await waitUntil { !model.browseMoreBusy }
            XCTAssertTrue(model.browseStalled)
            XCTAssertFalse(model.canLoadMoreLibrary)
            XCTAssertEqual(model.libraryItems.map(\.id), ["first", "later"])
        }
    }


    func testSearchPaginationRestartsForReplacementAccount() async {
        for pendingMore in [false, true] {
            let service = ControlledJellyfin()
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
            model.searchText = "shared query"
            await waitUntil { service.searchRequests.count == 1 }
            service.resolveSearch(term: "shared query", startIndex: 0, page: page([item("old", "Old account")], total: 100, start: 0, received: 50))
            await waitUntil { !model.searchBusy }
            if pendingMore {
                model.loadMoreSearch()
                await waitUntil { service.searchRequests.count == 2 }
            }
            settings.setJellyfinToken(v: "replacement-token")
            if pendingMore {
                service.resolveSearch(term: "shared query", startIndex: 50, page: page([item("stale", "Stale page")], total: 100, start: 50, received: 50))
                await waitUntil { !model.searchMoreBusy }
            }
            model.loadMoreSearch()
            await waitUntil { service.searchRequests.count == (pendingMore ? 3 : 2) }
            XCTAssertEqual(service.searchRequests.last?.startIndex, 0)
            XCTAssertTrue(model.searchResults.isEmpty)
            service.resolveSearch(term: "shared query", startIndex: 0, page: page([item("new", "New account")], total: 1, start: 0, received: 1))
            await waitUntil { !model.searchBusy && !model.searchMoreBusy }
            XCTAssertEqual(model.searchResults.map(\.id), ["new"])
            XCTAssertEqual(model.searchTotalRecordCount, 1)
            XCTAssertFalse(model.canLoadMoreSearch)
        }
    }

    func testBrowsePaginationRestartsAtRootForReplacementAccount() async {
        for pendingMore in [false, true] {
            let service = ControlledJellyfin()
            service.deferBrowse = true
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
            model.openFolder(item("old-series", "Old series", folder: true, type: "Series"))
            await waitUntil { service.browseRequests.count == 1 }
            service.resolveBrowse(requestId: 0, result: .success(page([item("old", "Old episode")], total: 100, start: 0, received: 50)))
            await waitUntil { !model.browseBusy }
            if pendingMore {
                model.loadMoreLibrary()
                await waitUntil { service.browseRequests.count == 2 }
            }
            settings.setJellyfinServer(v: "http://replacement.invalid")
            if pendingMore {
                service.resolveBrowse(requestId: 1, result: .success(page([item("stale", "Stale episode")], total: 100, start: 50, received: 50)))
                await waitUntil { !model.browseMoreBusy }
            }
            model.loadMoreLibrary()
            let requestCount = pendingMore ? 3 : 2
            await waitUntil { service.browseRequests.count == requestCount }
            XCTAssertEqual(service.browseRequests.last?.startIndex, 0)
            XCTAssertNil(service.browseRequests.last?.parentId)
            XCTAssertTrue(model.libraryPath.isEmpty)
            XCTAssertTrue(model.libraryItems.isEmpty)
            service.resolveBrowse(requestId: requestCount - 1, result: .success(page([item("new", "New library")], total: 1, start: 0, received: 1)))
            await waitUntil { !model.browseBusy && !model.browseMoreBusy }
            XCTAssertEqual(model.libraryItems.map(\.id), ["new"])
            XCTAssertFalse(model.canLoadMoreLibrary)
        }
    }

    func testRefreshRestartsSearchFromFirstPageWhileMoreIsLoading() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service) { _ in }
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "refresh"
        await waitUntil { service.searchRequests.count == 1 }
        let existingItems = (0..<50).map { item("page-\($0)", "Page \($0)") }
        service.resolveSearch(term: "refresh", startIndex: 0, page: page(existingItems, total: 51, start: 0, received: 50))
        await waitUntil { model.searchResults.count == 50 }

        model.loadMoreSearch()
        await waitUntil { service.searchRequests.count == 2 }
        XCTAssertEqual(service.searchRequests[1].startIndex, 50)
        model.refreshCurrentLocation()
        await waitUntil { service.searchRequests.count == 3 }
        XCTAssertEqual(service.searchRequests[2].startIndex, 0)

        service.resolveSearch(term: "refresh", startIndex: 0, page: page([item("fresh", "Fresh")], total: 1, start: 0, received: 1))
        await waitUntil { model.searchResults.map(\.id) == ["fresh"] }
        service.resolveSearch(term: "refresh", startIndex: 50, page: page([item("stale", "Stale")], total: 51, start: 50, received: 1))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(model.searchResults.map(\.id), ["fresh"])
    }
    func testNestedLibraryBackNavigationReloadsTheParentFolder() async {
        let service = ControlledJellyfin()
        let series = item("series", "Series", folder: true, type: "Series")
        let season = item("season", "Season 1", folder: true, type: "Season")
        let episode = item("episode", "Pilot", type: "Episode")
        service.browsePages["<root>"] = page([series], total: 1, start: 0, received: 1)
        service.browsePages["series"] = page([season], total: 1, start: 0, received: 1)
        service.browsePages["season"] = page([episode], total: 1, start: 0, received: 1)
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.loadLibraryIfNeeded()
        await waitUntil { model.libraryItems.map(\.id) == ["series"] }
        model.openFolder(series)
        await waitUntil { model.libraryItems.map(\.id) == ["season"] }
        model.openFolder(season)
        await waitUntil { model.libraryItems.map(\.id) == ["episode"] }
        model.goBack()
        await waitUntil { model.libraryItems.map(\.id) == ["season"] }
        model.goBack()
        await waitUntil { model.libraryItems.map(\.id) == ["series"] }

        XCTAssertEqual(service.browseRequests.map(\.parentId), [nil, "series", "season", "series", nil])
        XCTAssertEqual(service.browseRequests[1].order, .episode)
        XCTAssertEqual(service.browseRequests[2].order, .episode)
    }

    func testDisconnectDuringAuthenticationCannotRestoreExpiredSession() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        settings.setJellyfinToken(v: "")
        model.server = "http://new-jellyfin.invalid"
        model.username = "new-user"
        model.password = "password"
        model.connect()
        await waitUntil { service.authenticationPending }
        model.disconnect()
        service.resolveAuthentication(JellyfinAuth(token: "late-token", userId: "late-user"))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(model.connected)
        XCTAssertEqual(settings.jellyfinToken(), "")
    }
    func testDebounceIssuesOnlyLatestQueryAndClearCancelsPendingSearch() async {
        let service = ControlledJellyfin()
        let gate = SearchDelayGate()
        var delays: [UInt64] = []
        let (model, settings, saved, destination) = connectedModel(service) { delay in
            delays.append(delay)
            try await gate.wait(delay)
        }
        defer {
            gate.releaseAll()
            restore(model: model, service: service, settings: settings, saved: saved, destination: destination)
        }

        model.searchText = "old"
        await waitUntil { gate.count == 1 }
        model.searchText = "final"
        await waitUntil { gate.count == 2 }
        XCTAssertTrue(service.searchRequests.isEmpty)
        XCTAssertEqual(delays, [300_000_000, 300_000_000])

        gate.releaseAll()
        await waitUntil { service.searchRequests.count == 1 }
        XCTAssertEqual(service.searchRequests.map(\.term), ["final"])
        service.resolveSearch(term: "final", startIndex: 0, page: page([item("final", "Final")], total: 1, start: 0, received: 1))
        await waitUntil { model.searchResults.map(\.id) == ["final"] }

        model.searchText = "cleared while waiting"
        await waitUntil { gate.count == 1 }
        model.clearSearch()
        gate.releaseAll()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(service.searchRequests.map(\.term), ["final"])
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    func testSearchFolderBackRestoresSavedPagedResultsWithoutSearchingAgain() async {
        let service = ControlledJellyfin()
        let series = item("series", "Show", folder: true, type: "Series")
        let season = item("season", "Season 1", folder: true, type: "Season")
        let episode = item("episode", "Pilot", type: "Episode")
        service.browsePages["series"] = page([season], total: 1, start: 0, received: 1)
        service.browsePages["season"] = page([episode], total: 1, start: 0, received: 1)
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "show"
        await waitUntil { service.searchRequests.count == 1 }
        service.resolveSearch(term: "show", startIndex: 0, page: page([series], total: 100, start: 0, received: 50))
        await waitUntil { model.searchResults.map(\.id) == ["series"] }
        model.loadMoreSearch()
        await waitUntil { service.searchRequests.count == 2 }
        service.resolveSearch(term: "show", startIndex: 50, page: page([item("other", "Other")], total: 100, start: 50, received: 50))
        await waitUntil { model.searchResults.count == 2 }

        model.openFolder(series)
        await waitUntil { model.browseItems.map(\.id) == ["season"] }
        model.openFolder(season)
        await waitUntil { model.browseItems.map(\.id) == ["episode"] }
        model.goBack()
        await waitUntil { model.browseItems.map(\.id) == ["season"] }
        model.goBack()

        XCTAssertEqual(model.searchResults.map(\.id), ["series", "other"])
        XCTAssertEqual(model.currentItems.map(\.id), ["series", "other"])
        XCTAssertEqual(model.searchText, "show")
        XCTAssertEqual(service.searchRequests.count, 2)
    }

    func testFailedSearchLoadMorePreservesRowsAndRetriesSameOffset() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "retry"
        await waitUntil { service.searchRequests.count == 1 }
        service.resolveSearch(term: "retry", startIndex: 0, page: page([item("one", "One")], total: 100, start: 0, received: 50))
        await waitUntil { model.searchResults.map(\.id) == ["one"] }

        model.loadMoreSearch()
        await waitUntil { service.searchRequests.count == 2 }
        service.failSearch(term: "retry", startIndex: 50, error: NSError(domain: "network", code: 1))
        await waitUntil { model.searchMoreError != nil }
        XCTAssertEqual(model.searchResults.map(\.id), ["one"])

        model.loadMoreSearch()
        await waitUntil { service.searchRequests.count == 3 }
        XCTAssertEqual(service.searchRequests.map(\.startIndex), [0, 50, 50])
        service.resolveSearch(term: "retry", startIndex: 50, page: page([item("two", "Two")], total: 100, start: 50, received: 50))
        await waitUntil { model.searchResults.count == 2 }

        XCTAssertEqual(model.searchResults.map(\.id), ["one", "two"])
        XCTAssertNil(model.searchMoreError)
    }
    func testMultipleVersionsRequireExplicitChoiceAndKeepTheirSubtitles() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
        var opened: [JellyfinPlaybackSelection] = []
        let english = SubtitleTrack(url: "https://jf/english.vtt", language: "eng", title: "English")
        let french = SubtitleTrack(url: "https://jf/french.vtt", language: "fra", title: "French")

        model.play(item("movie", "Film")) { selection in
            opened.append(selection)
            return true
        }
        await waitUntil { service.mediaSourceRequests == ["movie"] }
        service.resolveMediaSources(itemId: "movie", sources: [
            mediaSource("low", name: "720p", subtitles: [english]),
            mediaSource("high", name: "2160p", subtitles: [french]),
        ])
        await waitUntil { model.versionChoice?.sources.count == 2 }

        XCTAssertTrue(opened.isEmpty)
        model.chooseVersion(sourceId: "high")

        XCTAssertEqual(opened.map(\.source.id), ["high"])
        XCTAssertEqual(opened.first?.source.subtitleTracks, [french])
        XCTAssertNil(model.versionChoice)
        XCTAssertNil(model.playbackError)
    }

    func testSingleVersionOpensImmediatelyAndEmptyItemCanRetry() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
        var opened: [JellyfinPlaybackSelection] = []

        model.play(item("movie", "Film")) { selection in
            opened.append(selection)
            return true
        }
        await waitUntil { service.mediaSourceRequests.count == 1 }
        service.resolveMediaSources(itemId: "movie", sources: [])
        await waitUntil { model.playbackError == "No playable versions are available for this item." }
        XCTAssertTrue(opened.isEmpty)

        model.retryPlayback()
        await waitUntil { service.mediaSourceRequests.count == 2 }
        service.resolveMediaSources(itemId: "movie", sources: [mediaSource("only", name: "Default")])
        await waitUntil { opened.count == 1 }

        XCTAssertEqual(opened[0].source.id, "only")
        XCTAssertNil(model.versionChoice)
        XCTAssertNil(model.playbackError)
    }

    func testLeavingFolderCancelsPendingVersionLookup() async {
        let service = ControlledJellyfin()
        let folder = item("folder", "Folder", folder: true, type: "Folder")
        service.browsePages["folder"] = page([], total: 0, start: 0, received: 0)
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
        var opened = false

        model.openFolder(folder)
        model.play(item("movie", "Film")) { _ in
            opened = true
            return true
        }
        await waitUntil { service.mediaSourceRequests == ["movie"] }
        model.backToRoot()
        service.resolveMediaSources(itemId: "movie", sources: [mediaSource("late", name: "Late")])
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(opened)
        XCTAssertNil(model.versionChoice)
        XCTAssertFalse(model.playbackBusy)
    }
    func testUnrecognizedVersionNeverFallsBackAndCanReloadChoices() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
        var opened: [JellyfinPlaybackSelection] = []

        model.play(item("movie", "Film")) { selection in
            opened.append(selection)
            return true
        }
        await waitUntil { service.mediaSourceRequests.count == 1 }
        service.resolveMediaSources(itemId: "movie", sources: [
            mediaSource("first", name: "First"), mediaSource("second", name: "Second"),
        ])
        await waitUntil { model.versionChoice != nil }
        model.chooseVersion(sourceId: "stale")

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(model.playbackError, "This version is no longer available. Reload versions and try again.")
        XCTAssertTrue(model.canRetryPlayback)

        model.retryPlayback()
        await waitUntil { service.mediaSourceRequests.count == 2 }
        service.resolveMediaSources(itemId: "movie", sources: [mediaSource("first", name: "First")])
        await waitUntil { opened.count == 1 }

        XCTAssertEqual(opened.first?.source.id, "first")
    }
    func testUnauthorizedSearchExpiresOnlyTheCurrentSession() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "expired"
        await waitUntil { service.searchRequests.count == 1 }
        service.failSearch(term: "expired", startIndex: 0, error: JellyfinInterop.shared.makeRequestException(statusCode: 401).asError())
        await waitUntil { !model.connected }

        XCTAssertEqual(settings.jellyfinToken(), "")
        XCTAssertEqual(model.notice, "Session expired. Sign in again.")
        XCTAssertTrue(model.noticeIsError)
    }

    func testForbiddenSearchKeepsSessionConnected() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "forbidden"
        await waitUntil { service.searchRequests.count == 1 }
        service.failSearch(term: "forbidden", startIndex: 0, error: JellyfinInterop.shared.makeRequestException(statusCode: 403).asError())
        await waitUntil { model.searchError != nil }

        XCTAssertTrue(model.connected)
        XCTAssertEqual(model.searchError, "You do not have permission to access this item.")
        XCTAssertEqual(settings.jellyfinToken(), "test-token")
    }

    func testLateUnauthorizedSearchCannotExpireReplacementAccount() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "old session"
        await waitUntil { service.searchRequests.count == 1 }
        settings.setJellyfinToken(v: "replacement-token")
        service.failSearch(term: "old session", startIndex: 0, error: JellyfinInterop.shared.makeRequestException(statusCode: 401).asError())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(settings.jellyfinToken(), "replacement-token")
        XCTAssertNil(model.notice)
    }

    func testCancelledRequestsCannotClearReplacementOperationBusyState() async {
        let service = ControlledJellyfin()
        service.deferBrowse = true
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.loadLibraryIfNeeded()
        await waitUntil { service.browseRequests.count == 1 }
        model.refreshLibrary()
        await waitUntil { service.browseRequests.count == 2 }
        service.resolveBrowse(requestId: 0, result: .failure(CancellationError()))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.browseBusy)
        service.resolveBrowse(requestId: 1, result: .success(page([item("current", "Current library")], total: 1, start: 0, received: 1)))
        await waitUntil { !model.browseBusy }
        XCTAssertEqual(model.libraryItems.map(\.id), ["current"])

        model.searchText = "older"
        await waitUntil { service.searchRequests.count == 1 }
        model.searchText = "newer"
        await waitUntil { service.searchRequests.count == 2 }
        service.failSearch(term: "older", startIndex: 0)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.searchBusy)
        service.resolveSearch(term: "newer", startIndex: 0, page: page([item("current", "Current search")], total: 1, start: 0, received: 1))
        await waitUntil { !model.searchBusy }
        XCTAssertEqual(model.searchResults.map(\.id), ["current"])
    }

    func testReplacedAccountSearchDiscardsSuccessAndFailureAndAllowsRetry() async {
        for succeeds in [true, false] {
            let service = ControlledJellyfin()
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
            model.searchText = "shared query"
            await waitUntil { service.searchRequests.count == 1 }
            XCTAssertTrue(model.searchBusy)
            settings.setJellyfinToken(v: "replacement-token")
            if succeeds {
                service.resolveSearch(term: "shared query", startIndex: 0, page: page([item("old", "Old account")], total: 1, start: 0, received: 1))
            } else {
                service.failSearch(term: "shared query", startIndex: 0, error: JellyfinInterop.shared.makeRequestException(statusCode: 401).asError())
            }
            await waitUntil { !model.searchBusy }
            XCTAssertTrue(model.searchResults.isEmpty)
            XCTAssertFalse(model.searchBusy)
            XCTAssertFalse(model.searchMoreBusy)
            XCTAssertNil(model.searchError)
            XCTAssertNil(model.notice)
            XCTAssertEqual(settings.jellyfinToken(), "replacement-token")
            model.searchNow()
            await waitUntil { service.searchRequests.count == 2 }
            XCTAssertEqual(service.searchRequests.count, 2)
            service.resolveSearch(term: "shared query", startIndex: 0, page: page([item("new", "Current account")], total: 1, start: 0, received: 1))
            await waitUntil { !model.searchBusy }
            XCTAssertEqual(model.searchResults.map(\.id), ["new"])
        }
    }

    func testReplacedAccountBrowseDiscardsSuccessAndFailureAndAllowsRetry() async {
        for succeeds in [true, false] {
            let service = ControlledJellyfin()
            service.deferBrowse = true
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }
            model.loadLibraryIfNeeded()
            await waitUntil { service.browseRequests.count == 1 }
            XCTAssertTrue(model.browseBusy)
            settings.setJellyfinUserId(v: "replacement-user")
            let result: Result<JellyfinItemPage, Error> = succeeds
                ? .success(page([item("old", "Old account")], total: 1, start: 0, received: 1))
                : .failure(JellyfinInterop.shared.makeRequestException(statusCode: 401).asError())
            service.resolveBrowse(requestId: 0, result: result)
            await waitUntil { !model.browseBusy }
            XCTAssertTrue(model.libraryItems.isEmpty)
            XCTAssertFalse(model.loadedOnce)
            XCTAssertFalse(model.browseBusy)
            XCTAssertFalse(model.browseMoreBusy)
            XCTAssertNil(model.libraryError)
            XCTAssertNil(model.notice)
            XCTAssertEqual(settings.jellyfinToken(), "test-token")
            model.loadLibraryIfNeeded()
            await waitUntil { service.browseRequests.count == 2 }
            XCTAssertEqual(service.browseRequests.count, 2)
            service.resolveBrowse(requestId: 1, result: .success(page([item("new", "Current account")], total: 1, start: 0, received: 1)))
            await waitUntil { !model.browseBusy }
            XCTAssertEqual(model.libraryItems.map(\.id), ["new"])
        }
    }

    func testKotlinCancellationDuringBrowseClearsBusyWithoutError() async {
        let service = ControlledJellyfin()
        service.browseError = JellyfinInterop.shared.makeCancellationThrowable().asError()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.loadLibraryIfNeeded()
        await waitUntil { service.browseRequests.count == 1 && !model.browseBusy }

        XCTAssertNil(model.libraryError)
        XCTAssertFalse(model.browseBusy)
    }

    func testKotlinCancellationDuringSearchClearsBusyWithoutError() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service) { _ in }
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.searchText = "cancel search"
        await waitUntil { service.searchRequests.count == 1 }
        service.failSearch(
            term: "cancel search",
            startIndex: 0,
            error: JellyfinInterop.shared.makeCancellationThrowable().asError()
        )
        await waitUntil { !model.searchBusy }

        XCTAssertNil(model.searchError)
        XCTAssertFalse(model.searchBusy)
    }

    func testReplacedAccountMediaSourceFailureClearsPlaybackAndAllowsNewPlay() async {
        let errors: [Error] = [
            JellyfinInterop.shared.makeRequestException(statusCode: 401).asError(),
            JellyfinInterop.shared.makeCancellationThrowable().asError(),
        ]
        for error in errors {
            let service = ControlledJellyfin()
            let (model, settings, saved, destination) = connectedModel(service)
            defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

            var opened: [JellyfinPlaybackSelection] = []
            model.play(item("old", "Old account film")) { opened.append($0); return true }
            await waitUntil { service.mediaSourceRequests == ["old"] }
            XCTAssertTrue(model.playbackBusy)
            settings.setJellyfinToken(v: "replacement-token")
            service.failMediaSources(itemId: "old", error: error)
            await waitUntil { !model.playbackBusy }

            XCTAssertFalse(model.playbackBusy)
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.canRetryPlayback)
            XCTAssertNil(model.versionChoice)
            XCTAssertTrue(opened.isEmpty)
            XCTAssertNil(model.notice)
            XCTAssertEqual(settings.jellyfinToken(), "replacement-token")

            model.play(item("new", "Current account film")) { opened.append($0); return true }
            await waitUntil { service.mediaSourceRequests == ["old", "new"] }
            service.resolveMediaSources(itemId: "new", sources: [mediaSource("current", name: "Current source")])
            await waitUntil { !model.playbackBusy }
            XCTAssertEqual(opened.map { $0.item.id }, ["new"])
            XCTAssertEqual(opened.first?.token, "replacement-token")
            XCTAssertNil(model.playbackError)
        }
    }

    func testCancelledMediaSourceFailureCannotClearReplacementLookup() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        var opened: [JellyfinPlaybackSelection] = []
        model.play(item("old", "Old account film")) { opened.append($0); return true }
        await waitUntil { service.mediaSourceRequests == ["old"] }
        settings.setJellyfinToken(v: "replacement-token")
        model.play(item("new", "Current account film")) { opened.append($0); return true }
        await waitUntil { service.mediaSourceRequests == ["old", "new"] }
        service.failMediaSources(itemId: "old", error: JellyfinInterop.shared.makeRequestException(statusCode: 401).asError())
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(model.playbackBusy)
        XCTAssertTrue(model.canRetryPlayback)
        XCTAssertNil(model.playbackError)
        XCTAssertEqual(settings.jellyfinToken(), "replacement-token")
        service.resolveMediaSources(itemId: "new", sources: [mediaSource("current", name: "Current source")])
        await waitUntil { !model.playbackBusy }
        XCTAssertEqual(opened.map { $0.item.id }, ["new"])
        XCTAssertEqual(opened.first?.token, "replacement-token")
    }

    func testKotlinCancellationDuringMediaSourceLookupClearsBusyWithoutError() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.play(item("movie", "Film")) { _ in true }
        await waitUntil { service.mediaSourceRequests == ["movie"] }
        service.failMediaSources(itemId: "movie", error: JellyfinInterop.shared.makeCancellationThrowable().asError())
        await waitUntil { !model.playbackBusy }

        XCTAssertNil(model.playbackError)
        XCTAssertTrue(model.canRetryPlayback)
    }
    func testUnauthorizedMediaSourceLookupReturnsToSignIn() async {
        let service = ControlledJellyfin()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        model.play(item("movie", "Film")) { _ in true }
        await waitUntil { service.mediaSourceRequests == ["movie"] }
        service.failMediaSources(itemId: "movie", error: JellyfinInterop.shared.makeRequestException(statusCode: 401).asError())
        await waitUntil { !model.connected }

        XCTAssertEqual(settings.jellyfinToken(), "")
        XCTAssertEqual(model.notice, "Session expired. Sign in again.")
        XCTAssertNil(model.versionChoice)
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
        let service = ControlledJellyfin()
        let settings = InMemoryJellyfinSettingsFacade()
        let model = JellyfinViewModel(jellyfin: service, settings: settings)
        defer {
            model.disconnect()
            service.cancelPending()
        }

        model.server = "https://old.example"
        model.username = "alice"
        model.password = "old-password"
        model.connect()
        await service.waitForAuthentication(base: "https://old.example")

        model.server = "https://new.example"
        model.password = "new-password"
        model.connect()
        await service.waitForAuthentication(base: "https://new.example")

        service.resolveAuthentication(
            base: "https://old.example",
            with: JellyfinAuth(token: "stale-token", userId: "stale-user")
        )
        await Task.yield()
        XCTAssertFalse(
            model.connected,
            "stale authentication changed credentials"
        )

        service.resolveAuthentication(
            base: "https://new.example",
            with: JellyfinAuth(token: "current-token", userId: "current-user")
        )
        for _ in 0..<100 where !model.connected {
            await Task.yield()
        }
        XCTAssertTrue(
            model.connected,
            "current authentication did not persist credentials"
        )
    }

    func testKotlinCancellationDuringAuthenticationIsNotPresentedAsFailure() async {
        let service = ControlledJellyfin()
        service.authenticationError = JellyfinInterop.shared.makeCancellationThrowable().asError()
        let (model, settings, saved, destination) = connectedModel(service)
        defer { restore(model: model, service: service, settings: settings, saved: saved, destination: destination) }

        settings.setJellyfinToken(v: "")
        model.server = "http://new-jellyfin.invalid"
        model.username = "new-user"
        model.password = "password"
        model.connect()
        await waitUntil { !model.connectBusy }

        XCTAssertFalse(model.connected)
        XCTAssertNil(model.notice)
    }
}
