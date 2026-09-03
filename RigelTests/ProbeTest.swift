import XCTest
import ComposeApp

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

    func testHardwareFramesContextUsesBufferData() {
        let size = MemoryLayout<AVHWFramesContext>.size
        guard let frames = av_buffer_alloc(size) else {
            return XCTFail("buffer allocation failed")
        }
        let framesRef = frames
        defer {
            var pointer: UnsafeMutablePointer<AVBufferRef>? = framesRef
            av_buffer_unref(&pointer)
        }

        guard let context = RigelHlsExporter.configureHardwareFramesContext(
            frames,
            width: 1_920,
            height: 1_080
        ) else {
            return XCTFail("hardware frames context data missing")
        }
        XCTAssertEqual(context.pointee.width, 1_920)
        XCTAssertEqual(context.pointee.height, 1_080)
        XCTAssertEqual(context.pointee.sw_format, AV_PIX_FMT_NV12)
        XCTAssertNotEqual(
            UnsafeMutableRawPointer(frames),
            UnsafeMutableRawPointer(context)
        )
    }

    func testTranscodeSessionProducesVideo() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let sessionId = "test-transcode-\(UUID().uuidString)"
        let finished = expectation(description: "transcode session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "transcode",
            startOffsetMs: 0,
            subtitleTracks: [],
            onReady: { path, message in
                readyPath = path
                error = message
                finished.fulfill()
            },
            onError: { message in
                error = message
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 10)
        RigelHlsExporter.stopSession(sessionId: sessionId)

        XCTAssertNotNil(readyPath, error ?? "transcode session did not produce a playlist")
        XCTAssertNil(error)
    }

    func testMultiAudioRemuxPublishesAlternateAudioMaster() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture_multi", withExtension: "mkv"))
        let sessionId = "test-multi-audio-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer {
            RigelHlsExporter.stopSession(sessionId: sessionId)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let finished = expectation(description: "multi-audio session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 0,
            subtitleTracks: [],
            onReady: { path, message in
                readyPath = path
                error = message
                finished.fulfill()
            },
            onError: { message in
                error = message
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 15)

        XCTAssertEqual(readyPath, "\(sessionId)/index.m3u8", error ?? "multi-audio session did not produce a playlist")
        XCTAssertNil(error)
        let master = try String(contentsOf: outputDir.appendingPathComponent("index.m3u8"), encoding: .utf8)
        XCTAssertTrue(master.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        XCTAssertTrue(master.contains("LANGUAGE=\"eng\""))
        XCTAssertTrue(master.contains("LANGUAGE=\"fre\""))
        XCTAssertTrue(master.contains("DEFAULT=YES"))
        for variant in 0...2 {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: outputDir.appendingPathComponent("variant_\(variant).m3u8").path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: outputDir.appendingPathComponent("seg\(variant)_00000.ts").path
                )
            )
        }
    }


    func testSubtitleRemuxPublishesSeparateLanguageRenditions() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture_subtitles", withExtension: "mkv"))
        let sessionId = "test-subtitles-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer {
            RigelHlsExporter.stopSession(sessionId: sessionId)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let finished = expectation(description: "subtitle session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 0,
            subtitleTracks: [],
            onReady: { path, message in
                readyPath = path
                error = message
                finished.fulfill()
            },
            onError: { message in
                error = message
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(
            readyPath,
            "\(sessionId)/index.m3u8",
            error ?? "subtitle session did not produce a playlist"
        )
        XCTAssertNil(error)
        let master = try String(contentsOf: outputDir.appendingPathComponent("index.m3u8"), encoding: .utf8)
        XCTAssertEqual(master.components(separatedBy: "TYPE=SUBTITLES").count - 1, 2, master)
        XCTAssertTrue(master.contains("SUBTITLES=\"subs\""), master)
        XCTAssertTrue(master.contains("LANGUAGE=\"eng\""), master)
        XCTAssertTrue(master.contains("LANGUAGE=\"fra\""), master)
        let vttFiles = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix(".vtt") }
        let vttText = try vttFiles
            .map { try String(contentsOf: outputDir.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(vttText.contains("English subtitle"))
        XCTAssertTrue(vttText.contains("Sous-titre français"))
        XCTAssertFalse(vttText.contains("0,0,Default"), vttText)
        let vttPlaylists = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix("_vtt.m3u8") }
        XCTAssertEqual(vttPlaylists.count, 2)
    }

    func testASSSubtitleEventsDiscardFFmpegMetadata() {
        XCTAssertEqual(
            RigelHlsExporter.plainSubtitleText(
                "2,0,Default,,0,0,0,,Hello, world\\NSecond line",
                isASS: true
            ),
            "Hello, world\nSecond line"
        )
        XCTAssertEqual(
            RigelHlsExporter.plainSubtitleText(
                "Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\i1}Styled{\\i0}",
                isASS: true
            ),
            "Styled"
        )
    }

    func testSidecarWebVttPublishesSubtitleRendition() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let sidecar = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture_sidecar", withExtension: "vtt"))
        let sessionId = "test-sidecar-subtitle-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer {
            RigelHlsExporter.stopSession(sessionId: sessionId)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let finished = expectation(description: "sidecar subtitle session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 0,
            subtitleTracks: [
                SubtitleTrack(
                    url: sidecar.absoluteString,
                    language: "eng",
                    title: "Sidecar"
                )
            ],
            onReady: { path, message in
                readyPath = path
                error = message
                finished.fulfill()
            },
            onError: { message in
                error = message
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(readyPath, "\(sessionId)/index.m3u8", error ?? "sidecar subtitle session failed")
        XCTAssertNil(error)
        let master = try String(contentsOf: outputDir.appendingPathComponent("index.m3u8"), encoding: .utf8)
        XCTAssertTrue(master.contains("TYPE=SUBTITLES"))
        XCTAssertTrue(master.contains("LANGUAGE=\"eng\""))
    }

    func testSelectedSidecarPrecedesEmbeddedRenditions() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture_subtitles", withExtension: "mkv"))
        let sidecar = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture_sidecar", withExtension: "vtt"))
        let sessionId = "test-selected-sidecar-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer {
            RigelHlsExporter.stopSession(sessionId: sessionId)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let finished = expectation(description: "selected sidecar session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 0,
            subtitleTracks: [
                SubtitleTrack(
                    url: sidecar.absoluteString,
                    language: "eng",
                    title: "Selected sidecar"
                )
            ],
            onReady: { path, message in
                readyPath = path
                error = message
                finished.fulfill()
            },
            onError: { message in
                error = message
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(readyPath, "\(sessionId)/index.m3u8", error ?? "selected sidecar session failed")
        XCTAssertNil(error)
        let master = try String(contentsOf: outputDir.appendingPathComponent("index.m3u8"), encoding: .utf8)
        XCTAssertEqual(master.components(separatedBy: "TYPE=SUBTITLES").count - 1, 3, master)
        XCTAssertTrue(master.contains("NAME=\"RigelSelected__Selected_sidecar\""), master)
        let selectedNameOffset = try XCTUnwrap(master.range(of: "NAME=\"RigelSelected__Selected_sidecar\"")?.lowerBound)
        let englishNameOffset = master.range(of: "LANGUAGE=\"eng\"")?.lowerBound
        XCTAssertLessThan(selectedNameOffset, englishNameOffset ?? master.endIndex)
        let vttFiles = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix(".vtt") }
        let vttText = try vttFiles
            .map { try String(contentsOf: outputDir.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(vttText.contains("Sidecar subtitle"), vttText)
    }

    func testInvalidSelectedSidecarFailsSession() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let missingSidecar = URL(fileURLWithPath: "/tmp/rigel-missing-selected-\(UUID().uuidString).srt")
        let sessionId = "test-invalid-selected-sidecar-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer {
            RigelHlsExporter.stopSession(sessionId: sessionId)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let finished = expectation(description: "invalid selected sidecar session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 0,
            subtitleTracks: [SubtitleTrack(url: missingSidecar.absoluteString, language: nil, title: nil)],
            onReady: { path, message in
                readyPath = path
                error = message
                finished.fulfill()
            },
            onError: { message in
                error = message
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 20)

        XCTAssertNil(readyPath)
        XCTAssertEqual(error, "Could not prepare the selected subtitle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("index.m3u8").path))
    }

    func testSidecarSubtitleTimestampsShiftWithSeekOffset() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let sidecar = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture_sidecar", withExtension: "vtt"))
        let sessionId = "test-sidecar-offset-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer {
            RigelHlsExporter.stopSession(sessionId: sessionId)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let finished = expectation(description: "offset sidecar session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 500,
            subtitleTracks: [
                SubtitleTrack(
                    url: sidecar.absoluteString,
                    language: "eng",
                    title: "Sidecar"
                )
            ],
            onReady: { path, message in
                readyPath = path
                error = message
                finished.fulfill()
            },
            onError: { message in
                error = message
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(readyPath, "\(sessionId)/index.m3u8", error ?? "offset sidecar session failed")
        XCTAssertNil(error)
        // The cue spans 0–1s in the sidecar file; a 500 ms seek must shift
        // its end to 0.5s instead of leaving it at 1s (absolute time).
        let vttFiles = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix(".vtt") }
        let vttText = try vttFiles
            .map { try String(contentsOf: outputDir.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(vttText.contains("Sidecar subtitle"), vttText)
        // Unshifted absolute end (1s) must not survive a 500 ms seek; the
        // muxer re-anchors relative to the keyframe it seeks to, so only the
        // absence of the original timestamp is asserted.
        XCTAssertFalse(vttText.contains("00:00:01.000"), vttText)
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
        for pts in [Int64(4_500), 9_000, 13_500] {
            guard let packet = av_packet_alloc() else { return XCTFail("alloc failed") }
            packet.pointee.pts = pts
            packet.pointee.stream_index = 0
            packets.append(packet)
        }
        defer { packets.forEach { var p: UnsafeMutablePointer<AVPacket>? = $0; av_packet_free(&p) } }
        let timeBases: [Int32: AVRational] = [0: timeBase]
        XCTAssertEqual(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBases: timeBases), 4_500)

        for packet in packets {
            packet.pointee.pts = Int64.min
            packet.pointee.dts = Int64.min
        }
        XCTAssertNil(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBases: timeBases))

        packets[0].pointee.duration = 50
        packets[1].pointee.pts = 100
        XCTAssertEqual(
            RigelHlsExporter.audioRingHeadPTS90k(
                packets,
                timeBases: [0: AVRational(num: 1, den: 1_000)]
            ),
            4_500
        )

        XCTAssertNil(RigelHlsExporter.audioRingHeadPTS90k([], timeBases: timeBases))

        packets[0].pointee.pts = Int64.min
        packets[0].pointee.dts = 9_000
        packets[0].pointee.duration = 0
        XCTAssertEqual(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBases: timeBases), 9_000)

        packets[0].pointee.dts = Int64.min
        packets[1].pointee.pts = Int64.min
        packets[1].pointee.dts = Int64.min
        XCTAssertNil(RigelHlsExporter.audioRingHeadPTS90k(packets, timeBases: timeBases))
    }

    func testPrimingReadClassification() {
        guard case .ok = RigelHlsExporter.classifyPrimingRead(0) else { return XCTFail("expected ok") }
        guard case .ok = RigelHlsExporter.classifyPrimingRead(512) else { return XCTFail("expected ok") }
        guard case .eof = RigelHlsExporter.classifyPrimingRead(-541_478_725) else { return XCTFail("expected eof") }
        guard case .again = RigelHlsExporter.classifyPrimingRead(-EAGAIN) else { return XCTFail("expected again") }
        guard case .readError = RigelHlsExporter.classifyPrimingRead(-5) else { return XCTFail("expected readError") }
    }
}
