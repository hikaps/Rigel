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

    static func writeTranscodedSubtitle(
        chain: SubtitleChain,
        packet: UnsafeMutablePointer<AVPacket>,
        inputStream: UnsafeMutablePointer<AVStream>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
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
            return
        }
        defer { avsubtitle_free(&subtitle) }

        let textData = Data(text.utf8)
        guard textData.count <= Int(Int32.max) else { return }
        var encoded = AVPacket()
        av_init_packet(&encoded)
        guard av_new_packet(&encoded, Int32(textData.count)) >= 0,
              let destination = encoded.data else {
            return
        }
        textData.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(destination, baseAddress, textData.count)
            }
        }
        let inputTimeBase = inputStream.pointee.time_base.num != 0 &&
            inputStream.pointee.time_base.den != 0
            ? inputStream.pointee.time_base
            : AVRational(num: 1, den: 1_000)
        let outputTimeBase = outStream.pointee.time_base.num != 0 &&
            outStream.pointee.time_base.den != 0
            ? outStream.pointee.time_base
            : AVRational(num: 1, den: 1_000)
        let inputPTS = packet.pointee.pts != Int64.min
            ? packet.pointee.pts
            : av_rescale_q(subtitle.pts, AVRational(num: 1, den: AV_TIME_BASE), inputTimeBase)
        encoded.pts = av_rescale_q(inputPTS, inputTimeBase, outputTimeBase)
        encoded.dts = encoded.pts
        if packet.pointee.duration > 0 {
            encoded.duration = av_rescale_q(packet.pointee.duration, inputTimeBase, outputTimeBase)
        } else {
            let displayDuration = Int64(subtitle.end_display_time) -
                Int64(subtitle.start_display_time)
            encoded.duration = max(1, displayDuration)
        }
        encoded.stream_index = outStream.pointee.index
        encoded.pos = -1
        av_interleaved_write_frame(out, &encoded)
        av_packet_unref(&encoded)
    }
}
