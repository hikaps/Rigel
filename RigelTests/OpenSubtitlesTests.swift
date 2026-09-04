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
                    body: "{\"link\":\"https://downloads.example/subtitle.srt\"}"
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
        XCTAssertEqual(fileRequest.url?.absoluteString, "https://downloads.example/subtitle.srt")
    }

    func testDownloadRejectsArchivePayloads() async throws {
        OpenSubtitlesURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v1/download":
                return Self.response(
                    request: request,
                    body: "{\"link\":\"https://downloads.example/batch.zip\"}"
                )
            case "/batch.zip":
                return Self.response(
                    request: request,
                    body: "PK\u{03}\u{04}not-a-plain-subtitle"
                )
            default:
                return Self.response(request: request, statusCode: 404, body: "{}")
            }
        }
        defer { OpenSubtitlesURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenSubtitlesURLProtocol.self]
        let store = TestCredentialStore()
        store.apiKey = "app-key"
        store.token = "token-123"
        store.baseURL = "api.opensubtitles.com"
        let client = OpenSubtitlesClient(
            store: store,
            session: URLSession(configuration: configuration)
        )
        let result = OpenSubtitlesSearchResult(
            id: 5,
            title: "Batch",
            language: "en",
            fileName: "batch.srt",
            downloadCount: nil,
            hearingImpaired: false,
            machineTranslated: false,
            aiTranslated: false
        )

        do {
            _ = try await client.download(result)
            XCTFail("archive payload must not be saved as a subtitle")
        } catch let error as OpenSubtitlesError {
            XCTAssertEqual(error.localizedDescription, OpenSubtitlesError.unsupportedFile.localizedDescription)
        }
    }

    func testDownloadSurfacesHTTPFailures() async throws {
        OpenSubtitlesURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v1/download":
                return Self.response(
                    request: request,
                    body: "{\"link\":\"https://downloads.example/gone.srt\"}"
                )
            case "/gone.srt":
                return Self.response(request: request, statusCode: 403, body: "forbidden")
            default:
                return Self.response(request: request, statusCode: 404, body: "{}")
            }
        }
        defer { OpenSubtitlesURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenSubtitlesURLProtocol.self]
        let store = TestCredentialStore()
        store.apiKey = "app-key"
        store.token = "token-123"
        store.baseURL = "api.opensubtitles.com"
        let client = OpenSubtitlesClient(
            store: store,
            session: URLSession(configuration: configuration)
        )
        let result = OpenSubtitlesSearchResult(
            id: 6,
            title: "Gone",
            language: "en",
            fileName: "gone.srt",
            downloadCount: nil,
            hearingImpaired: false,
            machineTranslated: false,
            aiTranslated: false
        )

        do {
            _ = try await client.download(result)
            XCTFail("HTTP failure must surface")
        } catch let error as OpenSubtitlesError {
            guard case let .httpStatus(status, _) = error else {
                return XCTFail("expected httpStatus, got \(error)")
            }
            XCTAssertEqual(status, 403)
        }
    }

    func testLocalFileNameIsSanitizedAndUnique() {
        func result(_ title: String, _ fileName: String?, id: Int) -> OpenSubtitlesSearchResult {
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
        XCTAssertEqual(
            OpenSubtitlesClient.localFileName(for: result("The Matrix", "Matrix.en.srt", id: 987)),
            "Matrix.en-987.srt"
        )
        XCTAssertEqual(
            OpenSubtitlesClient.localFileName(for: result("Movie: A Title?", nil, id: 12)),
            "Movie_ A Title-12.srt"
        )
        XCTAssertEqual(
            OpenSubtitlesClient.localFileName(for: result("###", "///", id: 3)),
            "subtitle-3.srt"
        )
    }

    private static func response(
        request: URLRequest,
        statusCode: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
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

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
