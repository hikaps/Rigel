import Foundation
import SwiftUI
import ComposeApp
struct JellyfinHistoryMatch: Equatable {
    let playableURL: String
    let baseURL: String
    let token: String
    let userId: String
    let itemId: String
}

enum HistoryPlaybackResolver {
    static func restoreJellyfin(
        historyURL: String,
        configuredBaseURL: String,
        token: String,
        userId: String
    ) -> JellyfinHistoryMatch? {
        guard !token.isEmpty, !userId.isEmpty,
              let history = parseHTTPURL(historyURL),
              let base = parseHTTPURL(configuredBaseURL),
              base.query == nil,
              sameOrigin(history, base),
              let itemId = libraryItemID(history, relativeTo: base),
              hasLibraryStreamQuery(history) else {
            return nil
        }

        var playable = history
        playable.queryItems = [URLQueryItem(name: "Static", value: "true"),
                               URLQueryItem(name: "api_key", value: token)]
        guard let playableURL = playable.url?.absoluteString else { return nil }
        return JellyfinHistoryMatch(
            playableURL: playableURL,
            baseURL: configuredBaseURL,
            token: token,
            userId: userId,
            itemId: itemId
        )
    }

    /// A configured Jellyfin stream URL must not fall through to unauthenticated
    /// generic playback when its credentials are unavailable.
    static func isLibraryStreamURL(_ rawURL: String, configuredBaseURL: String) -> Bool {
        guard let url = parseHTTPURL(rawURL),
              let base = parseHTTPURL(configuredBaseURL),
              base.query == nil,
              sameOrigin(url, base),
              libraryItemID(url, relativeTo: base) != nil else {
            return false
        }
        return true
    }

    private static func parseHTTPURL(_ rawURL: String) -> URLComponents? {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return nil
        }
        return components
    }

    private static func sameOrigin(_ lhs: URLComponents, _ rhs: URLComponents) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func libraryItemID(_ history: URLComponents, relativeTo base: URLComponents) -> String? {
        guard let baseSegments = pathSegments(base.percentEncodedPath),
              let historySegments = pathSegments(history.percentEncodedPath),
              historySegments.count == baseSegments.count + 3,
              Array(historySegments.prefix(baseSegments.count)) == baseSegments,
              historySegments[baseSegments.count] == "Videos",
              historySegments[baseSegments.count + 2] == "stream" else {
            return nil
        }
        let itemId = historySegments[baseSegments.count + 1]
        return itemId.isEmpty ? nil : itemId
    }

    private static func hasLibraryStreamQuery(_ url: URLComponents) -> Bool {
        guard let queryItems = url.queryItems, queryItems.count == 1,
              let item = queryItems.first else { return false }
        return item.name == "Static" && item.value == "true"
    }

    private static func pathSegments(_ encodedPath: String) -> [String]? {
        let encodedSegments = encodedPath.split(separator: "/", omittingEmptySubsequences: true)
        var segments: [String] = []
        segments.reserveCapacity(encodedSegments.count)
        for encodedSegment in encodedSegments {
            guard let decoded = String(encodedSegment).removingPercentEncoding,
                  decoded != ".", decoded != ".." else { return nil }
            segments.append(decoded)
        }
        return segments
    }
}
struct HistoryView: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var entries: [LinkHistoryEntry] = []
    @State private var confirmClear = false

    @State private var errorText: String?

    private var settings: SettingsStore { RigelCore.shared.settings }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !entries.isEmpty {
                    Button("Clear", role: .destructive) {
                        confirmClear = true
                    }
                }
            }
            .confirmationDialog(
                "Clear all links from history?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    settings.clearLinkHistory()
                    reload()
                }
            }
            .onAppear { reload() }
            .onChange(of: player.phase) { _ in reload() }
        }
    }

    private var historyList: some View {
        List {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(entries, id: \.url) { entry in
                Button {
                    open(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title ?? entry.url)
                            .lineLimit(1)
                        if entry.title != nil {
                            Text(entry.url)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .disabled(!player.futureDestinationAcceptsUrls)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(Color.rigelStar)
            Text("No links yet")
                .font(.headline)
            Text("Links you open or receive appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func reload() {
        errorText = nil
        entries = settings.linkHistory()
    }
    private func open(_ entry: LinkHistoryEntry) {
        errorText = nil
        let configuredBaseURL = settings.jellyfinServer()
        if let jellyfin = HistoryPlaybackResolver.restoreJellyfin(
            historyURL: entry.url,
            configuredBaseURL: configuredBaseURL,
            token: settings.jellyfinToken(),
            userId: settings.jellyfinUserId()
        ) {
            _ = player.open(
                url: jellyfin.playableURL,
                title: entry.title ?? jellyfin.itemId
            )
        } else if HistoryPlaybackResolver.isLibraryStreamURL(
            entry.url,
            configuredBaseURL: configuredBaseURL
        ) {
            errorText = "Unable to restore this Jellyfin link. Reconnect to the configured server in Sources."
        } else {
            _ = player.open(url: entry.url, title: entry.title)
        }
    }
}
