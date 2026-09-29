import Network
import XCTest

final class JellyfinWorkflowUITests: XCTestCase {
    func testVersionPickerCancelAndSelectionUseTheChosenSource() throws {
        let server = try JellyfinFixtureServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        let serverURL = "http://127.0.0.1:\(server.port)"
        app.launchArguments = [
            "-jellyfin_server", serverURL,
            "-jellyfin_token", "fixture-token",
            "-jellyfin_userid", "fixture-user",
            "-jellyfin_username", "fixture-user",
        ]
        app.launch()
        defer { app.terminate() }

        let sourcesTab = app.buttons.matching(identifier: "Sources").firstMatch
        XCTAssertTrue(sourcesTab.waitForExistence(timeout: 10))
        sourcesTab.tap()
        let search = app.textFields["Movies, shows, or episodes"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("smoke\n")
        XCTAssertTrue(app.staticTexts["1 of 1 results"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Smoke Feature"].waitForExistence(timeout: 5))

        let play = app.buttons.matching(identifier: "Play").firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(app.navigationBars["Choose version"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["720p copy"].exists)
        XCTAssertTrue(app.staticTexts["1080p master"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Jellyfin version picker"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["Choose version"].waitForExistence(timeout: 2))
        XCTAssertTrue(server.requestedSourceIds.isEmpty)

        app.buttons.matching(identifier: "Play").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Choose version"].waitForExistence(timeout: 10))
        let highVersion = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "1080p master")
        ).firstMatch
        XCTAssertTrue(highVersion.exists)

        let selectedSource = expectation(description: "selected source reaches the media endpoint")
        server.onSourceRequest = { sourceId in
            if sourceId == "high" { selectedSource.fulfill() }
        }
        highVersion.tap()
        wait(for: [selectedSource], timeout: 10)
        XCTAssertTrue(server.requestedSourceIds.contains("high"))
    }
}

private final class JellyfinFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rigel.jellyfin-fixture")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sourceIds: [String] = []
    var onSourceRequest: ((String) -> Void)?

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requestedSourceIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sourceIds
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() throws {
        listener.stateUpdateHandler = { [ready] state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw FixtureServerError.notReady
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let firstLine = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first
            else {
                connection.cancel()
                return
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.send(connection, status: 400, contentType: "text/plain", body: Data())
                return
            }
            let method = String(parts[0])
            let target = String(parts[1])
            let url = URLComponents(string: "http://127.0.0.1\(target)")
            switch (method, url?.path) {
            case ("POST", "/Users/AuthenticateByName"):
                self.send(connection, contentType: "application/json", body: Data(#"{"AccessToken":"fixture-token","User":{"Id":"fixture-user"}}"#.utf8))
            case ("GET", "/Items"):
                self.send(connection, contentType: "application/json", body: Data(#"{"Items":[{"Id":"movie-1","Name":"Smoke Feature","Type":"Movie","IsFolder":false,"ProductionYear":2024}],"TotalRecordCount":1,"StartIndex":0}"#.utf8))
            case ("GET", "/Items/movie-1"):
                self.send(connection, contentType: "application/json", body: Data(#"{"Id":"movie-1","MediaSources":[{"Id":"low","Name":"720p copy","Container":"mp4","Size":22000,"MediaStreams":[{"Type":"Video","Codec":"h264","Width":640,"Height":360},{"Type":"Audio","Codec":"aac","Channels":2},{"Type":"Subtitle","Index":0,"IsExternal":true,"Language":"eng","DisplayTitle":"English"}]},{"Id":"high","Name":"1080p master","Container":"mkv","Size":41000,"MediaStreams":[{"Type":"Video","Codec":"h264","Width":1280,"Height":720},{"Type":"Audio","Codec":"aac","Channels":2},{"Type":"Subtitle","Index":1,"IsExternal":true,"Language":"fra","DisplayTitle":"French"}]}]}"#.utf8))
            case ("GET", "/Videos/movie-1/stream"):
                let sourceId = url?.queryItems?.first(where: { $0.name == "MediaSourceId" })?.value ?? ""
                lock.lock()
                sourceIds.append(sourceId)
                let callback = onSourceRequest
                lock.unlock()
                callback?(sourceId)
                self.send(connection, contentType: "video/mp4", body: Data())
            default:
                self.send(connection, status: 404, contentType: "application/json", body: Data("{}".utf8))
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int = 200, contentType: String, body: Data) {
        let phrase = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"
        var response = Data("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum FixtureServerError: Error {
        case notReady
    }
}
