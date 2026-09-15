import Foundation

extension RigelHlsExporter {
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
            isSelectedExternal: isSelectedExternal
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

        let cue: SubtitleCue?
        if let chain = rendition.chain {
            cue = decodeSubtitleCue(
                chain: chain,
                packet: shiftedPacket,
                inputStream: inputStream
            )
        } else {
            cue = rawSubtitleCue(packet: shiftedPacket, inputStream: inputStream)
        }
        guard let cue else {
            rendition.decodeFailed = true
            return
        }
        appendSubtitleCue(cue, to: rendition)
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
    ) -> SubtitleCue? {
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        let decodeResult = avcodec_decode_subtitle2(
            chain.decCtx,
            &subtitle,
            &gotSubtitle,
            packet
        )
        guard decodeResult >= 0, gotSubtitle != 0, let text = subtitleText(subtitle) else {
            avsubtitle_free(&subtitle)
            return nil
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
        return SubtitleCue(startMs: startMs, endMs: startMs + durationMs, text: text)
    }

    private static func rawSubtitleCue(
        packet: UnsafeMutablePointer<AVPacket>,
        inputStream: UnsafeMutablePointer<AVStream>
    ) -> SubtitleCue? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let payload = Data(bytes: data, count: Int(packet.pointee.size))
        guard let raw = String(data: payload, encoding: .utf8),
              let text = webVTTText(raw) else {
            return nil
        }
        let inputTimeBase = subtitleTimeBase(inputStream)
        let startMs = packet.pointee.pts == Int64.min
            ? 0
            : max(0, av_rescale_q(packet.pointee.pts, inputTimeBase, AVRational(num: 1, den: 1_000)))
        let durationMs = packet.pointee.duration > 0
            ? max(1, av_rescale_q(packet.pointee.duration, inputTimeBase, AVRational(num: 1, den: 1_000)))
            : 1_000
        return SubtitleCue(startMs: startMs, endMs: startMs + durationMs, text: text)
    }

    private static func subtitleTimeBase(_ stream: UnsafeMutablePointer<AVStream>) -> AVRational {
        stream.pointee.time_base.num != 0 && stream.pointee.time_base.den != 0
            ? stream.pointee.time_base
            : AVRational(num: 1, den: 1_000)
    }

    private static func webVTTText(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines)
        let body: [String]
        if let timing = lines.firstIndex(where: { $0.contains("-->") }) {
            body = Array(lines.dropFirst(timing + 1))
        } else {
            body = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") }
        }
        let text = body.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static let subtitleSegmentTargetMs: Int64 = 4_000

    private static func appendSubtitleCue(_ cue: SubtitleCue, to rendition: SubtitleRendition) {
        guard cue.endMs > cue.startMs, !cue.text.isEmpty else { return }
        rendition.pendingCues.append(cue)
        rendition.timelineEndMs = max(rendition.timelineEndMs, cue.endMs)
        rendition.wrotePacket = true
        finalizePeriods(before: cue.startMs, in: rendition)
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
            vttLines.append("\(vttTimestamp(cue.startMs)) --> \(vttTimestamp(cue.endMs))")
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
        _ = atomicallyWrite(contents, to: url)
    }

    private static func appendSubtitlePlaylistSegment(
        name: String,
        duration: Double,
        to rendition: SubtitleRendition
    ) -> Bool {
        let url = rendition.outDir.appendingPathComponent(rendition.playlistName)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let addition = "#EXTINF:\(String(format: "%.3f", duration)),\n\(name)\n"
        return atomicallyWrite(current + addition, to: url)
    }

    private static func appendSubtitleEndList(_ rendition: SubtitleRendition) {
        let url = rendition.outDir.appendingPathComponent(rendition.playlistName)
        guard let current = try? String(contentsOf: url, encoding: .utf8),
              !current.contains("#EXT-X-ENDLIST") else { return }
        _ = atomicallyWrite(current + "#EXT-X-ENDLIST\n", to: url)
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
