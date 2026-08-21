import Foundation

/// Local ffmpeg remux/transcode → HLS session. Writes segments + playlist into
/// Documents/proxy/<sessionId>/ and signals readiness when the playlist exists.
/// REMUX: video stream-copy; audio copy when AAC/MP3/FLAC/ALAC else decode→AAC.
/// TRANSCODE: video decode→VideoToolbox H.264, audio decode→AAC.
final class RigelHlsExporter {
    struct Session {
        let queue: DispatchQueue
        var cancel: Bool = false
    }

    private static var sessions: [String: Session] = [:]
    private static let lock = NSLock()

    private static let passthroughAudio = Set(["aac", "mp3", "flac", "alac"])

    static func sessionDir(sessionId: String) -> URL {
        RigelHttpServer.proxyRootURL().appendingPathComponent(sessionId, isDirectory: true)
    }

    static func startSession(
        sessionId: String,
        sourceUrl: String,
        headers: [String: String],
        mode: String,
        onReady: @escaping (String?, String?) -> Void
    ) {
        let queue = DispatchQueue(label: "rigel-hls-\(sessionId)")
        lock.lock(); sessions[sessionId] = Session(queue: queue); lock.unlock()
        queue.async {
            run(sessionId: sessionId, sourceUrl: sourceUrl, headers: headers, mode: mode, onReady: onReady)
        }
    }

    static func stopSession(sessionId: String) {
        lock.lock(); sessions[sessionId]?.cancel = true; lock.unlock()
    }

    private static func isCancelled(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[sessionId]?.cancel ?? true
    }

