import Foundation
import XCTest
@testable import Rigel

final class OpenSubtitlesTests: XCTestCase {
    func testLoginSearchAndDownloadUseApplicationAndSessionCredentials() async throws {
        let store = TestCredentialStore()
        var requests: [URLRequest] = []
        let requestLock = NSLock()
        OpenSubtitlesURLProtocol.handler = { request in
            requestLock.lock()
            requests.append(request)
            requestLock.unlock()

            switch request.url?.path {
            case "/api/v1/login":
                return Self.response(
                    request: request,
                    body: "{\"token\":\"token-123\",\"base_url\":\"api.opensubtitles.com\"}"
                )
            case "/api/v1/subtitles":
                return Self.response(
                    request: request,
                    body: """
                    {"data":[{"id":"42","attributes":{"language":"en","files":[{"file_id":987,"file_name":"Matrix.en.srt"}],"feature_details":{"title":"The Matrix"},"download_count":12,"hearing_impaired":false,"machine_translated":false,"ai_translated":false}}]}
                    """
                )
            case "/api/v1/download":
                return Self.response(
                    request: request,
                    body: "{\"link\":\"https://dl.opensubtitles.com/subtitle.srt\"}"
                )
            case "/subtitle.srt":
                return Self.response(
                    request: request,
                    body: "1\n00:00:00,000 --> 00:00:01,000\nHello\n"
                )
            default:
                return Self.response(request: request, statusCode: 404, body: "{}")
            }
        }
        defer { OpenSubtitlesURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenSubtitlesURLProtocol.self]
        let client = OpenSubtitlesClient(
            store: store,
            session: URLSession(configuration: configuration)
        )

        let session = try await client.login(
            apiKey: "app-key",
            username: "rigel-user",
            password: "secret"
        )
        XCTAssertEqual(session.token, "token-123")
        XCTAssertEqual(session.baseURL, "api.opensubtitles.com")

        store.apiKey = "app-key"
        store.username = "rigel-user"
        store.token = session.token
        store.baseURL = session.baseURL

        let results = try await client.search(query: "The Matrix", language: "en")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 987)
        XCTAssertEqual(results[0].title, "The Matrix")
        XCTAssertEqual(results[0].language, "en")
        XCTAssertEqual(results[0].fileName, "Matrix.en.srt")

        // The download must land on disk: the HLS exporter cannot be pointed
        // at the remote link (no network timeouts in its FFmpeg stack).
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensubtitles-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let downloadURL = try await client.download(results[0], destinationDirectory: destination)
        XCTAssertTrue(downloadURL.isFileURL, downloadURL.absoluteString)
        XCTAssertEqual(downloadURL.lastPathComponent, "Matrix.en-987.srt")
        let saved = try String(contentsOf: downloadURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("Hello"), saved)

        let capturedRequests = requests
        XCTAssertEqual(capturedRequests.count, 4)

