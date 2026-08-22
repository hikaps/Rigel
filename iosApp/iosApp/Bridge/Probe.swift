import Foundation
import ComposeApp

/// Stream probing via libavformat. Normalizes container/codec names for
/// FormatRouter (matroska/mp4/m3u8, h264/hevc/dts/...).
final class RigelProbe {
    static func probe(url: String, headers: [String: String]) -> (ProbeResult?, String?) {
        var fmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var result: ProbeResult? = nil
        var error: String? = nil

        url.withCString { cstr in
            var opts: OpaquePointer? = nil
            for (key, value) in headers {
                key.withCString { k in
                    value.withCString { v in
                        av_dict_set(&opts, k, v, 0)
                    }
                }
            }
            var timeoutDict: OpaquePointer? = opts
            let ret = avformat_open_input(&fmt, cstr, nil, &timeoutDict)
            if ret < 0 {
                error = "probe open failed: \(avErrorString(ret))"
                return
            }
            guard let ctx = fmt else {
                error = "probe open failed: no context"
                return
            }
            let infoRet = avformat_find_stream_info(ctx, nil)
            if infoRet < 0 {
                error = "probe stream info failed: \(avErrorString(infoRet))"
                avformat_close_input(&fmt)
                return
            }

            let containerRaw = String(cString: ctx.pointee.iformat.pointee.name)
            var videoCodec: String? = nil
            var audioCodecs: [String] = []
            var subtitleCodecs: [String] = []
            var videoPixFmt: String? = nil
            var videoWidth: Int32 = 0
            var videoHeight: Int32 = 0
            let streamCount = Int(ctx.pointee.nb_streams)
            var selectedVideoIndex: Int?
            var selectedVideoIsDefault = false
            if streamCount > 0 {
                for i in 0..<streamCount {
                    guard let stream = ctx.pointee.streams[i],
                          let codecpar = stream.pointee.codecpar,
                          codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
                    let isAttachedPicture = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
                    guard !isAttachedPicture else { continue }
                    let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
                    if selectedVideoIndex == nil || (isDefault && !selectedVideoIsDefault) {
                        selectedVideoIndex = i
                        selectedVideoIsDefault = isDefault
                    }
                }
            }
            if streamCount > 0 {
                for i in 0..<streamCount {
                    guard let stream = ctx.pointee.streams[i] else { continue }
                    guard let codecpar = stream.pointee.codecpar else { continue }
                    let codecName = codecNameString(codecpar.pointee.codec_id)
                    switch codecpar.pointee.codec_type {
                    case AVMEDIA_TYPE_VIDEO:
                        guard i == selectedVideoIndex else { continue }
                        videoCodec = codecName
                        let pf = AVPixelFormat(rawValue: codecpar.pointee.format)
                        if let name = av_get_pix_fmt_name(pf) {
                            videoPixFmt = String(cString: name)
                        }
                        videoWidth = codecpar.pointee.width
                        videoHeight = codecpar.pointee.height
                    case AVMEDIA_TYPE_AUDIO:
                        audioCodecs.append(codecName)
                    case AVMEDIA_TYPE_SUBTITLE:
                        subtitleCodecs.append(codecName)
                    default:
                        break
                    }
                }
            }

            let durationUs = ctx.pointee.duration
            let durationMs: Int64? = durationUs > 0 ? durationUs / 1000 : nil
            let isLive = durationUs <= 0

            result = ProbeResult(
                container: normalizeContainer(containerRaw),
                videoCodec: normalizeCodec(videoCodec),
                audioCodecs: audioCodecs.map { normalizeCodec($0) ?? "unknown" },
                subtitleCodecs: subtitleCodecs.map { normalizeCodec($0) ?? "unknown" },
                durationMs: durationMs.map { KotlinLong(longLong: $0) },
                isLive: isLive,
                pixFmt: videoPixFmt.flatMap { normalizePixelFormat($0) },
                width: videoWidth,
                height: videoHeight
            )
            avformat_close_input(&fmt)
        }
        return (result, error)
    }

    private static func codecNameString(_ id: AVCodecID) -> String {
        guard let name = avcodec_get_name(id) else { return "unknown" }
        return String(cString: name)
    }

    private static func avErrorString(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        av_strerror(code, &buf, buf.count)
        return String(cString: buf)
    }

    static func normalizeContainer(_ raw: String) -> String {
        switch raw {
        case let s where s.contains("matroska"): return "matroska"
        case let s where s.contains("mov,mp4") || s == "mov" || s == "mp4": return "mp4"
        case let s where s.contains("mpegts"): return "mpegts"
        case let s where s.contains("webm"): return "webm"
        case let s where s == "avi": return "avi"
        case let s where s.contains("hls") || s.contains("applehttp"): return "m3u8"
        default: return raw
        }
    }

    static func normalizeCodec(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "dca": return "dts"
        case "hevc": return "hevc"
        default: return raw.lowercased()
        }
    }

    /// Collapse only explicit YUV/NV12/P010 families. Unknown formats stay
    /// unknown so FormatRouter cannot accidentally grant a direct-play route
    /// (for example, gray10le is not HEVC Main10 4:2:0).
    static func normalizePixelFormat(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower == "nv12" { return "yuv420p" }
        if lower == "p010" || lower == "p010le" || lower == "p010be" {
            return "yuv420p10le"
        }
        guard lower.hasPrefix("yuv") || lower.hasPrefix("yuvj") else { return lower }
        if lower.contains("444") { return "yuv444p" }
        if lower.contains("422") { return "yuv422p" }
        // Planar 4:2:0: preserve bit depth instead of collapsing 12/14/16
        // bit to 8-bit. Big-endian names normalize to the same shape because
        // the router gates chroma and depth, not memory byte order.
        if lower.contains("16") { return "yuv420p16le" }
        if lower.contains("14") { return "yuv420p14le" }
        if lower.contains("12") { return "yuv420p12le" }
        if lower.contains("10") { return "yuv420p10le" }
        if lower.contains("9") { return "yuv420p9le" }
        if lower.contains("420") { return "yuv420p" }
        return lower
    }
}
