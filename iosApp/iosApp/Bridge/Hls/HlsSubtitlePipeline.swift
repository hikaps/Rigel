import Foundation

extension RigelHlsExporter {
    private enum SubtitlePacketResult {
        case cue(SubtitleCue)
        case skipped
        case failed
    }
    static func isBitmapSubtitle(_ id: AVCodecID) -> Bool {
        switch id {
        case AV_CODEC_ID_DVD_SUBTITLE,
             AV_CODEC_ID_DVB_SUBTITLE,
             AV_CODEC_ID_XSUB,
             AV_CODEC_ID_HDMV_PGS_SUBTITLE:
            return true
        default:
            return false
        }
    }

    static func hlsLanguageValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({
            ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) ||
            $0.value == 45
        }) else { return nil }
        return trimmed
    }

    static func streamMapName(_ value: String?, fallback: String) -> String {
        let source = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = source?.isEmpty == false ? source! : fallback
        let sanitized = candidate.unicodeScalars.map { scalar -> String in
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isLower = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            return isUpper || isLower || isDigit || scalar.value == 45 || scalar.value == 95
                ? String(scalar)
                : "_"
        }.joined()
        return sanitized.isEmpty ? fallback : sanitized
    }

    static func makeSubtitleChain(
        inputStream: UnsafeMutablePointer<AVStream>
    ) -> SubtitleChain? {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(decoder) else {
            return nil
        }
        func fail() -> SubtitleChain? {
            var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
            avcodec_free_context(&dec)
            return nil
        }

        let sourceTimeBase = inputStream.pointee.time_base
        let packetTimeBase = sourceTimeBase.num != 0 && sourceTimeBase.den != 0
            ? sourceTimeBase
            : AVRational(num: 1, den: 1_000)
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0 else { return fail() }
        decCtx.pointee.pkt_timebase = packetTimeBase
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { return fail() }
        return SubtitleChain(decCtx: decCtx)
    }

    static func plainSubtitleText(_ value: String, isASS: Bool) -> String {
        let body: String
        if isASS {
            // FFmpeg's SRT and WebVTT decoders expose ASS-compatible events
            // without the Dialogue prefix: readorder,layer,style,speaker,
            // marginL,marginR,marginV,effect,text. Split only that fixed
            // prefix so commas in the subtitle body remain text.
            if value.hasPrefix("Dialogue:") {
                let fields = value.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
                body = fields.count == 10 ? String(fields[9]) : value
            } else {
                let fields = value.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                body = fields.count == 9 ? String(fields[8]) : value
            }
        } else {
            body = value
        }
        return body
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func subtitleText(_ subtitle: AVSubtitle) -> String? {
        guard let rects = subtitle.rects else { return nil }
        var lines: [String] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = rects[index] else { continue }
            let raw: String?
            let isASS: Bool
            if let ass = rect.pointee.ass {
                raw = SubtitleParser.decodeCString(UnsafePointer(ass))
                isASS = true
            } else if let text = rect.pointee.text {
                raw = SubtitleParser.decodeCString(UnsafePointer(text))
                isASS = false
            } else {
                raw = nil
                isASS = false
            }
            if let raw {
                let cleaned = plainSubtitleText(raw, isASS: isASS)
                if !cleaned.isEmpty {
                    lines.append(cleaned)
                }
            }
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    static func makeSubtitleRendition(
        input: SubtitleInput,
        ordinal: Int,
        outDir: URL,
        chain: SubtitleChain?,
        timestampMapMpegTS: Int64,
        isSelectedExternal: Bool
    ) -> SubtitleRendition? {
        guard input.context.pointee.streams[Int(input.streamIndex)] != nil else {
            chain?.release()
            return nil
        }
        let rendition = SubtitleRendition(
            input: input,
            ordinal: ordinal,
            playlistName: "subtitle_\(ordinal)_vtt.m3u8",
            outDir: outDir,
            chain: chain,
            timestampMapMpegTS: timestampMapMpegTS,
            language: input.language,
            title: input.title,
            isSelectedExternal: isSelectedExternal,
            settingsByStartMs: sourceWebVTTSettings(input.sourceURL)
        )
        initializeSubtitlePlaylist(rendition)
        return rendition
    }

    static func writeSubtitlePacket(
        _ rendition: SubtitleRendition,
        packet: UnsafeMutablePointer<AVPacket>,
        sidecarOffsetUs: Int64
    ) {
        guard let inputStream = rendition.input.context.pointee.streams[Int(rendition.input.streamIndex)] else {
            return
        }
        let shiftedPacket = packet
        if rendition.input.sourceID != 0, sidecarOffsetUs > 0,
           packet.pointee.pts != Int64.min {
            let inputTimeBase = subtitleTimeBase(inputStream)
            let offsetInInput = av_rescale_q(
                sidecarOffsetUs,
                AVRational(num: 1, den: AV_TIME_BASE),
                inputTimeBase
            )
            let end = packet.pointee.duration > 0
                ? packet.pointee.pts + packet.pointee.duration
                : packet.pointee.pts
            guard end > offsetInInput else { return }
            shiftedPacket.pointee.pts = max(0, packet.pointee.pts - offsetInInput)
            if shiftedPacket.pointee.dts != Int64.min {
                shiftedPacket.pointee.dts = shiftedPacket.pointee.pts
            }
            if packet.pointee.duration > 0 {
                shiftedPacket.pointee.duration = end - max(offsetInInput, packet.pointee.pts)
            }
        }

        let result: SubtitlePacketResult
        if let chain = rendition.chain {
            result = decodeSubtitleCue(
                chain: chain,
                packet: shiftedPacket,
                inputStream: inputStream
            )
        } else {
            result = rawSubtitleCue(packet: shiftedPacket, inputStream: inputStream)
        }
        switch result {
        case .cue(let cue):
            let originalStartMs = cue.startMs + max(0, sidecarOffsetUs / 1_000)
            let settings = cue.settings
                ?? packetWebVTTSettings(shiftedPacket)
                ?? consumeSourceSettings(at: originalStartMs, from: rendition)
            appendSubtitleCue(
                SubtitleCue(
                    startMs: cue.startMs,
                    endMs: cue.endMs,
                    text: cue.text,
                    settings: settings
                ),
                to: rendition
            )
        case .skipped:
            return
        case .failed:
            rendition.decodeFailed = true
        }
    }

    static func finishSubtitleRendition(_ rendition: SubtitleRendition) {
        guard !rendition.finished else { return }
        rendition.finished = true
        finalizeRemainingPeriods(rendition)
        appendSubtitleEndList(rendition)
    }

    private static func decodeSubtitleCue(
        chain: SubtitleChain,
        packet: UnsafeMutablePointer<AVPacket>,
        inputStream: UnsafeMutablePointer<AVStream>
    ) -> SubtitlePacketResult {
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        let decodeResult = avcodec_decode_subtitle2(
            chain.decCtx,
            &subtitle,
            &gotSubtitle,
            packet
        )
        guard decodeResult >= 0 else {
            avsubtitle_free(&subtitle)
            return .failed
        }
        guard gotSubtitle != 0 else {
            avsubtitle_free(&subtitle)
            return .skipped
        }
        guard let text = subtitleText(subtitle) else {
            avsubtitle_free(&subtitle)
            return .skipped
        }
        defer { avsubtitle_free(&subtitle) }
        let inputTimeBase = subtitleTimeBase(inputStream)
        let inputPTS = packet.pointee.pts != Int64.min
            ? packet.pointee.pts
            : av_rescale_q(subtitle.pts, AVRational(num: 1, den: AV_TIME_BASE), inputTimeBase)
        let startMs = max(
            0,
            av_rescale_q(inputPTS, inputTimeBase, AVRational(num: 1, den: 1_000))
        )
        let durationMs: Int64
        if packet.pointee.duration > 0 {
            durationMs = max(
                1,
                av_rescale_q(packet.pointee.duration, inputTimeBase, AVRational(num: 1, den: 1_000))
            )
        } else {
            durationMs = max(
                1_000,
                Int64(subtitle.end_display_time) - Int64(subtitle.start_display_time)
            )
        }
        return .cue(SubtitleCue(startMs: startMs, endMs: startMs + durationMs, text: text, settings: nil))
    }

    private static func rawSubtitleCue(
        packet: UnsafeMutablePointer<AVPacket>,
        inputStream: UnsafeMutablePointer<AVStream>
    ) -> SubtitlePacketResult {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return .skipped }
        let payload = Data(bytes: data, count: Int(packet.pointee.size))
        guard let raw = String(data: payload, encoding: .utf8) else { return .failed }
        guard let parsed = webVTTPayload(raw) else { return .skipped }
        let inputTimeBase = subtitleTimeBase(inputStream)
        let startMs = packet.pointee.pts == Int64.min
            ? 0
            : max(0, av_rescale_q(packet.pointee.pts, inputTimeBase, AVRational(num: 1, den: 1_000)))
        let durationMs = packet.pointee.duration > 0
            ? max(1, av_rescale_q(packet.pointee.duration, inputTimeBase, AVRational(num: 1, den: 1_000)))
            : 1_000
        return .cue(
            SubtitleCue(
                startMs: startMs,
                endMs: startMs + durationMs,
                text: parsed.text,
                settings: parsed.settings
            )
        )
    }
    private static func sourceWebVTTSettings(_ sourceURL: String?) -> [Int64: [String]] {
        guard let sourceURL,
              let url = URL(string: sourceURL),
              url.isFileURL,
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var result: [Int64: [String]] = [:]
        for line in raw.components(separatedBy: .newlines) where line.contains("-->") {
            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let rhs = parts[1].trimmingCharacters(in: .whitespaces)
            let fields = rhs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count > 1, let startMs = parseVTTTimestamp(start) else { continue }
            result[startMs, default: []].append(String(fields[1]))
        }
        return result
    }

    private static func packetWebVTTSettings(_ packet: UnsafeMutablePointer<AVPacket>) -> String? {
        var size = 0
        guard let data = av_packet_get_side_data(packet, AV_PKT_DATA_WEBVTT_SETTINGS, &size),
              size > 0 else { return nil }
        let bytes = UnsafeBufferPointer(start: data, count: size)
        let value = String(decoding: bytes, as: UTF8.self)
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func consumeSourceSettings(
        at startMs: Int64,
        from rendition: SubtitleRendition
    ) -> String? {
        guard let values = rendition.settingsByStartMs[startMs], !values.isEmpty else { return nil }
        let index = rendition.settingsUseCount[startMs] ?? 0
        guard index < values.count else { return nil }
        rendition.settingsUseCount[startMs] = index + 1
        return values[index]
    }

    private static func parseVTTTimestamp(_ value: String) -> Int64? {
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let hourIndex = parts.count == 3 ? 0 : nil
        let minuteIndex = parts.count == 3 ? 1 : 0
        let secondIndex = parts.count == 3 ? 2 : 1
        let hours = hourIndex.flatMap { Int(parts[$0]) } ?? 0
        guard let minutes = Int(parts[minuteIndex]),
              let seconds = Double(parts[secondIndex]) else { return nil }
        return Int64(((Double(hours * 3600 + minutes * 60) + seconds) * 1000.0).rounded())
    }
    private static func subtitleTimeBase(_ stream: UnsafeMutablePointer<AVStream>) -> AVRational {
        stream.pointee.time_base.num != 0 && stream.pointee.time_base.den != 0
            ? stream.pointee.time_base
            : AVRational(num: 1, den: 1_000)
    }

    private static func webVTTPayload(_ raw: String) -> (text: String, settings: String?)? {
        let lines = raw.components(separatedBy: .newlines)
        let body: [String]
        let settings: String?
        if let timing = lines.firstIndex(where: { $0.contains("-->") }) {
            let timingParts = lines[timing].components(separatedBy: "-->")
            let rhs = timingParts.dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            let fields = rhs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            settings = fields.count > 1 ? String(fields[1]) : nil
            body = Array(lines.dropFirst(timing + 1))
        } else {
            settings = nil
            body = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") }
        }
        let text = body.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, settings)
    }

    private static let subtitleSegmentTargetMs: Int64 = 4_000

    private static func appendSubtitleCue(_ cue: SubtitleCue, to rendition: SubtitleRendition) {
        guard cue.endMs > cue.startMs, !cue.text.isEmpty else { return }
        rendition.pendingCues.append(cue)
        rendition.timelineEndMs = max(rendition.timelineEndMs, cue.endMs)
        rendition.wrotePacket = true
        finalizePeriods(before: cue.startMs, in: rendition)
    }
    static func advanceSubtitleProgress(_ rendition: SubtitleRendition, mediaPositionMs: Int64) {
        let safePosition = max(0, mediaPositionMs)
        finalizePeriods(
            before: max(0, safePosition - subtitleSegmentTargetMs),
            in: rendition
        )
    }
    private static func finalizePeriods(before timestampMs: Int64, in rendition: SubtitleRendition) {
        while rendition.nextPeriodStartMs + subtitleSegmentTargetMs <= timestampMs {
            let periodEnd = rendition.nextPeriodStartMs + subtitleSegmentTargetMs
            guard finalizePeriod(from: rendition.nextPeriodStartMs, to: periodEnd, in: rendition) else {
                return
            }
            rendition.nextPeriodStartMs = periodEnd
            rendition.pendingCues.removeAll { $0.endMs <= periodEnd }
        }
    }
    private static func finalizeRemainingPeriods(_ rendition: SubtitleRendition) {
        while rendition.nextPeriodStartMs < rendition.timelineEndMs {
            let periodEnd = min(
                rendition.timelineEndMs,
                rendition.nextPeriodStartMs + subtitleSegmentTargetMs
            )
            guard finalizePeriod(from: rendition.nextPeriodStartMs, to: periodEnd, in: rendition) else {
                return
            }
            rendition.nextPeriodStartMs = periodEnd
            rendition.pendingCues.removeAll { $0.endMs <= periodEnd }
        }
    }

    private static func finalizePeriod(
        from periodStart: Int64,
        to periodEnd: Int64,
        in rendition: SubtitleRendition
    ) -> Bool {
        let activeCues = rendition.pendingCues.filter {
            $0.startMs < periodEnd && $0.endMs > periodStart
        }
        let map = "X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:\(max(0, rendition.timestampMapMpegTS))"
        var vttLines = ["WEBVTT", map, ""]
        for cue in activeCues {
            let settings = cue.settings.map { " \($0)" } ?? ""
            vttLines.append("\(vttTimestamp(cue.startMs)) --> \(vttTimestamp(cue.endMs))\(settings)")
            vttLines.append(cue.text)
            vttLines.append("")
        }
        let fileName = "subtitle_\(rendition.ordinal)_\(String(format: "%05d", rendition.segments.count)).vtt"
        let fileURL = rendition.outDir.appendingPathComponent(fileName)
        do {
            try (vttLines.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        let duration = Double(periodEnd - periodStart) / 1_000
        guard appendSubtitlePlaylistSegment(
            name: fileName,
            duration: duration,
            to: rendition
        ) else {
            return false
        }
        rendition.segments.append((name: fileName, duration: duration))
        return true
    }

    private static func initializeSubtitlePlaylist(_ rendition: SubtitleRendition) {
        let contents = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
        let url = rendition.outDir.appendingPathComponent(rendition.playlistName)
        subtitlePlaylistLock.lock()
        _ = atomicallyWrite(contents, to: url)
        subtitlePlaylistLock.unlock()
    }

    private static func appendSubtitlePlaylistSegment(
        name: String,
        duration: Double,
        to rendition: SubtitleRendition
    ) -> Bool {
        let url = rendition.outDir.appendingPathComponent(rendition.playlistName)
        let addition = "#EXTINF:\(String(format: "%.3f", duration)),\n\(name)\n"
        subtitlePlaylistLock.lock()
        defer { subtitlePlaylistLock.unlock() }
        guard let file = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? file.close() }
        file.seekToEndOfFile()
        do {
            try file.write(contentsOf: Data(addition.utf8))
            try file.synchronize()
            return true
        } catch {
            return false
        }
    }

    private static func appendSubtitleEndList(_ rendition: SubtitleRendition) {
        let url = rendition.outDir.appendingPathComponent(rendition.playlistName)
        subtitlePlaylistLock.lock()
        defer { subtitlePlaylistLock.unlock() }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        file.seekToEndOfFile()
        try? file.write(contentsOf: Data("#EXT-X-ENDLIST\n".utf8))
        try? file.synchronize()
    }

    private static func atomicallyWrite(_ contents: String, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try contents.write(to: temporary, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    private static func vttTimestamp(_ milliseconds: Int64) -> String {
        let total = max(0, milliseconds)
        let hours = total / 3_600_000
        let minutes = (total / 60_000) % 60
        let seconds = (total / 1_000) % 60
        let millis = total % 1_000
        return String(format: "%02d:%02d:%02d.%03d", Int(hours), Int(minutes), Int(seconds), Int(millis))
    }
}
