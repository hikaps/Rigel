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

    func testFractionalFrameTiming() {
        XCTAssertEqual(RigelHlsExporter.gopFrameCount(forFPS: 24_000.0 / 1_001.0), 96)
        XCTAssertEqual(RigelHlsExporter.gopFrameCount(forFPS: 30_000.0 / 1_001.0), 120)
        XCTAssertEqual(RigelHlsExporter.gopFrameCount(forFPS: 60_000.0 / 1_001.0), 240)

        let encoderTimeBase = AVRational(num: 1, den: 90_000)
        XCTAssertEqual(
            RigelHlsExporter.rescaleVideoPTS(
                1,
                from: AVRational(num: 1_001, den: 24_000),
                to: encoderTimeBase
            ),
            3_754
        )
        XCTAssertEqual(
            RigelHlsExporter.rescaleVideoPTS(Int64.min, from: AVRational(num: 1, den: 1_000), to: encoderTimeBase),
            Int64.min
        )
    }

    func testHighFrameRateTimestampRepairPreservesCadence() {
        // 120fps at 90kHz advances 750 ticks. Valid source timestamps must
        // not be forced to the 60fps synthetic duration of 1,500 ticks.
        XCTAssertEqual(RigelHlsExporter.repairVideoPTS(candidate: 0, previous: nil, frameDuration: 750), 0)
        XCTAssertEqual(RigelHlsExporter.repairVideoPTS(candidate: 750, previous: 0, frameDuration: 1_500), 750)
        XCTAssertEqual(RigelHlsExporter.repairVideoPTS(candidate: 1_500, previous: 750, frameDuration: 1_500), 1_500)
        XCTAssertEqual(RigelHlsExporter.repairVideoPTS(candidate: 700, previous: 1_500, frameDuration: 1_500), 1_501)
        XCTAssertEqual(RigelHlsExporter.repairVideoPTS(candidate: nil, previous: 1_500, frameDuration: 750), 2_250)
    }
}
