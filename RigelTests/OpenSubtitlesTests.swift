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

        let downloadURL = try await client.download(results[0])
        XCTAssertEqual(downloadURL.absoluteString, "https://downloads.example/subtitle.srt")

        let capturedRequests = requests
        XCTAssertEqual(capturedRequests.count, 3)

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
