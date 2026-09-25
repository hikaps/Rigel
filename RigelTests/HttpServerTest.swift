import XCTest
@testable import Rigel

final class HttpServerTest: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rigel-http-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("a", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)
            .write(to: tempRoot.appendingPathComponent("a/index.m3u8"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testServePlaylistContentType() throws {
        let url = try XCTUnwrap(RigelHttpServer.resolve(root: tempRoot, path: "/a/index.m3u8"))
        XCTAssertEqual(RigelHttpServer.contentType(for: url), "application/vnd.apple.mpegurl")
    }

    func testResolveRejectsTraversal() {
        XCTAssertNil(RigelHttpServer.resolve(root: tempRoot, path: "/../etc/passwd"))
        XCTAssertNil(RigelHttpServer.resolve(root: tempRoot, path: "/a/../../secret"))
        XCTAssertNil(RigelHttpServer.resolve(root: tempRoot, path: "/missing/file.ts"))
    }

    func testResolveRejectsDirectory() {
        XCTAssertNil(RigelHttpServer.resolve(root: tempRoot, path: "/a"))
    }

    func testContentTypeMap() {
        XCTAssertEqual(RigelHttpServer.contentType(for: URL(fileURLWithPath: "/x/y.ts")), "video/mp2t")
        XCTAssertEqual(RigelHttpServer.contentType(for: URL(fileURLWithPath: "/x/y.vtt")), "text/vtt")
        XCTAssertEqual(RigelHttpServer.contentType(for: URL(fileURLWithPath: "/x/y.mp4")), "video/mp4")
    }

    func testParseRequest() {
        let get = RigelHttpServer.parseRequest(
            Data("GET /s/x/index.m3u8 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        )
        XCTAssertEqual(get?.path, "/s/x/index.m3u8")
        XCTAssertEqual(get?.isHead, false)
        XCTAssertEqual(get?.keepAlive, true, "HTTP/1.1 defaults to keep-alive")
        XCTAssertNil(get?.rangeStart)

        let head = RigelHttpServer.parseRequest(
            Data("HEAD /s/x/seg0.ts HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        )
        XCTAssertEqual(head?.isHead, true)
        XCTAssertEqual(head?.path, "/s/x/seg0.ts")

        XCTAssertNil(RigelHttpServer.parseRequest(Data("POST / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(RigelHttpServer.parseRequest(Data("GET / HTTP/1.1\r\n\r\n".utf8).prefix(3)))
    }

    func testParseRequestRangeHeader() {
        func rangeStart(_ request: String) -> Int64? {
            RigelHttpServer.parseRequest(Data(request.utf8))?.rangeStart
        }
        XCTAssertEqual(rangeStart("GET /f HTTP/1.1\r\nRange: bytes=100-\r\n\r\n"), 100)
        XCTAssertEqual(rangeStart("GET /f HTTP/1.1\r\nRange: bytes=0-99\r\n\r\n"), 0)
        XCTAssertNil(rangeStart("GET /f HTTP/1.1\r\nRange: items=0-5\r\n\r\n"), "non-byte units are ignored")
        XCTAssertNil(rangeStart("GET /f HTTP/1.1\r\nRange: bytes=abc-\r\n\r\n"))
    }

    func testParseRequestKeepAliveHeader() {
        func keepAlive(_ request: String) -> Bool? {
            RigelHttpServer.parseRequest(Data(request.utf8))?.keepAlive
        }
        XCTAssertEqual(keepAlive("GET /f HTTP/1.1\r\nConnection: close\r\n\r\n"), false)
        XCTAssertEqual(keepAlive("GET /f HTTP/1.0\r\n\r\n"), false, "HTTP/1.0 defaults to close")
        XCTAssertEqual(keepAlive("GET /f HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"), true)
    }

    func testRangeBounds() {
        XCTAssertEqual(RigelHttpServer.rangeBounds(start: 0, fileSize: 100)?.end, 99)
        XCTAssertEqual(RigelHttpServer.rangeBounds(start: 99, fileSize: 100)?.start, 99)
        XCTAssertNil(RigelHttpServer.rangeBounds(start: 100, fileSize: 100), "start at EOF is unsatisfiable")
        XCTAssertNil(RigelHttpServer.rangeBounds(start: 5, fileSize: 0), "empty file has no range")
        XCTAssertNil(RigelHttpServer.rangeBounds(start: -1, fileSize: 100))
    }

    func testFramerHandlesFragmentationBodyAndPipelinedLeftover() {
        var framer = RigelHTTPFramer()
        let first = Data("GET /ctl HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let second = Data("GET /rootDesc.xml HTTP/1.1\r\n\r\n".utf8)

        guard case .needMore = framer.append(Data(first.prefix(19))) else {
            return XCTFail("fragmented header must wait for the delimiter")
        }
        var remainder = Data(first.dropFirst(19))
        remainder.append(second)
        guard case .frame(let firstFrame) = framer.append(remainder) else {
            return XCTFail("complete body should produce one frame")
        }
        XCTAssertEqual(String(data: firstFrame.body, encoding: .utf8), "hello")
        XCTAssertEqual(RigelHttpServer.parseRequest(firstFrame.head)?.path, "/ctl")

        guard case .frame(let secondFrame) = framer.next() else {
            return XCTFail("pipelined bytes must remain buffered")
        }
        XCTAssertEqual(RigelHttpServer.parseRequest(secondFrame.head)?.path, "/rootDesc.xml")
    }

    func testFramerRejectsConflictingAndOversizedContentLengths() {
        var conflicting = RigelHTTPFramer()
        let conflict = Data("POST /ctl HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc".utf8)
        guard case .invalid = conflicting.append(conflict) else {
            return XCTFail("conflicting lengths must be rejected")
        }

        var oversized = RigelHTTPFramer()
        let length = RigelHTTPFramer.maxBodyBytes + 1
        let request = Data("POST /ctl HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8)
        guard case .invalid = oversized.append(request) else {
            return XCTFail("oversized bodies must be rejected before buffering")
        }
    }

}
