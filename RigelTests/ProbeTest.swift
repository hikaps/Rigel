import XCTest
@testable import Rigel

final class ProbeTest: XCTestCase {
    func testProbeMp4H264Aac() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let (result, error) = RigelProbe.probe(url: url.absoluteString, headers: [:])
        XCTAssertNil(error, "probe error: \(error ?? "")")
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.container, "mp4")
        XCTAssertEqual(r.videoCodec, "h264")
        XCTAssertTrue(r.audioCodecs.contains("aac"), "audio codecs: \(r.audioCodecs)")
    }

    func testProbeMkvDts() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture_dts", withExtension: "mkv"))
        let (result, error) = RigelProbe.probe(url: url.absoluteString, headers: [:])
        XCTAssertNil(error, "probe error: \(error ?? "")")
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.container, "matroska")
        XCTAssertEqual(r.videoCodec, "h264")
        XCTAssertTrue(r.audioCodecs.contains("dts"), "audio codecs: \(r.audioCodecs)")
    }
}
