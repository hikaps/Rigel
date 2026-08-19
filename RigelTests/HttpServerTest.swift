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

    func testParseRequestPath() {
        let req = Data("GET /s/x/index.m3u8 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        XCTAssertEqual(RigelHttpServer.parseRequestPath(req), "/s/x/index.m3u8")
        XCTAssertNil(RigelHttpServer.parseRequestPath(Data("POST / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(RigelHttpServer.parseRequestPath(Data("GET / HTTP/1.1\r\n\r\n".utf8).prefix(3)))
    }
}
