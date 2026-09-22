import XCTest
import Network
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

    func testRemuxTimestampsRepairMissingSourceTimes() {
        let first = RigelHlsExporter.repairedRemuxTimestamps(
            pts: Int64.min,
            dts: Int64.min,
            duration: 0,
            nextTimestamp: nil,
            frameDuration: 40
        )
        XCTAssertEqual(first.pts, 0)
        XCTAssertEqual(first.dts, 0)
        XCTAssertEqual(first.nextTimestamp, 40)

        let second = RigelHlsExporter.repairedRemuxTimestamps(
            pts: Int64.min,
            dts: Int64.min,
            duration: 0,
            nextTimestamp: first.nextTimestamp,
            frameDuration: 40
        )
        XCTAssertEqual(second.pts, 40)
        XCTAssertEqual(second.dts, 40)
        XCTAssertEqual(second.nextTimestamp, 80)
    }

    func testRemuxTimestampsPassthroughUntouched() {
        // Well-timestamped sources must pass through byte-identical;
        // only the synthesized next marker advances from the valid tail.
        let passthrough = RigelHlsExporter.repairedRemuxTimestamps(
            pts: 1_000,
            dts: 960,
            duration: 40,
            nextTimestamp: nil,
            frameDuration: 40
        )
        XCTAssertEqual(passthrough.pts, 1_000)
        XCTAssertEqual(passthrough.dts, 960)
        XCTAssertEqual(passthrough.nextTimestamp, 1_040)
    }

    func testRemuxTimestampsSingleSideFallbacks() {
        // Missing PTS falls back to DTS (pts=dts), matching libavformat.
        let ptsMissing = RigelHlsExporter.repairedRemuxTimestamps(
            pts: Int64.min,
            dts: 960,
            duration: 40,
            nextTimestamp: nil,
            frameDuration: 40
        )
        XCTAssertEqual(ptsMissing.pts, 960)
        XCTAssertEqual(ptsMissing.dts, 960)
        XCTAssertEqual(ptsMissing.nextTimestamp, 1_000)

        // Missing DTS mirrors PTS.
        let dtsMissing = RigelHlsExporter.repairedRemuxTimestamps(
            pts: 1_000,
            dts: Int64.min,
            duration: 40,
            nextTimestamp: nil,
            frameDuration: 40
        )
        XCTAssertEqual(dtsMissing.pts, 1_000)
        XCTAssertEqual(dtsMissing.dts, 1_000)
        XCTAssertEqual(dtsMissing.nextTimestamp, 1_040)

        // A real packet duration prefers itself over the frame-rate step.
        let longDuration = RigelHlsExporter.repairedRemuxTimestamps(
            pts: Int64.min,
            dts: Int64.min,
            duration: 80,
            nextTimestamp: nil,
            frameDuration: 40
        )
        XCTAssertEqual(longDuration.pts, 0)
        XCTAssertEqual(longDuration.dts, 0)
        XCTAssertEqual(longDuration.nextTimestamp, 80)
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

        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        let completed = expectation(description: "local proxy reaches ENDLIST")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let media = (try? FileManager.default.contentsOfDirectory(
                    at: outputDir,
                    includingPropertiesForKeys: nil
                ))?
                    .filter { $0.pathExtension == "m3u8" }
                    .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                    .filter { $0.contains("#EXTINF") } ?? []
                if !media.isEmpty, media.allSatisfy({ $0.contains("#EXT-X-ENDLIST") }) {
                    completed.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [completed], timeout: 10)

        let mediaPlaylists = try FileManager.default.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == "m3u8" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .filter { $0.contains("#EXTINF") }
        XCTAssertFalse(mediaPlaylists.isEmpty)
        XCTAssertTrue(mediaPlaylists.allSatisfy { $0.contains("#EXT-X-PLAYLIST-TYPE:EVENT") })
        XCTAssertTrue(mediaPlaylists.allSatisfy { !$0.contains("#EXT-X-PLAYLIST-TYPE:VOD") })

        RigelHlsExporter.stopSession(sessionId: sessionId)
        XCTAssertNotNil(readyPath, error ?? "transcode session did not produce a playlist")
        XCTAssertNil(error)
    }
    func testHlsSessionIdsRejectPathTraversal() {
        XCTAssertTrue(RigelHlsExporter.isValidSessionId("session-abc_123"))
        XCTAssertFalse(RigelHlsExporter.isValidSessionId("../escape"))
        XCTAssertFalse(RigelHlsExporter.isValidSessionId("nested/path"))
        XCTAssertFalse(RigelHlsExporter.isValidSessionId("session%2Fescape"))
    }

    func testDuplicateHlsSessionIdIsRejected() throws {
        let sessionId = "test-duplicate-\(UUID().uuidString)"
        let queue = DispatchQueue(label: "rigel-test-existing-session")
        let existing = RigelHlsExporter.Session(
            queue: queue,
            startOffsetMs: 0,
            subtitleTracks: [],
            waitForCompletion: false
        )
        RigelHlsExporter.lock.lock()
        RigelHlsExporter.sessions[sessionId] = existing
        RigelHlsExporter.lock.unlock()
        defer {
            RigelHlsExporter.lock.lock()
            RigelHlsExporter.sessions.removeValue(forKey: sessionId)
            RigelHlsExporter.lock.unlock()
        }

        let rejected = expectation(description: "duplicate HLS session is rejected")
        var readyPath: String?
        var error: String?
        RigelHlsExporter.startSession(
            sessionId: sessionId.uppercased(),
            sourceUrl: "file:///does-not-run",
            headers: [:],
            mode: "transcode",
            startOffsetMs: 0,
            subtitleTracks: [],
            onReady: { path, message in
                readyPath = path
                error = message
                rejected.fulfill()
            },
            onError: { message in
                error = message
                rejected.fulfill()
            }
        )
        wait(for: [rejected], timeout: 2)

        XCTAssertNil(readyPath)
        XCTAssertEqual(error, "HLS session is already active")
    }
    func testStoppingSessionReservesIdUntilCleanup() {
        let sessionId = "test-cleanup-reservation-\(UUID().uuidString)"
        let queue = DispatchQueue(label: "rigel-test-cleanup-reservation")
        queue.suspend()
        let existing = RigelHlsExporter.Session(
            queue: queue,
            startOffsetMs: 0,
            subtitleTracks: [],
            waitForCompletion: false
        )
        RigelHlsExporter.lock.lock()
        RigelHlsExporter.sessions[sessionId] = existing
        RigelHlsExporter.lock.unlock()

        RigelHlsExporter.stopSession(sessionId: sessionId)
        let rejected = expectation(description: "cleanup-pending HLS session is reserved")
        var error: String?
        RigelHlsExporter.startSession(
            sessionId: sessionId.uppercased(),
            sourceUrl: "file:///does-not-run",
            headers: [:],
            mode: "transcode",
            startOffsetMs: 0,
            subtitleTracks: [],
            onReady: { path, message in
                XCTAssertNil(path)
                error = message
                rejected.fulfill()
            },
            onError: { message in
                error = message
                rejected.fulfill()
            }
        )
        wait(for: [rejected], timeout: 2)
        XCTAssertEqual(error, "HLS session is already active")

        queue.resume()
        queue.sync {}
    }
    func testAirPlayProxyPublishesFiniteVODPlaylist() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let sessionId = "test-airplay-vod-\(UUID().uuidString)"
        let finished = expectation(description: "AirPlay VOD session finishes")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "transcode",
            startOffsetMs: 0,
            subtitleTracks: [],
            waitForCompletion: true,
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
        defer { RigelHlsExporter.stopSession(sessionId: sessionId) }

        XCTAssertEqual(readyPath, "\(sessionId)/index.m3u8", error ?? "AirPlay VOD session did not produce a playlist")
        XCTAssertNil(error)

        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        let playlists = try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m3u8" }
        let mediaPlaylists = try playlists.map { try String(contentsOf: $0, encoding: .utf8) }
            .filter { $0.contains("#EXTINF") }

        XCTAssertFalse(mediaPlaylists.isEmpty)
        for playlist in mediaPlaylists {
            XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"), playlist)
            XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"), playlist)
            XCTAssertFalse(playlist.contains("#EXT-X-PLAYLIST-TYPE:EVENT"), playlist)
        }
    }

    func testStopSessionDeletesSessionDirectory() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let sessionId = "test-cleanup-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        let finished = expectation(description: "session delivers playlist")
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
        wait(for: [finished], timeout: 10)
        XCTAssertNotNil(readyPath, error ?? "remux session did not produce a playlist")

        // The writer may still be running; stopping must remove the directory
        // only after run() has finished, and no later than the poll timeout.
        RigelHlsExporter.stopSession(sessionId: sessionId)
        let removed = expectation(description: "session directory removed")
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if !FileManager.default.fileExists(atPath: outputDir.path) {
                timer.invalidate()
                removed.fulfill()
            }
        }
        wait(for: [removed], timeout: 10)
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
        XCTAssertFalse(master.contains("SUBTITLES=\"subs\""), master)
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
        XCTAssertTrue(master.contains("DEFAULT=YES,AUTOSELECT=YES"), master)
        XCTAssertTrue(master.contains("DEFAULT=NO,AUTOSELECT=NO"), master)
        XCTAssertFalse(master.contains("DEFAULT:"), master)
        XCTAssertFalse(master.contains("AUTOSELECT:"), master)
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

    func testHLSPlaylistDurationUsesInvariantDecimalSeparator() {
        let localized = String(format: "%.3f", locale: Locale(identifier: "fr_FR"), 4.25)
        XCTAssertEqual(localized, "4,250")
        XCTAssertEqual(RigelHlsExporter.hlsPlaylistDuration(4.25), "4.250")
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
    func testSidecarPlaylistPreservesLateCueTimeline() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let sidecar = FileManager.default.temporaryDirectory
            .appendingPathComponent("rigel-late-subtitle-\(UUID().uuidString).vtt")
        try """
        WEBVTT

        00:00:10.000 --> 00:00:12.000 position:20% align:start
        First late cue

        00:00:30.000 --> 00:00:32.000
        Second late cue
        """.write(to: sidecar, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let sessionId = "test-late-sidecar-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer {
            RigelHlsExporter.stopSession(sessionId: sessionId)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let finished = expectation(description: "late sidecar session becomes ready")
        var readyPath: String?
        var error: String?
        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 0,
            subtitleTracks: [SubtitleTrack(url: sidecar.absoluteString, language: "eng", title: "Late")],
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
        XCTAssertEqual(readyPath, "\(sessionId)/index.m3u8", error ?? "late sidecar session failed")
        XCTAssertNil(error)

        let finalized = expectation(description: "late sidecar playlist finalizes")
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard let playlist = try? String(
                contentsOf: outputDir.appendingPathComponent("subtitle_0_vtt.m3u8"),
                encoding: .utf8
            ) else { return }
            guard playlist.contains("#EXT-X-ENDLIST") else { return }
            timer.invalidate()
            finalized.fulfill()
        }
        wait(for: [finalized], timeout: 20)

        let playlist = try String(
            contentsOf: outputDir.appendingPathComponent("subtitle_0_vtt.m3u8"),
            encoding: .utf8
        )
        let durations = playlist.components(separatedBy: .newlines).compactMap { line -> Double? in
            guard line.hasPrefix("#EXTINF:") else { return nil }
            return Double(line.dropFirst(8).split(separator: ",").first ?? "")
        }
        XCTAssertEqual(durations.count, 8)
        XCTAssertEqual(Int(durations.reduce(0, +).rounded()), 32)
        XCTAssertLessThanOrEqual(durations.max() ?? .infinity, 4)
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:4"))
        let vttText = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix(".vtt") }
            .map { try String(contentsOf: outputDir.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(vttText.contains("X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0"), vttText)
        XCTAssertTrue(vttText.contains("00:00:10.000 --> 00:00:12.000"), vttText)
        XCTAssertTrue(vttText.contains("position:20% align:start"), vttText)
        XCTAssertTrue(vttText.contains("00:00:30.000 --> 00:00:32.000"), vttText)
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
        let files = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
        let videoSegments = files.filter {
            $0.hasPrefix("seg0_") && $0.hasSuffix(".ts")
        }
        XCTAssertFalse(videoSegments.isEmpty, "video must be emitted once")
        let subtitlePlaylists = files.filter {
            $0.hasPrefix("subtitle_") && $0.hasSuffix("_vtt.m3u8")
        }
        XCTAssertEqual(subtitlePlaylists.count, 3)
        for playlistName in subtitlePlaylists {
            let playlist = try String(
                contentsOf: outputDir.appendingPathComponent(playlistName),
                encoding: .utf8
            )
            let mediaFiles = playlist.components(separatedBy: .newlines).filter {
                !$0.isEmpty && !$0.hasPrefix("#")
            }
            XCTAssertFalse(mediaFiles.isEmpty, playlistName)
            for mediaFile in mediaFiles {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: outputDir.appendingPathComponent(mediaFile).path
                    ),
                    "\(playlistName) references missing \(mediaFile)"
                )
            }
        }
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

    func testInputWatchdogDeadlineSemantics() {
        let watchdog = InputWatchdog(timeoutSeconds: 1)
        XCTAssertFalse(watchdog.shouldAbort(), "fresh open budget must not abort")
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(watchdog.shouldAbort(), "open budget must expire")

        watchdog.startReading()
        XCTAssertFalse(watchdog.shouldAbort(), "reading resets the budget")
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(watchdog.shouldAbort(), "a read stalled past the budget must abort")

        watchdog.touch()
        XCTAssertFalse(watchdog.shouldAbort(), "touch must refresh the read budget")
    }

    func testExportPacingDecision() {
        XCTAssertFalse(
            RigelHlsExporter.shouldPace(exportedUs: 90_000_000, playheadMs: -1, playheadAgeSeconds: 1),
            "unknown playhead keeps free-run"
        )
        XCTAssertFalse(
            RigelHlsExporter.shouldPace(exportedUs: 90_000_000, playheadMs: 10_000, playheadAgeSeconds: nil),
            "missing freshness keeps free-run"
        )
        XCTAssertFalse(
            RigelHlsExporter.shouldPace(exportedUs: 90_000_000, playheadMs: 10_000, playheadAgeSeconds: 16),
            "stale playhead keeps free-run"
        )
        XCTAssertFalse(
            RigelHlsExporter.shouldPace(exportedUs: 25_000_000, playheadMs: 10_000, playheadAgeSeconds: 1),
            "within the run-ahead limit keeps exporting"
        )
        XCTAssertTrue(
            RigelHlsExporter.shouldPace(exportedUs: 90_000_000, playheadMs: 10_000, playheadAgeSeconds: 1),
            "far ahead of a fresh playhead must idle"
        )
    }

    /// Sidecar URLs arrive percent-encoded (absoluteString); FFmpeg cannot
    /// open them that way, so the exporter must resolve file URLs to paths.
    func testSidecarFileURLPercentEscapesAreDecoded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pct-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("EN 23.976 sidecar.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8).write(to: fileURL)
        XCTAssertTrue(fileURL.absoluteString.contains("%20"), fileURL.absoluteString)

        var fmt: UnsafeMutablePointer<AVFormatContext>? = nil
        let watchdog = InputWatchdog(timeoutSeconds: 10)
        let opened = RigelHlsExporter.openSidecarInput(
            url: fileURL.absoluteString,
            headers: [:],
            watchdog: watchdog,
            fmt: &fmt
        )
        RigelHlsExporter.closeInput(&fmt)
        XCTAssertTrue(opened, "exporter must open percent-encoded file URLs: \(fileURL.absoluteString)")
    }

    /// A sidecar source whose server accepts the connection and then stalls
    /// must fail the session within the watchdog budget, never hang it.
    func testStalledSidecarSourceFailsSession() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "mp4"))
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "stall server ready")
        var port: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                port = listener.port?.rawValue ?? 0
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            // Intentionally never reads or replies: the stall is the point.
        }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        defer { listener.cancel() }

        let sessionId = "test-stalled-sidecar-\(UUID().uuidString)"
        let outputDir = RigelHlsExporter.sessionDir(sessionId: sessionId)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let finished = expectation(description: "stalled sidecar session settles")
        var readyPath: String?
        var error: String?

        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: fixture.absoluteString,
            headers: [:],
            mode: "remux",
            startOffsetMs: 0,
            subtitleTracks: [SubtitleTrack(url: "http://127.0.0.1:\(port)/stalled.srt", language: "eng", title: "Stalled")],
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
        // Watchdog budget is 10s; allow generous slack before declaring a hang.
        wait(for: [finished], timeout: 20)
        RigelHlsExporter.stopSession(sessionId: sessionId)

        XCTAssertNil(readyPath, "a stalled sidecar must not publish a playlist")
        XCTAssertEqual(error, "Could not prepare the selected subtitle")
    }
}
