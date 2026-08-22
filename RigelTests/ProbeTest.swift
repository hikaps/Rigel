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

    func testPixelFormatNormalization() {
        // 8-bit 4:2:0 family collapses to yuv420p (direct-playable).
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv420p"), "yuv420p")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuvj420p"), "yuv420p")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("nv12"), "yuv420p")
        // 10-bit 4:2:0 (HEVC Main10 surface) stays 10-bit.
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv420p10le"), "yuv420p10le")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv420p10be"), "yuv420p10le")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("p010le"), "yuv420p10le")
        // Bit depth is never collapsed: 9/12/14/16-bit must transcode, and
        // unrelated formats remain unknown instead of becoming 4:2:0.
        XCTAssertEqual(RigelProbe.normalizePixelFormat("gray10le"), "gray10le")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv420p9le"), "yuv420p9le")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv420p12le"), "yuv420p12le")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv420p14le"), "yuv420p14le")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv420p16le"), "yuv420p16le")
        // 4:2:2 / 4:4:4 at any depth must transcode; shape is what matters.
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv422p"), "yuv422p")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv422p10le"), "yuv422p")
        XCTAssertEqual(RigelProbe.normalizePixelFormat("yuv444p10le"), "yuv444p")
    }
}