    private static func run(
        sessionId: String,
        sourceUrl: String,
        headers: [String: String],
        mode: String,
        onReady: @escaping (String?, String?) -> Void
    ) {
        let outDir = sessionDir(sessionId: sessionId)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let playlistPath = outDir.appendingPathComponent("index.m3u8").path

        var ifmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var ofmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var audioChain: AudioChain? = nil
        var videoChain: VideoChain? = nil
        var notified = false

        defer {
            if !notified {
                DispatchQueue.main.async { onReady(nil, "session ended before playlist was ready") }
            }
            cleanup(ifmt: ifmt, ofmt: ofmt, audio: audioChain, video: videoChain)
            lock.lock(); sessions.removeValue(forKey: sessionId); lock.unlock()
        }

        guard openInput(url: sourceUrl, headers: headers, fmt: &ifmt), let ctx = ifmt else {
            DispatchQueue.main.async { onReady(nil, "failed to open source: \(sourceUrl)") }
            return
        }

        guard avformat_alloc_output_context2(&ofmt, nil, "hls", playlistPath) >= 0, let out = ofmt else {
            DispatchQueue.main.async { onReady(nil, "failed to create HLS output context") }
            return
        }

        av_opt_set(out.pointee.priv_data, "hls_time", "4", 0)
        av_opt_set(out.pointee.priv_data, "hls_list_size", "0", 0)
        av_opt_set(out.pointee.priv_data, "hls_flags", "independent_segments", 0)
        av_opt_set(
            out.pointee.priv_data,
            "hls_segment_filename",
            outDir.appendingPathComponent("seg%05d.ts").path,
            0
        )

        let inCount = Int(ctx.pointee.nb_streams)
        var streamMap: [Int32: Int32] = [:]
        for i in 0..<inCount {
            guard let inStream = ctx.pointee.streams[i], let codecpar = inStream.pointee.codecpar else { continue }
            guard let outStream = avformat_new_stream(out, nil) else { continue }
            let outIndex = outStream.pointee.index
            streamMap[Int32(i)] = outIndex

            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if mode == "remux" || codecpar.pointee.codec_id == AV_CODEC_ID_H264 || codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
                    if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 {
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        outStream.pointee.time_base = inStream.pointee.time_base
                    }
                } else {
                    videoChain = makeVideoChain(inputStream: inStream, outputStream: outStream)
                }
            case AVMEDIA_TYPE_AUDIO:
                if mode == "remux", let name = codecName(codecpar.pointee.codec_id),
                   passthroughAudio.contains(name) {
                    if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 {
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        outStream.pointee.time_base = inStream.pointee.time_base
                    }
                } else {
                    audioChain = makeAudioChain(inputStream: inStream, outputStream: outStream)
                }
            default:
                outStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_UNKNOWN
                outStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_NONE
            }
        }

        let headerRet = avformat_write_header(out, nil)
        guard headerRet >= 0 else {
            DispatchQueue.main.async { onReady(nil, "HLS write header failed: \(avErrorString(headerRet))") }
            return
        }

        var pkt = AVPacket()
        av_init_packet(&pkt)
        while true {
            if isCancelled(sessionId) { break }
            let readRet = av_read_frame(ctx, &pkt)
            if readRet < 0 { break }
            defer { av_packet_unref(&pkt) }

            let inIdx = pkt.stream_index
            guard let outIdx = streamMap[inIdx],
                  let inStream = ctx.pointee.streams[Int(inIdx)],
                  let outStream = out.pointee.streams[Int(outIdx)] else { continue }

            switch inStream.pointee.codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if let chain = videoChain, chain.inputIndex == inIdx {
                    writeTranscodedVideo(chain: chain, packet: &pkt, out: out, outStream: outStream)
                } else {
                    writeRemuxPacket(&pkt, inStream: inStream, outStream: outStream, out: out)
                }
            case AVMEDIA_TYPE_AUDIO:
                if let chain = audioChain, chain.inputIndex == inIdx {
                    writeTranscodedAudio(chain: chain, packet: &pkt, out: out, outStream: outStream)
                } else {
                    writeRemuxPacket(&pkt, inStream: inStream, outStream: outStream, out: out)
                }
            default:
                break
            }

            if !notified && FileManager.default.fileExists(atPath: playlistPath) {
                notified = true
                DispatchQueue.main.async { onReady("\(sessionId)/index.m3u8", nil) }
            }
        }

        av_write_trailer(out)
        if !notified && FileManager.default.fileExists(atPath: playlistPath) {
            notified = true
            DispatchQueue.main.async { onReady("\(sessionId)/index.m3u8", nil) }
        }
    }

    private static func writeRemuxPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        inStream: UnsafeMutablePointer<AVStream>,
        outStream: UnsafeMutablePointer<AVStream>,
        out: UnsafeMutablePointer<AVFormatContext>
    ) {
        pkt.pointee.stream_index = outStream.pointee.index
        av_packet_rescale_ts(pkt, inStream.pointee.time_base, outStream.pointee.time_base)
        pkt.pointee.pos = -1
        av_interleaved_write_frame(out, pkt)
    }

    // MARK: - Audio chain (decode → swresample → AAC)

    private final class AudioChain {
        let inputIndex: Int32
        let decCtx: UnsafeMutablePointer<AVCodecContext>
        let encCtx: UnsafeMutablePointer<AVCodecContext>
        let swr: OpaquePointer
        var nextPts: Int64 = 0

        init(
            inputIndex: Int32,
            decCtx: UnsafeMutablePointer<AVCodecContext>,
            encCtx: UnsafeMutablePointer<AVCodecContext>,
            swr: OpaquePointer
        ) {
            self.inputIndex = inputIndex
            self.decCtx = decCtx
            self.encCtx = encCtx
            self.swr = swr
        }
    }

    private static func makeAudioChain(
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>
    ) -> AudioChain? {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(decoder) else { return nil }
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0,
              avcodec_open2(decCtx, decoder, nil) >= 0 else { return nil }

        guard let aacEncoder = avcodec_find_encoder(AV_CODEC_ID_AAC),
              let encCtx = avcodec_alloc_context3(aacEncoder) else { return nil }
        encCtx.pointee.sample_rate = 48000
        av_channel_layout_default(&encCtx.pointee.ch_layout, 2)
        encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        encCtx.pointee.bit_rate = 256_000
        guard avcodec_open2(encCtx, aacEncoder, nil) >= 0 else { return nil }

        var swr: OpaquePointer? = nil
        var inLayout = decCtx.pointee.ch_layout
        var outLayout = encCtx.pointee.ch_layout
        swr_alloc_set_opts2(
            &swr, &outLayout, AV_SAMPLE_FMT_FLTP, 48000,
            &inLayout, decCtx.pointee.sample_fmt, decCtx.pointee.sample_rate,
            0, nil
        )
        guard let swr, swr_init(swr) >= 0 else { return nil }

        avcodec_parameters_from_context(outputStream.pointee.codecpar, encCtx)
        outputStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        outputStream.pointee.time_base = AVRational(num: 1, den: 48000)

        return AudioChain(inputIndex: inputStream.pointee.index, decCtx: decCtx, encCtx: encCtx, swr: swr)
    }

    private static func writeTranscodedAudio(
        chain: AudioChain,
        packet: UnsafeMutablePointer<AVPacket>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        if avcodec_send_packet(chain.decCtx, packet) < 0 { return }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        while let decoded = frame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
            let maxOut = Int(av_rescale_rnd(
                swr_get_delay(chain.swr, 48000) + Int64(decoded.pointee.nb_samples),
                48000, Int64(decoded.pointee.sample_rate), AV_ROUND_UP))

            let planarBytes = maxOut * 2 * 4
            let buf0 = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self)
            let buf1 = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self)
            guard let buf0, let buf1 else { continue }
            defer { av_free(buf0); av_free(buf1) }

            var outBufs: [UnsafeMutablePointer<UInt8>?] = [buf0, buf1]
            let rawData = decoded.pointee.data
            var inData: [UnsafePointer<UInt8>?] = [
                UnsafePointer(rawData.0), UnsafePointer(rawData.1), UnsafePointer(rawData.2),
                UnsafePointer(rawData.3), UnsafePointer(rawData.4), UnsafePointer(rawData.5),
                UnsafePointer(rawData.6), UnsafePointer(rawData.7),
            ]
            let outSamples = Int(swr_convert(
                chain.swr, &outBufs, Int32(maxOut), &inData, decoded.pointee.nb_samples))
            guard outSamples > 0 else { continue }

            var encFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&encFrame) }
            guard let enc = encFrame else { continue }
            enc.pointee.nb_samples = Int32(outSamples)
            enc.pointee.format = Int32(AV_SAMPLE_FMT_FLTP.rawValue)
            enc.pointee.sample_rate = 48000
            av_channel_layout_copy(&enc.pointee.ch_layout, &chain.encCtx.pointee.ch_layout)
            guard av_frame_get_buffer(enc, 0) >= 0 else { continue }
            memcpy(enc.pointee.data.0, outBufs[0], outSamples * 4)
            memcpy(enc.pointee.data.1, outBufs[1], outSamples * 4)
            enc.pointee.pts = chain.nextPts
            chain.nextPts += Int64(outSamples)
            if avcodec_send_frame(chain.encCtx, enc) >= 0 {
                drainEncodedAudio(chain: chain, out: out, outStream: outStream)
            }
        }
    }

    private static func drainEncodedAudio(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var encPkt = AVPacket()
        av_init_packet(&encPkt)
        while avcodec_receive_packet(chain.encCtx, &encPkt) >= 0 {
            defer { av_packet_unref(&encPkt) }
            encPkt.stream_index = outStream.pointee.index
            av_packet_rescale_ts(&encPkt, chain.encCtx.pointee.time_base, outStream.pointee.time_base)
            encPkt.pos = -1
            av_interleaved_write_frame(out, &encPkt)
        }
    }

    // MARK: - Video transcode chain (VideoToolbox)

    private struct VideoChain {
        let inputIndex: Int32
        let decCtx: UnsafeMutablePointer<AVCodecContext>
        let encCtx: UnsafeMutablePointer<AVCodecContext>
        let hwFramesCtx: UnsafeMutablePointer<AVBufferRef>?
        // Non-nil only when the 1080p cap changes dimensions: decoded frames
        // are rescaled before hw upload. Cached context; freed in cleanup().
        let scaler: OpaquePointer?
        let scaledFrame: UnsafeMutablePointer<AVFrame>?
    }

    private static func makeVideoChain(
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>
    ) -> VideoChain? {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(decoder) else { return nil }
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0,
              avcodec_open2(decCtx, decoder, nil) >= 0 else { return nil }

        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_H264),
              let encCtx = avcodec_alloc_context3(encoder) else { return nil }

        // Cap output at 1080p, preserving aspect ratio. AirPlay targets are
        // 1080p-class; feeding them 4K transcodes burns CPU and stalls
        // realtime. Even dimensions required by H.264 yuv420p.
        var outW = decCtx.pointee.width
        var outH = decCtx.pointee.height
        if outW > 0 && outH > 0 && (outW > 1920 || outH > 1080) {
            let scale = min(Double(1920) / Double(outW), Double(1080) / Double(outH))
            outW = (Int32((Double(outW) * scale).rounded() / 2) * 2)
            outH = (Int32((Double(outH) * scale).rounded() / 2) * 2)
            NSLog("[RigelHlsExporter] downscaling %dx%d -> %dx%d", decCtx.pointee.width, decCtx.pointee.height, outW, outH)
        }

        var hwCtx: UnsafeMutablePointer<AVBufferRef>? = nil
        guard av_hwdevice_ctx_create(&hwCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0,
              let hwCtx else { return nil }
        guard let raw = av_hwframe_ctx_alloc(hwCtx) else { return nil }
        let framesRef = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: AVBufferRef.self)
        let framesPtr = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: AVHWFramesContext.self)
        framesPtr.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
        // sw_format is finalized below once the scaler decision is made.
        framesPtr.pointee.sw_format = decCtx.pointee.pix_fmt
        framesPtr.pointee.width = outW
        framesPtr.pointee.height = outH
        framesPtr.pointee.initial_pool_size = 8
        guard av_hwframe_ctx_init(framesRef) >= 0 else { return nil }

        encCtx.pointee.hw_frames_ctx = av_buffer_ref(framesRef)
        encCtx.pointee.width = outW
        encCtx.pointee.height = outH
        encCtx.pointee.time_base = AVRational(num: 1, den: 30)
        // AirPlay smoothness over fidelity: realtime-priority VideoToolbox
        // session, bitrate scaled to output size so the encoder never falls
        // behind the renderer's consumption rate.
        encCtx.pointee.bit_rate = transcodedBitrate(width: Int(outW), height: Int(outH))
        // Keyframe every segment (4s): each HLS chunk starts on an IDR, so a
        // seek/AirPlay join lands on an instantly decodable frame and the
        // playlist never references across segment boundaries.
        encCtx.pointee.gop_size = fpsHint(inputStream: inputStream) * 4
        encCtx.pointee.keyint_min = encCtx.pointee.gop_size
        encCtx.pointee.max_b_frames = 0
        encCtx.pointee.pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX
        av_opt_set(encCtx, "profile", "main", 0)
        // realtime: VideoToolbox schedules encode at capture priority —
        // the difference between keeping up with playback and falling
        // behind on AirPlay. allow_hw: keeps frames on GPU end to end.
        av_opt_set(encCtx, "realtime", "1", 0)
        av_opt_set(encCtx, "allow_hw", "1", 0)
        var encoderOptions: OpaquePointer? = nil
        defer { av_dict_free(&encoderOptions) }
        var scaler: OpaquePointer? = nil
        var scaledFrame: UnsafeMutablePointer<AVFrame>? = nil
        let needsScale = outW != decCtx.pointee.width || outH != decCtx.pointee.height
        if needsScale {
            // Scale into NV12: VideoToolbox's native encode format. Also
            // normalizes high-bit-depth decode output (10/12-bit YUV) into
            // 8-bit NV12 so the hw encoder accepts it.
            framesPtr.pointee.sw_format = AV_PIX_FMT_NV12
            scaler = sws_getContext(
                decCtx.pointee.width, decCtx.pointee.height, decCtx.pointee.pix_fmt,
                Int32(outW), Int32(outH), AV_PIX_FMT_NV12,
                SWS_BILINEAR, nil, nil, nil)
            guard let scaler else { return nil }
            scaledFrame = av_frame_alloc()
            guard let scaledFrame else { return nil }
            let f = scaledFrame
            f.pointee.format = Int32(AV_PIX_FMT_NV12.rawValue)
            f.pointee.width = Int32(outW)
            f.pointee.height = Int32(outH)
            if av_frame_get_buffer(f, 0) < 0 { return nil }
        }

        return VideoChain(
            inputIndex: inputStream.pointee.index,
            decCtx: decCtx,
            encCtx: encCtx,
            hwFramesCtx: framesRef,
            scaler: scaler,
            scaledFrame: scaledFrame
        )
    }

    /// Output bitrate by resolution class. Generous but bounded: AirPlay
    /// renderers buffer ~3 segments; a steady bitrate avoids VBV spikes that
    /// stall segment fetches.
    private static func transcodedBitrate(width: Int, height: Int) -> Int64 {
        if width <= 640 && height <= 360 { return 800_000 }
        if width <= 1280 && height <= 720 { return 3_500_000 }
        if width <= 1920 && height <= 1080 { return 7_000_000 }
        return 10_000_000
    }

    /// Source fps from the stream's avg_frame_rate, clamped to [15, 60].
    /// gop_size must be an integer frame count; guessing 30 for 24fps media
    /// drifts keyframes off segment boundaries.
    private static func fpsHint(inputStream: UnsafeMutablePointer<AVStream>) -> Int32 {
        let rate = inputStream.pointee.avg_frame_rate
        if rate.den > 0 {
            let fps = Double(rate.num) / Double(rate.den)
            if fps.isFinite && fps > 0 { return Int32(min(max(fps, 15), 60)) }
        }
        return 30
    }

    private static func writeTranscodedVideo(
        chain: VideoChain,
        packet: UnsafeMutablePointer<AVPacket>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        if avcodec_send_packet(chain.decCtx, packet) < 0 { return }
        var swFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&swFrame) }
        while let decoded = swFrame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
            let uploadFrame: UnsafeMutablePointer<AVFrame>
            if let scaler = chain.scaler, let scaled = chain.scaledFrame {
                guard sws_scale_frame(scaler, scaled, decoded) == 0 else { continue }
                uploadFrame = scaled
            } else {
                uploadFrame = decoded
            }
            var hwFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&hwFrame) }
            guard let hw = hwFrame,
                  av_hwframe_get_buffer(chain.hwFramesCtx, hw, 0) >= 0,
                  av_hwframe_transfer_data(hw, uploadFrame, 0) >= 0 else { continue }
            hw.pointee.pts = decoded.pointee.pts
            if avcodec_send_frame(chain.encCtx, hw) >= 0 {
                drainEncodedVideo(chain: chain, out: out, outStream: outStream)
            }
        }
    }

    private static func drainEncodedVideo(
        chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var encPkt = AVPacket()
        av_init_packet(&encPkt)
        while avcodec_receive_packet(chain.encCtx, &encPkt) >= 0 {
            defer { av_packet_unref(&encPkt) }
            encPkt.stream_index = outStream.pointee.index
            av_packet_rescale_ts(&encPkt, chain.encCtx.pointee.time_base, outStream.pointee.time_base)
            encPkt.pos = -1
            av_interleaved_write_frame(out, &encPkt)
        }
    }

    private static func openInput(url: String, headers: [String: String], fmt: inout UnsafeMutablePointer<AVFormatContext>?) -> Bool {
        var opened = false
        url.withCString { cstr in
            var opts: OpaquePointer? = nil
            for (key, value) in headers {
                key.withCString { k in
                    value.withCString { v in
                        av_dict_set(&opts, k, v, 0)
                    }
                }
            }
            let ret = avformat_open_input(&fmt, cstr, nil, &opts)
            if ret < 0 { return }
            if avformat_find_stream_info(fmt, nil) < 0 { return }
            opened = true
        }
        return opened
    }

    private static func cleanup(
        ifmt: UnsafeMutablePointer<AVFormatContext>?,
        ofmt: UnsafeMutablePointer<AVFormatContext>?,
        audio: AudioChain?,
        video: VideoChain?
    ) {
        var ifmtPtr: UnsafeMutablePointer<AVFormatContext>? = ifmt
        avformat_close_input(&ifmtPtr)
        if let ofmt { avformat_free_context(ofmt) }
        if let audio {
            var dec: UnsafeMutablePointer<AVCodecContext>? = audio.decCtx
            avcodec_free_context(&dec)
            var enc: UnsafeMutablePointer<AVCodecContext>? = audio.encCtx
            avcodec_free_context(&enc)
            var swr: OpaquePointer? = audio.swr
            swr_free(&swr)
        }

        if let video {
            var dec: UnsafeMutablePointer<AVCodecContext>? = video.decCtx
            avcodec_free_context(&dec)
            var enc: UnsafeMutablePointer<AVCodecContext>? = video.encCtx
            avcodec_free_context(&enc)
            var ref: UnsafeMutablePointer<AVBufferRef>? = video.encCtx.pointee.hw_frames_ctx
            av_buffer_unref(&ref)
            if video.scaledFrame != nil {
                var f: UnsafeMutablePointer<AVFrame>? = video.scaledFrame
                av_frame_free(&f)
            }
            if let sws = video.scaler {
                sws_freeContext(sws)
            }
        }
    }

    private static func codecName(_ id: AVCodecID) -> String? {
        guard let name = avcodec_get_name(id) else { return nil }
        return String(cString: name)
    }

    private static func avErrorString(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        av_strerror(code, &buf, buf.count)
        return String(cString: buf)
    }
}