        let loginRequest = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(loginRequest.value(forHTTPHeaderField: "Api-Key"), "app-key")
        XCTAssertNotNil(loginRequest.value(forHTTPHeaderField: "User-Agent"))
        let loginBody = try Self.bodyData(of: loginRequest)
        let loginJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: loginBody) as? [String: String]
        )
        XCTAssertEqual(loginJSON["username"], "rigel-user")
        XCTAssertEqual(loginJSON["password"], "secret")

        let searchRequest = try XCTUnwrap(capturedRequests[1])
        XCTAssertEqual(searchRequest.value(forHTTPHeaderField: "Api-Key"), "app-key")
        XCTAssertEqual(
            searchRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer token-123"
        )
        let searchQuery = try XCTUnwrap(URLComponents(url: try XCTUnwrap(searchRequest.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(searchQuery.first(where: { $0.name == "query" })?.value, "The Matrix")
        XCTAssertEqual(searchQuery.first(where: { $0.name == "languages" })?.value, "en")

        let downloadRequest = try XCTUnwrap(capturedRequests[2])
        XCTAssertEqual(downloadRequest.httpMethod, "POST")
        XCTAssertEqual(downloadRequest.value(forHTTPHeaderField: "Api-Key"), "app-key")
        XCTAssertEqual(
            downloadRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer token-123"
        )
        let downloadBody = try Self.bodyData(of: downloadRequest)
        let downloadJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: downloadBody) as? [String: Any]
        )
        XCTAssertEqual(downloadJSON["file_id"] as? Int, 987)
        XCTAssertEqual(downloadJSON["sub_format"] as? String, "srt")

        let fileRequest = try XCTUnwrap(capturedRequests[3])
        XCTAssertEqual(fileRequest.url?.absoluteString, "https://dl.opensubtitles.com/subtitle.srt")
        XCTAssertEqual(fileRequest.value(forHTTPHeaderField: "Api-Key"), "app-key")
        XCTAssertNotNil(fileRequest.value(forHTTPHeaderField: "User-Agent"))
    }

    func testDownloadRejectsArchivePayloads() async throws {
        serve([
            "/api/v1/download": (200, Self.data("{\"link\":\"https://dl.opensubtitles.com/batch.zip\"}")),
            "/batch.zip": (200, Data("PK\u{03}\u{04}not-a-plain-subtitle".utf8)),
        ])
        defer { OpenSubtitlesURLProtocol.handler = nil }

        do {
            _ = try await makeAuthorizedClient().download(makeResult(id: 5, title: "Batch", fileName: "batch.srt"))
            XCTFail("archive payload must not be saved as a subtitle")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(error.localizedDescription, OpenSubtitlesError.unsupportedFile.localizedDescription)
        }
    }

    func testDownloadSurfacesHTTPFailures() async throws {
        serve([
            "/api/v1/download": (200, Self.data("{\"link\":\"https://dl.opensubtitles.com/gone.srt\"}")),
            "/gone.srt": (403, Self.data("forbidden")),
        ])
        defer { OpenSubtitlesURLProtocol.handler = nil }

        do {
            _ = try await makeAuthorizedClient().download(makeResult(id: 6, title: "Gone", fileName: "gone.srt"))
            XCTFail("HTTP failure must surface")
        } catch let error as OpenSubtitlesError {
            guard case let .httpStatus(status, _) = error else {
                return XCTFail("expected httpStatus, got \(error)")
            }
            XCTAssertEqual(status, 403)
        }
    }

    func testDownloadNormalizesEncodedSubtitlesToUtf8() async throws {
        let text = "1\n00:00:00,000 --> 00:00:01,000\nCafé — é\n"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(contentsOf: text.data(using: .utf16LittleEndian) ?? Data())
        serve([
            "/api/v1/download": (200, Self.data("{\"link\":\"https://dl.opensubtitles.com/utf16.srt\"}")),
            "/utf16.srt": (200, utf16),
        ])
        defer { OpenSubtitlesURLProtocol.handler = nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensubtitles-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let result = makeResult(id: 7, title: "Encoded", fileName: "encoded.srt")
        let fileURL = try await makeAuthorizedClient().download(result, destinationDirectory: destination)
        let saved = try Data(contentsOf: fileURL)
        // Clean UTF-8 without BOM: FFmpeg's SRT demuxer reads this byte-for-byte.
        XCTAssertEqual(saved.first, UInt8(ascii: "1"), "saved file must start with the cue, no BOM")
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), text)
    }

    func testLocalFileNameIsSanitizedAndUnique() {
        XCTAssertEqual(
            OpenSubtitlesClient.localFileName(for: makeResult(id: 987, title: "The Matrix", fileName: "Matrix.en.srt")),
            "Matrix.en-987.srt"
        )
        XCTAssertEqual(
            OpenSubtitlesClient.localFileName(for: makeResult(id: 12, title: "Movie: A Title?", fileName: nil)),
            "Movie_ A Title-12.srt"
        )
        XCTAssertEqual(
            OpenSubtitlesClient.localFileName(for: makeResult(id: 3, title: "###", fileName: "///")),
            "subtitle-3.srt"
        )
    }

    func testLoginRejectsUntrustedBaseURL() async throws {
        serve([
            "/api/v1/login": (200, Self.data("{\"token\":\"token-123\",\"base_url\":\"api.opensubtitles.com.attacker.example\"}")),
        ])
        defer {
            OpenSubtitlesURLProtocol.handler = nil
        }

        do {
            _ = try await makeAuthorizedClient().login(apiKey: "app-key", username: "user", password: "password")
            XCTFail("login must reject an untrusted base_url")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(error.localizedDescription, OpenSubtitlesError.invalidResponse.localizedDescription)
        }
    }

    func testDownloadRejectsInsecureLookalikeAndNonstandardPortLinks() async throws {
        let links = [
            "http://dl.opensubtitles.com/subtitle.srt",
            "https://user:secret@dl.opensubtitles.com/subtitle.srt",
            "https://dl.opensubtitles.com.attacker.example/subtitle.srt",
            "https://dl.opensubtitles.com:8443/subtitle.srt",
        ]
        defer {
            OpenSubtitlesURLProtocol.handler = nil
        }

        for link in links {
            do {
                _ = try await OpenSubtitlesClient.fetchSubtitleFile(
                    from: try XCTUnwrap(URL(string: link)),
                    for: makeResult(id: 8, title: "Rejected", fileName: "rejected.srt"),
                    apiKey: "app-key",
                    session: makeSession(),
                    directory: nil
                )
                XCTFail("unsafe link must be rejected: \(link)")
            } catch let error as OpenSubtitlesError {
                XCTAssertEqual(error.localizedDescription, OpenSubtitlesError.missingDownloadLink.localizedDescription)
            }
        }
    }

    func testAPIRequestRedirectRejectsUntrustedAuthority() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.opensubtitles.com.attacker.example/api/v1/subtitles"))
        )
        request.setValue("stale-key", forHTTPHeaderField: "Api-Key")
        request.setValue("Bearer stale-token", forHTTPHeaderField: "Authorization")

        let redirected = OpenSubtitlesClient.redirectedRequest(
            for: request,
            policy: .api(apiKey: "app-key", token: "token-123")
        )

        XCTAssertNil(redirected, "API credentials must not follow an untrusted authority")
    }

    func testAPIRequestDispatchUsesTrustedAuthorityAndCredentials() async throws {
        var requests: [URLRequest] = []
        let lock = NSLock()
        serve([
            "/api/v1/subtitles": (200, Self.data("{\"data\":[]}")),
        ])
        OpenSubtitlesURLProtocol.observer = { request in
            lock.lock()
            requests.append(request)
            lock.unlock()
        }
        defer {
            OpenSubtitlesURLProtocol.handler = nil
            OpenSubtitlesURLProtocol.observer = nil
        }

        let results = try await makeAuthorizedClient().search(query: "The Matrix")
        XCTAssertEqual(results.count, 0)

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.host, "api.opensubtitles.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Api-Key"), "app-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
    }

    func testSignedThirdPartyLinkDoesNotReceiveApplicationKey() async throws {
        var requests: [URLRequest] = []
        let lock = NSLock()
        serve([
            "/subtitle.srt": (200, Self.data("1\n00:00:00,000 --> 00:00:01,000\nSigned\n")),
        ])
        OpenSubtitlesURLProtocol.observer = { request in
            lock.lock()
            requests.append(request)
            lock.unlock()
        }
        defer {
            OpenSubtitlesURLProtocol.handler = nil
            OpenSubtitlesURLProtocol.observer = nil
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensubtitles-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await OpenSubtitlesClient.fetchSubtitleFile(
            from: try XCTUnwrap(URL(string: "https://signed.example/subtitle.srt")),
            for: makeResult(id: 9, title: "Signed", fileName: "signed.srt"),
            apiKey: "app-key",
            session: makeSession(),
            directory: destination
        )
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Api-Key"))
    }

    func testTrustedCDNRedirectStripsApiKeyForSignedDestination() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://signed.example/subtitle.srt"))
        )
        request.setValue("app-key", forHTTPHeaderField: "Api-Key")
        request.setValue("Bearer token-123", forHTTPHeaderField: "Authorization")

        let redirected = try XCTUnwrap(
            OpenSubtitlesClient.redirectedRequest(
                for: request,
                policy: .download(apiKey: "app-key")
            )
        )

        XCTAssertNil(redirected.value(forHTTPHeaderField: "Api-Key"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    }

    func testTrustedCDNRedirectRejectsHTTPDowngrade() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "http://signed.example/subtitle.srt"))
        )
        request.setValue("app-key", forHTTPHeaderField: "Api-Key")

        XCTAssertNil(
            OpenSubtitlesClient.redirectedRequest(
                for: request,
                policy: .download(apiKey: "app-key")
            )
        )
    }

    func testSubtitleTransportStopsAtMaximumSize() async throws {
        serve([
            "/too-large.srt": (200, Data(repeating: 0x61, count: OpenSubtitlesClient.maximumSubtitleBytes + 1)),
        ])
        defer {
            OpenSubtitlesURLProtocol.handler = nil
        }

        do {
            _ = try await OpenSubtitlesClient.fetchSubtitleFile(
                from: try XCTUnwrap(URL(string: "https://signed.example/too-large.srt")),
                for: makeResult(id: 12, title: "Large", fileName: "large.srt"),
                apiKey: "app-key",
                session: makeSession(),
                directory: nil
            )
            XCTFail("oversize subtitle must be rejected while streaming")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(error.localizedDescription, OpenSubtitlesError.fileTooLarge.localizedDescription)
        }
    }



    // MARK: - Helpers
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenSubtitlesURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeAuthorizedClient() -> OpenSubtitlesClient {
        let store = TestCredentialStore()
        store.apiKey = "app-key"
        store.token = "token-123"
        store.baseURL = "api.opensubtitles.com"
        return OpenSubtitlesClient(store: store, session: makeSession())
    }

    private func makeResult(id: Int, title: String, fileName: String?) -> OpenSubtitlesSearchResult {
        OpenSubtitlesSearchResult(
            id: id,
            title: title,
            language: "en",
            fileName: fileName,
            downloadCount: nil,
            hearingImpaired: false,
            machineTranslated: false,
            aiTranslated: false
        )
    }

    private func serve(_ routes: [String: (status: Int, body: Data)]) {
        OpenSubtitlesURLProtocol.handler = { request in
            let route = routes[request.url?.path ?? ""] ?? (404, Self.data("{}"))
            return Self.response(request: request, statusCode: route.status, body: route.body)
        }
    }

    private static func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    private static func response(
        request: URLRequest,
        statusCode: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        response(request: request, statusCode: statusCode, body: Data(body.utf8))
    }

    private static func response(
        request: URLRequest,
        statusCode: Int = 200,
        body: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            body
        )
    }

    private static func bodyData(of request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw NSError(domain: "OpenSubtitlesTests", code: 1)
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? NSError(domain: "OpenSubtitlesTests", code: 2)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class TestCredentialStore: OpenSubtitlesCredentialStore {
    var apiKey: String?
    var username: String?
    var token: String?
    var baseURL: String?

    var isConnected: Bool {
        apiKey?.isEmpty == false && token?.isEmpty == false && baseURL?.isEmpty == false
    }

    func clear() {
        apiKey = nil
        username = nil
        token = nil
        baseURL = nil
    }
}

private final class OpenSubtitlesURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var observer: ((URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.observer?(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
