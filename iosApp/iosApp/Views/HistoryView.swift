import Foundation
import SwiftUI
import ComposeApp
struct JellyfinHistoryMatch: Equatable {
    let baseURL: String
    let token: String
    let userId: String
    let itemId: String
    let mediaSourceId: String?
}

enum HistoryPlaybackResolver {
    enum LegacyStreamClassification: Equatable {
        case unrelated
        case rejected
        case replayable(itemId: String, mediaSourceId: String?)
    }

    static func classifyLegacyJellyfinStream(_ rawURL: String) -> LegacyStreamClassification {
        guard let url = URLComponents(string: rawURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              let itemId = streamItemID(url),
              let queryItems = url.queryItems,
              queryItems.contains(where: { ["static", "mediasourceid", "api_key", "apikey"].contains($0.name.lowercased()) }) else {
            return .unrelated
        }

        guard url.user == nil, url.password == nil, url.fragment == nil else { return .rejected }

        var valid = true
        var staticCount = 0
        var sourceCount = 0
        var credentialCount = 0
        var mediaSourceId: String?
        for item in queryItems {
            let hasControl = item.name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                || (item.value?.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ?? false)
            guard !hasControl else {
                valid = false
                continue
            }

            switch item.name {
            case "Static":
                staticCount += 1
                if item.value != "true" { valid = false }
            case "MediaSourceId":
                sourceCount += 1
                guard let value = item.value, !value.isEmpty else {
                    valid = false
                    continue
                }
                mediaSourceId = value
            case "api_key", "ApiKey":
                credentialCount += 1
                if item.value?.isEmpty != false { valid = false }
            default:
                valid = false
            }
        }

        guard staticCount == 1, sourceCount <= 1, credentialCount <= 1 else { return .rejected }
        guard valid else { return .rejected }
        return .replayable(itemId: itemId, mediaSourceId: mediaSourceId)
    }

    static func restoreJellyfin(
        historyURL: String,
        configuredBaseURL: String,
        token: String,
        userId: String
    ) -> JellyfinHistoryMatch? {
        guard case .replayable(let itemId, let mediaSourceId) = classifyLegacyJellyfinStream(historyURL),
              !token.isEmpty, !userId.isEmpty,
              let history = parseHTTPURL(historyURL),
              let base = parseHTTPURL(configuredBaseURL),
              base.query == nil,
              sameOrigin(history, base),
              libraryItemID(history, relativeTo: base) == itemId else {
            return nil
        }

        return JellyfinHistoryMatch(
            baseURL: configuredBaseURL,
            token: token,
            userId: userId,
            itemId: itemId,
            mediaSourceId: mediaSourceId
        )
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

    private static func streamItemID(_ url: URLComponents) -> String? {
        guard let segments = pathSegments(url.percentEncodedPath), segments.count >= 3,
              segments[segments.count - 3] == "Videos",
              segments[segments.count - 1] == "stream" else {
            return nil
        }
        let itemId = segments[segments.count - 2]
        return itemId.isEmpty ? nil : itemId
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
        let classification = HistoryPlaybackResolver.classifyLegacyJellyfinStream(entry.url)
        guard case .unrelated = classification else {
            let jellyfin = HistoryPlaybackResolver.restoreJellyfin(
                historyURL: entry.url,
                configuredBaseURL: settings.jellyfinServer(),
                token: settings.jellyfinToken(),
                userId: settings.jellyfinUserId()
            )
            guard let jellyfin else {
                errorText = "Unable to restore this Jellyfin link. Reconnect to the configured server in Sources."
                return
            }

            _ = player.openJellyfin(
                title: entry.title ?? jellyfin.itemId,
                subtitleTracks: [],
                baseUrl: jellyfin.baseURL,
                token: jellyfin.token,
                userId: jellyfin.userId,
                itemId: jellyfin.itemId,
                mediaSourceId: jellyfin.mediaSourceId
            )
            return
        }
        _ = player.open(url: entry.url, title: entry.title)
    }
}
