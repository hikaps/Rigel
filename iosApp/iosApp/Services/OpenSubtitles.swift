import Foundation
import Security
import ComposeApp

protocol OpenSubtitlesCredentialStore: AnyObject {
    var apiKey: String? { get set }
    var username: String? { get set }
    var token: String? { get set }
    var baseURL: String? { get set }
    var isConnected: Bool { get }
    func clear()
}

final class OpenSubtitlesKeychainStore: OpenSubtitlesCredentialStore {
    static let shared = OpenSubtitlesKeychainStore()

    private let service = "com.rigel.player.opensubtitles"

    var apiKey: String? {
        get { value(for: "api-key") }
        set { setValue(newValue, for: "api-key") }
    }

    var username: String? {
        get { value(for: "username") }
        set { setValue(newValue, for: "username") }
    }

    var token: String? {
        get { value(for: "token") }
        set { setValue(newValue, for: "token") }
    }

    var baseURL: String? {
        get { value(for: "base-url") }
        set { setValue(newValue, for: "base-url") }
    }

    var isConnected: Bool {
        guard let apiKey, !apiKey.isEmpty,
              let token, !token.isEmpty,
              let baseURL, !baseURL.isEmpty else {
            return false
        }
        return true
    }

    func clear() {
        for key in ["api-key", "username", "token", "base-url"] {
            setValue(nil, for: key)
        }
    }

    private func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func setValue(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, let data = value.data(using: .utf8), !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

struct OpenSubtitlesSession {
    let token: String
    let baseURL: String
}

struct OpenSubtitlesSearchResult: Identifiable, Hashable {
    let id: Int
    let title: String
    let language: String
    let fileName: String?
    let downloadCount: Int?
    let hearingImpaired: Bool
    let machineTranslated: Bool
    let aiTranslated: Bool

    var displayTitle: String {
        let trimmed = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? title : "\(title) — \(trimmed)"
    }

    var detail: String {
        var values = [language.uppercased()]
        if let downloadCount {
            values.append("\(downloadCount) downloads")
        }
        if hearingImpaired {
            values.append("HI")
        }
        if machineTranslated {
            values.append("machine translated")
        } else if aiTranslated {
            values.append("AI translated")
        }
        return values.joined(separator: " · ")
    }
}

enum OpenSubtitlesError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case httpStatus(Int, String?)
    case missingDownloadLink
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Configure OpenSubtitles in Settings before searching."
        case .invalidResponse:
            return "OpenSubtitles returned an invalid response."
        case let .httpStatus(status, detail):
            if let detail, !detail.isEmpty {
                return "OpenSubtitles error (HTTP \(status)): \(detail)"
            }
            return "OpenSubtitles error (HTTP \(status))."
        case .missingDownloadLink:
            return "OpenSubtitles did not provide a subtitle download link."
        case .unsupportedFile:
            return "The downloaded subtitle file is not a supported text format."
        }
    }
}

final class OpenSubtitlesClient {
    static let shared = OpenSubtitlesClient(store: OpenSubtitlesKeychainStore.shared)

    private static let apiRoot = URL(string: "https://api.opensubtitles.com/api/v1")!
    private static let userAgent = "Rigel iOS player/1.0"

    private let store: OpenSubtitlesCredentialStore
    private let session: URLSession

    init(store: OpenSubtitlesCredentialStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    func login(apiKey: String, username: String, password: String) async throws -> OpenSubtitlesSession {
        let body: [String: String] = [
            "username": username,
            "password": password,
        ]
        let request = try makeRequest(
            url: Self.apiRoot.appendingPathComponent("login"),
            method: "POST",
            apiKey: apiKey,
            body: try JSONEncoder().encode(body)
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard !decoded.token.isEmpty, !decoded.baseURL.isEmpty else {
            throw OpenSubtitlesError.invalidResponse
        }
        return OpenSubtitlesSession(token: decoded.token, baseURL: decoded.baseURL)
    }

    func search(query: String, language: String? = nil) async throws -> [OpenSubtitlesSearchResult] {
        guard let apiKey = store.apiKey,
              let token = store.token,
              let baseURL = store.baseURL,
              !apiKey.isEmpty,
              !token.isEmpty,
              let url = Self.endpoint(baseURL, path: "subtitles") else {
            throw OpenSubtitlesError.missingCredentials
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "query", value: trimmedQuery),
            URLQueryItem(name: "languages", value: language),
        ].compactMap { item in
            item.value == nil ? nil : item
        }
        guard let requestURL = components?.url else { throw OpenSubtitlesError.invalidResponse }
        let request = try makeRequest(url: requestURL, apiKey: apiKey, token: token)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.data.flatMap { entry in
            entry.attributes.files.compactMap { file in
                guard let fileID = file.fileID else { return nil }
                let title = entry.attributes.featureDetails?.title
                    ?? file.fileName
                    ?? "Subtitle"
                return OpenSubtitlesSearchResult(
                    id: fileID,
                    title: title,
                    language: entry.attributes.language ?? "und",
                    fileName: file.fileName,
                    downloadCount: entry.attributes.downloadCount,
                    hearingImpaired: entry.attributes.hearingImpaired ?? false,
                    machineTranslated: entry.attributes.machineTranslated ?? false,
                    aiTranslated: entry.attributes.aiTranslated ?? false
                )
            }
        }
    }

    /// Downloads the subtitle bytes and returns a local file URL. The remote
    /// link must never reach the HLS exporter: its FFmpeg network stack has
    /// no request timeout, so a stalled CDN connection would block session
    /// startup (and the player) indefinitely.
    func download(
        _ result: OpenSubtitlesSearchResult,
        destinationDirectory: URL? = nil
    ) async throws -> URL {
        guard let apiKey = store.apiKey,
              let token = store.token,
              let baseURL = store.baseURL,
              !apiKey.isEmpty,
              !token.isEmpty,
              let url = Self.endpoint(baseURL, path: "download") else {
            throw OpenSubtitlesError.missingCredentials
        }
        let body = try JSONEncoder().encode(DownloadRequest(fileID: result.id, format: "srt"))
        let request = try makeRequest(
            url: url,
            method: "POST",
            apiKey: apiKey,
            token: token,
            body: body
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(DownloadResponse.self, from: data)
        guard let link = URL(string: decoded.link), link.scheme == "https" || link.scheme == "http" else {
            throw OpenSubtitlesError.missingDownloadLink
        }
        return try await Self.fetchSubtitleFile(
            from: link,
            for: result,
            session: session,
            directory: destinationDirectory
        )
    }

    static func fetchSubtitleFile(
        from link: URL,
        for result: OpenSubtitlesSearchResult,
        session: URLSession,
        directory: URL?
    ) async throws -> URL {
        var request = URLRequest(url: link)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenSubtitlesError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenSubtitlesError.httpStatus(
                http.statusCode,
                HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        // OpenSubtitles may serve an archive or a gzip file instead of plain
        // text; the player only renders text SRT/VTT.
        let isZip = data.starts(with: [0x50, 0x4B])
        let isGzip = data.starts(with: [0x1F, 0x8B])
        guard !data.isEmpty, !isZip, !isGzip else {
            throw OpenSubtitlesError.unsupportedFile
        }

        let targetDirectory = directory ?? defaultSubtitleDirectory()
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let fileURL = targetDirectory.appendingPathComponent(localFileName(for: result))
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func defaultSubtitleDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Subtitles", isDirectory: true)
    }

    /// Unique per result id, stable across re-downloads (overwrites in place).
    static func localFileName(for result: OpenSubtitlesSearchResult) -> String {
        let baseName: String
        let requestedFile = (result.fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedFile.isEmpty {
            baseName = requestedFile
        } else {
            baseName = result.title
        }
        let stem = sanitizedFileName(baseName)
        return "\(stem)-\(result.id).srt"
    }

    static func sanitizedFileName(_ raw: String) -> String {
        var stem = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.hasSuffix(".srt") || stem.hasSuffix(".vtt") {
            stem = String(stem.dropLast(4))
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let replaced = String(String.UnicodeScalarView(stem.unicodeScalars.map {
            allowed.contains($0) ? $0 : "_"
        }))
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        let capped = String(trimmed.prefix(80))
        return capped.isEmpty ? "subtitle" : capped
    }

    private func makeRequest(
        url: URL,
        method: String = "GET",
        apiKey: String,
        token: String? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func endpoint(_ baseURL: String, path: String) -> URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let withScheme = raw.hasPrefix("http://") || raw.hasPrefix("https://")
            ? raw
            : "https://\(raw)"
        guard let base = URL(string: withScheme) else { return nil }
        let root = base.path.hasSuffix("/api/v1")
            ? base
            : base.appendingPathComponent("api/v1")
        return root.appendingPathComponent(path)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenSubtitlesError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(APIErrorResponse.self, from: data).message
            throw OpenSubtitlesError.httpStatus(http.statusCode, detail)
        }
    }

    private struct LoginResponse: Decodable {
        let token: String
        let baseURL: String

        enum CodingKeys: String, CodingKey {
            case token
            case baseURL = "base_url"
        }
    }

    private struct SearchResponse: Decodable {
        let data: [SearchEntry]
    }

    private struct SearchEntry: Decodable {
        let attributes: SearchAttributes
    }

    private struct SearchAttributes: Decodable {
        let language: String?
        let files: [SubtitleFile]
        let featureDetails: FeatureDetails?
        let downloadCount: Int?
        let hearingImpaired: Bool?
        let machineTranslated: Bool?
        let aiTranslated: Bool?

        enum CodingKeys: String, CodingKey {
            case language
            case files
            case featureDetails = "feature_details"
            case downloadCount = "download_count"
            case hearingImpaired = "hearing_impaired"
            case machineTranslated = "machine_translated"
            case aiTranslated = "ai_translated"
        }
    }

    private struct FeatureDetails: Decodable {
        let title: String?
    }

    private struct SubtitleFile: Decodable {
        let fileID: Int?
        let fileName: String?

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case fileName = "file_name"
        }
    }

    private struct DownloadRequest: Encodable {
        let fileID: Int
        let format: String

        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"
            case format = "sub_format"
        }
    }

    private struct DownloadResponse: Decodable {
        let link: String
    }

    private struct APIErrorResponse: Decodable {
        let message: String?
    }
}
