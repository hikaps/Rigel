import Foundation
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
        XCTAssertTrue(app.staticTexts["Resume Feature"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Next Feature"].waitForExistence(timeout: 5))
        XCTAssertEqual(server.rootItemsRequestCount, 0)
        let homeAttachment = XCTAttachment(screenshot: app.screenshot())
        homeAttachment.name = "Personalized Jellyfin home"
        homeAttachment.lifetime = .keepAlways
        add(homeAttachment)

        let search = app.textFields["Movies, shows, or episodes"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("smoke\n")
        XCTAssertTrue(app.staticTexts["1 of 1 results"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Smoke Feature"].waitForExistence(timeout: 5))

        let noNegotiationAfterCancel = expectation(description: "cancelled version selection makes no source request")
        noNegotiationAfterCancel.isInverted = true
        server.onSourceRequest = { _ in noNegotiationAfterCancel.fulfill() }
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
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Choose version"]
        )
        // Match the picker presentation budget: CI accessibility snapshots can exceed two seconds.
        wait(for: [dismissed], timeout: 10)
        wait(for: [noNegotiationAfterCancel], timeout: 1)
        XCTAssertTrue(server.requestedSourceIds.isEmpty)
        XCTAssertTrue(server.playbackRequestSourceIds.isEmpty)
        XCTAssertTrue(server.forcedStaticSourceIds.isEmpty)
        XCTAssertEqual(server.directStreamRequestCount, 0)
        server.onSourceRequest = nil

        app.buttons.matching(identifier: "Play").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Choose version"].waitForExistence(timeout: 10))
        let highVersion = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "1080p master")
        ).firstMatch
        XCTAssertTrue(highVersion.exists)

        let selectedSource = expectation(description: "PlaybackInfo preserves the selected version")
        server.onSourceRequest = { sourceId in
            if sourceId == "high" { selectedSource.fulfill() }
        }
        let selectedHLSMedia = expectation(description: "the selected session serves its HLS segment")
        let selectedSubtitleBytes = expectation(description: "the selected version serves its bundled subtitle")
        var observedFixtureResources = Set<String>()
        server.onFixtureServed = { resourcePath in
            guard observedFixtureResources.insert(resourcePath).inserted else { return }
            if resourcePath == "fixture_hls/seg000.ts" { selectedHLSMedia.fulfill() }
            if resourcePath == "fixture_sub_fr.srt" { selectedSubtitleBytes.fulfill() }
        }
        highVersion.tap()
        wait(for: [selectedSource, selectedHLSMedia, selectedSubtitleBytes], timeout: 30)
        XCTAssertEqual(server.requestedSourceIds, ["high"])
        XCTAssertEqual(server.playbackRequestSourceIds, ["high"])
        XCTAssertEqual(server.playbackRequestUserIds, ["fixture-user"])

        let subtitles = app.buttons["Subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 30))
        XCTAssertTrue(server.servedHLSMediaSourceIds.contains("high"))
        XCTAssertTrue(server.servedHLSPlaySessionIds.contains("fixture-high-session"))
        XCTAssertTrue(server.servedFixtureResourcePaths.contains("fixture_hls/index.m3u8"))
        XCTAssertTrue(server.servedFixtureResourcePaths.contains("fixture_hls/seg000.ts"))
        XCTAssertTrue(server.servedSubtitleSourceIds.contains("high"))
        XCTAssertTrue(server.servedSubtitleSourceIds.allSatisfy { $0 == "high" })
        XCTAssertTrue(server.servedFixtureResourcePaths.contains("fixture_sub_fr.srt"))
        XCTAssertTrue(server.forcedStaticSourceIds.isEmpty)
        XCTAssertEqual(server.directStreamRequestCount, 0)
        let playerAttachment = XCTAttachment(screenshot: app.screenshot())
        playerAttachment.name = "Jellyfin native playback surface"
        playerAttachment.lifetime = .keepAlways
        add(playerAttachment)

        subtitles.tap()
        XCTAssertTrue(app.buttons["French selected source"].waitForExistence(timeout: 10))
    }
    func testSearchCanContinueAfterFirstPageHasNoUsableItems() throws {
        let server = try JellyfinFixtureServer(emptyFirstSearchPage: true)
        try server.start()
        defer { server.stop() }
        let app = XCUIApplication()
        app.launchArguments = [
            "-jellyfin_server", "http://127.0.0.1:\(server.port)",
            "-jellyfin_token", "fixture-token",
            "-jellyfin_userid", "fixture-user",
            "-jellyfin_username", "fixture-user",
        ]
        app.launch()
        defer { app.terminate() }
        let sources = app.buttons.matching(identifier: "Sources").firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        sources.tap()
        let search = app.textFields["Movies, shows, or episodes"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("skipped\n")
        let more = app.buttons["Load more results"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Smoke Feature"].exists)
        more.tap()
        let intermediateFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: more
        )
        wait(for: [intermediateFinished], timeout: 10)
        XCTAssertFalse(app.staticTexts["Smoke Feature"].exists)
        more.tap()
        XCTAssertTrue(app.staticTexts["Smoke Feature"].waitForExistence(timeout: 10))
        XCTAssertFalse(more.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Search continues past unusable first and intermediate pages"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

private final class JellyfinFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let emptyFirstSearchPage: Bool
    private let queue = DispatchQueue(label: "rigel.jellyfin-fixture")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sourceIds: [String] = []
    private var playbackSourceIds: [String] = []
    private var playbackUserIds: [String] = []
    private var staticSourceIds: [String] = []
    private var directStreamRequestTotal = 0
    private var hlsPlaySessionIds: [String] = []
    private var hlsMediaSourceIds: [String] = []
    private var subtitleSourceIds: [String] = []
    private var fixtureResourcePaths: Set<String> = []
    private var fixtureServedHandler: ((String) -> Void)?
    private var rootItemsRequestTotal = 0
    private var sourceRequestHandler: ((String) -> Void)?
    var onSourceRequest: ((String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return sourceRequestHandler
        }
        set {
            lock.lock()
            sourceRequestHandler = newValue
            lock.unlock()
        }
    }
    var onFixtureServed: ((String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fixtureServedHandler
        }
        set {
            lock.lock()
            fixtureServedHandler = newValue
            lock.unlock()
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requestedSourceIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sourceIds
    }
    var playbackRequestSourceIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return playbackSourceIds
    }
    var playbackRequestUserIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return playbackUserIds
    }
    var forcedStaticSourceIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return staticSourceIds
    }
    var directStreamRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return directStreamRequestTotal
    }
    var servedHLSMediaSourceIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hlsMediaSourceIds
    }
    var servedHLSPlaySessionIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hlsPlaySessionIds
    }
    var servedSubtitleSourceIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return subtitleSourceIds
    }
    var servedFixtureResourcePaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return fixtureResourcePaths
    }
    var rootItemsRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rootItemsRequestTotal
    }

    init(emptyFirstSearchPage: Bool = false) throws {
        self.emptyFirstSearchPage = emptyFirstSearchPage
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
        var request = Data()
        let headerEnd = Data([13, 10, 13, 10])
        let lineEnd = Data([13, 10])
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, error == nil, let data, !data.isEmpty else {
                    connection.cancel()
                    return
                }
                request.append(data)
                guard request.count <= 64 * 1024 else {
                    self.send(connection, status: 400, contentType: "text/plain", body: Data())
                    return
                }
                guard let headerRange = request.range(of: headerEnd) else {
                    if complete { connection.cancel() } else { receive() }
                    return
                }
                let headerText = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
                let contentLength = headerText
                    .components(separatedBy: "\r\n")
                    .dropFirst()
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int(String($0.dropFirst("Content-Length:".count)).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard contentLength >= 0 else {
                    self.send(connection, status: 400, contentType: "text/plain", body: Data())
                    return
                }
                let bodyStart = headerRange.upperBound
                let bodyEnd = bodyStart + contentLength
                guard request.count >= bodyEnd else {
                    if complete { connection.cancel() } else { receive() }
                    return
                }
                let body = Data(request[bodyStart..<bodyEnd])
                guard let end = request.range(of: lineEnd),
                      let firstLine = String(bytes: request[..<end.lowerBound], encoding: .utf8)
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
                if method == "GET", url?.path == "/Items",
                   url?.queryItems?.contains(where: { $0.name == "SearchTerm" }) != true {
                    lock.lock()
                    rootItemsRequestTotal += 1
                    lock.unlock()
                }
                switch (method, url?.path) {
                case ("POST", "/Users/AuthenticateByName"):
                    self.send(connection, contentType: "application/json", body: Data(#"{"AccessToken":"fixture-token","User":{"Id":"fixture-user"}}"#.utf8))
                case ("GET", "/UserItems/Resume"):
                    self.send(connection, contentType: "application/json", body: Data(#"{"Items":[{"Id":"resume-1","Name":"Resume Feature","Type":"Movie","IsFolder":false}],"TotalRecordCount":1,"StartIndex":0}"#.utf8))
                case ("GET", "/Shows/NextUp"):
                    self.send(connection, contentType: "application/json", body: Data(#"{"Items":[{"Id":"next-1","Name":"Next Feature","Type":"Episode","IsFolder":false}],"TotalRecordCount":1,"StartIndex":0}"#.utf8))
                case ("GET", "/Items"):
                    if emptyFirstSearchPage, url?.queryItems?.contains(where: { $0.name == "SearchTerm" }) == true {
                        let offset = url?.queryItems?.first(where: { $0.name == "StartIndex" })?.value ?? "0"
                        switch offset {
                        case "0":
                            let skippedItems = Array(repeating: "{}", count: 50).joined(separator: ",")
                            self.send(connection, contentType: "application/json", body: Data(#"{"Items":[\#(skippedItems)],"TotalRecordCount":101,"StartIndex":0}"#.utf8))
                        case "50":
                            self.send(connection, contentType: "application/json", body: Data(#"{"Items":[{}],"StartIndex":50}"#.utf8))
                        case "51":
                            let skippedItems = Array(repeating: "{}", count: 49).joined(separator: ",")
                            self.send(connection, contentType: "application/json", body: Data(#"{"Items":[{"Id":"movie-1","Name":"Smoke Feature","Type":"Movie","IsFolder":false},\#(skippedItems)],"TotalRecordCount":101,"StartIndex":51}"#.utf8))
                        default:
                            self.send(connection, status: 404, contentType: "application/json", body: Data("{}".utf8))
                        }
                        return
                    }
                    self.send(connection, contentType: "application/json", body: Data(#"{"Items":[{"Id":"movie-1","Name":"Smoke Feature","Type":"Movie","IsFolder":false,"ProductionYear":2024}],"TotalRecordCount":1,"StartIndex":0}"#.utf8))
                case ("GET", "/Items/movie-1"):
                    self.send(connection, contentType: "application/json", body: Data(#"{"Id":"movie-1","MediaSources":[{"Id":"low","Name":"720p copy","Container":"mp4","Size":22000,"MediaStreams":[{"Type":"Video","Codec":"h264","Width":640,"Height":360},{"Type":"Audio","Codec":"aac","Channels":2},{"Type":"Subtitle","Index":0,"IsExternal":true,"Language":"eng","DisplayTitle":"English"}]},{"Id":"high","Name":"1080p master","Container":"mkv","Size":41000,"MediaStreams":[{"Type":"Video","Codec":"h264","Width":1280,"Height":720},{"Type":"Audio","Codec":"aac","Channels":2},{"Type":"Subtitle","Index":1,"IsExternal":true,"Language":"fra","DisplayTitle":"French selected source"}]}]}"#.utf8))
                case ("POST", "/Items/movie-1/PlaybackInfo"):
                    guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                          let sourceId = payload["MediaSourceId"] as? String,
                          let userId = payload["UserId"] as? String,
                          sourceId == "low" || sourceId == "high"
                    else {
                        self.send(connection, status: 400, contentType: "application/json", body: Data("{}".utf8))
                        return
                    }
                    lock.lock()
                    sourceIds.append(sourceId)
                    playbackSourceIds.append(sourceId)
                    playbackUserIds.append(userId)
                    let callback = sourceRequestHandler
                    lock.unlock()
                    callback?(sourceId)

                    let playSessionId = "fixture-\(sourceId)-session"
                    let isHighVersion = sourceId == "high"
                    let subtitleIndex = isHighVersion ? 1 : 0
                    let subtitleTitle = isHighVersion ? "French selected source" : "English alternate source"
                    let mediaSource: [String: Any] = [
                        "Id": sourceId,
                        "Name": isHighVersion ? "1080p master" : "720p copy",
                        "Container": "m3u8",
                        "SupportsDirectPlay": false,
                        "SupportsDirectStream": false,
                        "SupportsTranscoding": true,
                        "TranscodingUrl": "/fixture_hls/index.m3u8?MediaSourceId=\(sourceId)&PlaySessionId=\(playSessionId)&api_key=fixture-token",
                        "MediaStreams": [
                            ["Type": "Video", "Codec": "h264", "Width": 320, "Height": 180],
                            ["Type": "Audio", "Codec": "aac", "Channels": 2],
                            ["Type": "Subtitle", "Index": subtitleIndex, "IsExternal": true, "DisplayTitle": subtitleTitle],
                        ],
                    ]
                    let response: [String: Any] = ["PlaySessionId": playSessionId, "MediaSources": [mediaSource]]
                    guard let responseBody = try? JSONSerialization.data(withJSONObject: response) else {
                        self.send(connection, status: 500, contentType: "application/json", body: Data("{}".utf8))
                        return
                    }
                    self.send(connection, contentType: "application/json", body: responseBody)
                case ("GET", "/Videos/movie-1/stream"):
                    let sourceId = url?.queryItems?.first(where: { $0.name == "MediaSourceId" })?.value ?? ""
                    let forcedStatic = url?.queryItems?.contains(where: {
                        $0.name.lowercased() == "static" && $0.value?.lowercased() == "true"
                    }) == true
                    lock.lock()
                    sourceIds.append(sourceId)
                    directStreamRequestTotal += 1
                    if forcedStatic { staticSourceIds.append(sourceId) }
                    let callback = sourceRequestHandler
                    lock.unlock()
                    callback?(sourceId)
                    if forcedStatic {
                        self.send(connection, status: 401, contentType: "application/json", body: Data("{}".utf8))
                    } else {
                        self.sendFixture(connection, name: "fixture", fileExtension: "mp4", contentType: "video/mp4")
                    }
                case ("GET", "/fixture_hls/index.m3u8"):
                    let sourceId = url?.queryItems?.first(where: { $0.name == "MediaSourceId" })?.value
                    let sessionId = url?.queryItems?.first(where: { $0.name == "PlaySessionId" })?.value
                    lock.lock()
                    let expectedSourceId = playbackSourceIds.last
                    let expectedSessionId = expectedSourceId.map { "fixture-\($0)-session" }
                    let matchesSelectedPlayback = sourceId == expectedSourceId && sessionId == expectedSessionId
                    lock.unlock()
                    guard matchesSelectedPlayback, let sourceId, let sessionId else {
                        self.send(connection, status: 401, contentType: "application/json", body: Data("{}".utf8))
                        return
                    }
                    lock.lock()
                    hlsMediaSourceIds.append(sourceId)
                    hlsPlaySessionIds.append(sessionId)
                    lock.unlock()
                    self.sendFixture(connection, name: "index", fileExtension: "m3u8", subdirectory: "fixture_hls", contentType: "application/vnd.apple.mpegurl")
                case ("GET", "/fixture_hls/fixture.mp4"):
                    self.sendFixture(connection, name: "fixture", fileExtension: "mp4", contentType: "video/mp4")
                case ("GET", "/fixture_hls/seg000.ts"):
                    self.sendFixture(connection, name: "seg000", fileExtension: "ts", subdirectory: "fixture_hls", contentType: "video/mp2t")
                case ("GET", "/fixture_hls/seg001.ts"):
                    self.sendFixture(connection, name: "seg001", fileExtension: "ts", subdirectory: "fixture_hls", contentType: "video/mp2t")
                case ("GET", "/Videos/movie-1/high/Subtitles/1/Stream.vtt"):
                    lock.lock()
                    subtitleSourceIds.append("high")
                    lock.unlock()
                    self.sendFixture(connection, name: "fixture_sub_fr", fileExtension: "srt", contentType: "text/vtt", convertSRTToVTT: true)
                case ("GET", "/Videos/movie-1/low/Subtitles/0/Stream.vtt"):
                    lock.lock()
                    subtitleSourceIds.append("low")
                    lock.unlock()
                    self.sendFixture(connection, name: "fixture_sub_en", fileExtension: "srt", contentType: "text/vtt", convertSRTToVTT: true)
                default:
                    self.send(connection, status: 404, contentType: "application/json", body: Data("{}".utf8))
                }
            }
        }
        receive()
    }

    private func sendFixture(
        _ connection: NWConnection,
        name: String,
        fileExtension: String,
        subdirectory: String? = nil,
        contentType: String,
        convertSRTToVTT: Bool = false
    ) {
        let bundle = Bundle(for: JellyfinWorkflowUITests.self)
        let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: fileExtension)
        guard let url, let fixtureBody = try? Data(contentsOf: url) else {
            send(connection, status: 404, contentType: "application/json", body: Data("{}".utf8))
            return
        }
        var body = fixtureBody
        if convertSRTToVTT {
            guard let subtitleText = String(data: fixtureBody, encoding: .utf8) else {
                send(connection, status: 500, contentType: "text/plain", body: Data())
                return
            }
            let subtitleCues = subtitleText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { line in
                    line.contains("-->") ? line.replacingOccurrences(of: ",", with: ".") : line
                }
                .joined(separator: "\n")
            body = Data("WEBVTT\n\n\(subtitleCues)".utf8)
        }
        let resourcePath = [subdirectory, "\(name).\(fileExtension)"]
            .compactMap { $0 }
            .joined(separator: "/")
        lock.lock()
        fixtureResourcePaths.insert(resourcePath)
        let callback = fixtureServedHandler
        lock.unlock()
        send(connection, contentType: contentType, body: body)
        callback?(resourcePath)
    }


    private func send(_ connection: NWConnection, status: Int = 200, contentType: String, body: Data) {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 500: phrase = "Internal Server Error"
        default: phrase = "Not Found"
        }
        var response = Data("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum FixtureServerError: Error {
        case notReady
    }
}
