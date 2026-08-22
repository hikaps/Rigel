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
        func step(_ candidate: Int64?, _ prev: Int64?, _ prevRaw: Int64?, _ offset: Int64, _ fd: Int64)
            -> (repaired: Int64, offset: Int64, lastRaw: Int64?) {
            RigelHlsExporter.repairVideoPTS(
                candidate: candidate,
                previousRepaired: prev,
                previousRaw: prevRaw,
                previousOffset: offset,
                frameDuration: fd
            )
        }
        // 120fps valid cadence (750 ticks) is preserved unchanged.
        var r = step(0, nil, nil, 0, 750)
        XCTAssertEqual(r.repaired, 0)
        r = step(750, 0, 0, 0, 1_500)
        XCTAssertEqual(r.repaired, 750)
        XCTAssertEqual(r.offset, 0)
        // Reviewer's case: 30fps [0, 0, 3100] must become [0, 3000, 6100] —
        // the repair offset carries forward to the next genuine candidate.
        r = step(0, nil, nil, 0, 3_000)
        XCTAssertEqual(r.repaired, 0)
        r = step(0, 0, 0, 0, 3_000)
        XCTAssertEqual(r.repaired, 3_000)
        XCTAssertEqual(r.offset, 3_000)
        XCTAssertEqual(r.lastRaw, 0)
        r = step(3_100, 3_000, 0, 3_000, 3_000)
        XCTAssertEqual(r.repaired, 6_100)
        XCTAssertEqual(r.offset, 3_000)
        // Duplicate timestamps re-space at full duration and re-anchor.
        r = step(6_100, 6_100, 6_100, 3_000, 750)
        XCTAssertEqual(r.repaired, 6_850)
        XCTAssertEqual(r.offset, 750)
        // Missing PTS synthesizes one frame; the next forward raw timestamp
        // must carry that repair offset instead of regressing behind 2250.
        r = step(nil, 1_500, 1_000, 500, 750)
        XCTAssertEqual(r.repaired, 2_250)
        XCTAssertEqual(r.offset, 500)
        XCTAssertEqual(r.lastRaw, 1_000)
        r = step(1_500, 2_250, 1_000, 500, 750)
        XCTAssertEqual(r.repaired, 3_000)
        XCTAssertEqual(r.offset, 1_500)
        XCTAssertEqual(r.lastRaw, 1_500)
    }
    func testSourceFrameRateFallsBackToNominalRate() {
        XCTAssertEqual(
            RigelHlsExporter.sourceFrameRate(
                avg: AVRational(num: 0, den: 0),
                nominal: AVRational(num: 120, den: 1)
            ),
            120
        )
        XCTAssertEqual(
            RigelHlsExporter.sourceFrameRate(
                avg: AVRational(num: 24_000, den: 1_001),
                nominal: AVRational(num: 120, den: 1)
            ),
            24_000.0 / 1_001.0,
            accuracy: 0.0001
        )
    }


    func testAudioRingHeadPTS() {
        let timeBase = AVRational(num: 1, den: 90_000)
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        for (i, pts) in [Int64(4_500), 9_000, 13_500].enumerated() {
            guard let packet = av_packet_alloc() else { return XCTFail("alloc failed") }
            packet.pointee.pts = pts
            packet.pointee.stream_index = Int32(i)
            packets.append(packet)
        }
        defer { packets.forEach { var p: UnsafeMutablePointer<AVPacket>? = $0; av_packet_free(&p) } }
        // Head is the oldest retained packet.
        XCTAssertEqual(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBase: timeBase), 4_500)
        // Both unset yields nil.
        for packet in packets {
            packet.pointee.pts = Int64.min
            packet.pointee.dts = Int64.min
        }
        XCTAssertNil(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBase: timeBase))
        packets[0].pointee.duration = 50
        packets[1].pointee.pts = 100
        XCTAssertEqual(
            RigelHlsExporter.audioRingHeadPTS90k(packets, timeBase: AVRational(num: 1, den: 1_000)),
            4_500
        )
        // Empty ring yields nil.
        XCTAssertEqual(RigelHlsExporter.audioRingHeadPTS90k([], timeBase: timeBase), nil)
        // Missing PTS falls back to DTS so the rebase is not skipped.
        packets[0].pointee.pts = Int64.min
        packets[0].pointee.dts = 9_000
        packets[0].pointee.duration = 0
        XCTAssertEqual(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBase: timeBase), 9_000)
        // Both unset yields nil.
        packets[0].pointee.dts = Int64.min
        packets[1].pointee.pts = Int64.min
        packets[1].pointee.dts = Int64.min
        XCTAssertNil(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBase: timeBase))
    }

    func testPrimingReadClassification() {
        guard case .ok = RigelHlsExporter.classifyPrimingRead(0) else { return XCTFail("expected ok") }
        guard case .ok = RigelHlsExporter.classifyPrimingRead(512) else { return XCTFail("expected ok") }
        guard case .eof = RigelHlsExporter.classifyPrimingRead(-541_478_725) else { return XCTFail("expected eof") }
        guard case .again = RigelHlsExporter.classifyPrimingRead(-EAGAIN) else { return XCTFail("expected again") }
        guard case .readError = RigelHlsExporter.classifyPrimingRead(-5) else { return XCTFail("expected readError") }
    }
}
