import Foundation

final class VideoChain {
    let inputIndex: Int32
    let decCtx: UnsafeMutablePointer<AVCodecContext>
    let encCtx: UnsafeMutablePointer<AVCodecContext>
    let inputTimeBase: AVRational
    var timestampOrigin90k: Int64
    let frameDurationPTS: Int64
    var inputPixFmt: AVPixelFormat = AV_PIX_FMT_NONE
    var sourceWidth: Int32 = 0
    var sourceHeight: Int32 = 0
    var hwFramesCtx: UnsafeMutablePointer<AVBufferRef>?
    var scaler: OpaquePointer?
    var scaledFrame: UnsafeMutablePointer<AVFrame>?
    var initialized = false
    var pendingFrames: [UnsafeMutablePointer<AVFrame>] = []
    var error: String?
    var outputStreams: [UnsafeMutablePointer<AVStream>] = []
    var hasVideoPTS = false
    var lastVideoPTS: Int64 = 0
    var lastRawVideoPTS: Int64?
    var videoPTSOffset: Int64 = 0

    init(
        inputIndex: Int32,
        decCtx: UnsafeMutablePointer<AVCodecContext>,
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        inputTimeBase: AVRational,
        timestampOrigin90k: Int64,
        frameRate: Double
    ) {
        self.inputIndex = inputIndex
        self.decCtx = decCtx
        self.encCtx = encCtx
        self.inputTimeBase = inputTimeBase
        self.timestampOrigin90k = timestampOrigin90k
        self.frameDurationPTS = max(1, Int64((90_000.0 / max(frameRate, 1.0)).rounded()))
    }

    func release() {
        for frame in pendingFrames {
            var pointer: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&pointer)
        }
        pendingFrames.removeAll()
        if let scaledFrame {
            var pointer: UnsafeMutablePointer<AVFrame>? = scaledFrame
            av_frame_free(&pointer)
            self.scaledFrame = nil
        }
        if let scaler {
            sws_freeContext(scaler)
            self.scaler = nil
        }
        var frames = hwFramesCtx
        av_buffer_unref(&frames)
        hwFramesCtx = nil
        var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&dec)
        var enc: UnsafeMutablePointer<AVCodecContext>? = encCtx
        avcodec_free_context(&enc)
    }
}

extension RigelHlsExporter {
    static func makeVideoChain(
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>,
        timestampOrigin90k: Int64
    ) -> VideoChain? {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(decoder) else { return nil }
        var encCtx: UnsafeMutablePointer<AVCodecContext>?
        func fail() -> VideoChain? {
            var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
            avcodec_free_context(&dec)
            if encCtx != nil {
                var enc = encCtx
                avcodec_free_context(&enc)
            }
            return nil
        }
        let sourceTimeBase = inputStream.pointee.time_base
        let packetTimeBase = sourceTimeBase.num != 0 && sourceTimeBase.den != 0
            ? sourceTimeBase : AVRational(num: 1, den: 90_000)
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0 else { return fail() }
        decCtx.pointee.pkt_timebase = packetTimeBase
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { return fail() }
        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_H264),
              let allocatedEnc = avcodec_alloc_context3(encoder) else { return fail() }
        encCtx = allocatedEnc
        allocatedEnc.pointee.time_base = AVRational(num: 1, den: 90_000)
        let chain = VideoChain(
            inputIndex: inputStream.pointee.index,
            decCtx: decCtx,
            encCtx: allocatedEnc,
            inputTimeBase: packetTimeBase,
            timestampOrigin90k: timestampOrigin90k,
            frameRate: sourceFrameRate(inputStream: inputStream)
        )
        let format = AVPixelFormat(rawValue: codecpar.pointee.format)
        if format != AV_PIX_FMT_NONE && codecpar.pointee.width > 0 && codecpar.pointee.height > 0,
           !initializeVideoChain(
               chain, inputStream: inputStream, outputStream: outputStream, inputPixFmt: format,
               sourceWidth: codecpar.pointee.width, sourceHeight: codecpar.pointee.height
           ) {
            chain.release()
            return nil
        }
        return chain
    }

    /// Complete VideoToolbox setup only after a concrete decoded format is
    /// known. codecpar.format is legitimately AV_PIX_FMT_NONE for some
    /// demuxers and becomes reliable only on the first decoded frame.
    static func configureHardwareFramesContext(
        _ frames: UnsafeMutablePointer<AVBufferRef>,
        width: Int32,
        height: Int32
    ) -> UnsafeMutablePointer<AVHWFramesContext>? {
        guard let framesData = frames.pointee.data else { return nil }
        let context = UnsafeMutableRawPointer(framesData)
            .assumingMemoryBound(to: AVHWFramesContext.self)
        context.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
        context.pointee.sw_format = AV_PIX_FMT_NV12
        context.pointee.width = width
        context.pointee.height = height
        context.pointee.initial_pool_size = 8
        return context
    }

    static func initializeVideoChain(
        _ chain: VideoChain,
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>,
        inputPixFmt: AVPixelFormat,
        sourceWidth: Int32,
        sourceHeight: Int32
    ) -> Bool {
        guard !chain.initialized, inputPixFmt != AV_PIX_FMT_NONE,
              sourceWidth > 0, sourceHeight > 0 else { return false }

        var outW = sourceWidth
        var outH = sourceHeight
        if outW > 1920 || outH > 1080 {
            let scale = min(Double(1920) / Double(outW), Double(1080) / Double(outH))
            outW = Int32((Double(outW) * scale).rounded() / 2) * 2
            outH = Int32((Double(outH) * scale).rounded() / 2) * 2
            NSLog("[RigelHlsExporter] downscaling %dx%d -> %dx%d", sourceWidth, sourceHeight, outW, outH)
        }

        // VideoToolbox's H.264 encoder consumes NV12. sw_format and dimensions
        // are final before av_hwframe_ctx_init, even for unknown-format input.
        let needScale = outW != sourceWidth || outH != sourceHeight || inputPixFmt != AV_PIX_FMT_NV12
        var hwCtx: UnsafeMutablePointer<AVBufferRef>? = nil
        guard av_hwdevice_ctx_create(&hwCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0,
              let deviceCtx = hwCtx else { return false }
        var deviceRef: UnsafeMutablePointer<AVBufferRef>? = deviceCtx
        defer { av_buffer_unref(&deviceRef) }
        guard let raw = av_hwframe_ctx_alloc(deviceCtx) else { return false }

        var framesRef: UnsafeMutablePointer<AVBufferRef>? = UnsafeMutableRawPointer(raw)
            .assumingMemoryBound(to: AVBufferRef.self)
        var scaler: OpaquePointer?
        var scaledFrame: UnsafeMutablePointer<AVFrame>?
        var committed = false
        defer {
            if !committed {
                var frames = framesRef
                av_buffer_unref(&frames)
                if let scaledFrame {
                    var frame: UnsafeMutablePointer<AVFrame>? = scaledFrame
                    av_frame_free(&frame)
                }
                if let scaler { sws_freeContext(scaler) }
            }
        }

        guard let frames = framesRef else { return false }
        guard configureHardwareFramesContext(frames, width: outW, height: outH) != nil else {
            return false
        }
        guard av_hwframe_ctx_init(frames) >= 0 else { return false }

        if needScale {
            guard let newScaler = sws_getContext(
                sourceWidth, sourceHeight, inputPixFmt,
                outW, outH, AV_PIX_FMT_NV12,
                SWS_BILINEAR, nil, nil, nil
            ) else { return false }
            scaler = newScaler
            guard let frame = av_frame_alloc() else { return false }
            frame.pointee.format = Int32(AV_PIX_FMT_NV12.rawValue)
            frame.pointee.width = outW
            frame.pointee.height = outH
            guard av_frame_get_buffer(frame, 0) >= 0 else {
                var framePointer: UnsafeMutablePointer<AVFrame>? = frame
                av_frame_free(&framePointer)
                return false
            }
            scaledFrame = frame
        }

        guard let encoderFrames = av_buffer_ref(frames) else { return false }
        chain.encCtx.pointee.hw_frames_ctx = encoderFrames
        chain.encCtx.pointee.width = outW
        chain.encCtx.pointee.height = outH
        chain.encCtx.pointee.time_base = AVRational(num: 1, den: 90_000)
        chain.encCtx.pointee.bit_rate = transcodedBitrate(width: Int(outW), height: Int(outH))
        let fps = fpsHint(inputStream: inputStream)
        chain.encCtx.pointee.gop_size = gopFrameCount(forFPS: fps)
        chain.encCtx.pointee.keyint_min = chain.encCtx.pointee.gop_size
        chain.encCtx.pointee.max_b_frames = 0
        chain.encCtx.pointee.pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX
        av_opt_set(chain.encCtx, "profile", "main", 0)
        var encoderOptions: OpaquePointer? = nil
        av_dict_set(&encoderOptions, "realtime", "1", 0)
        defer { av_dict_free(&encoderOptions) }
        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_H264),
              avcodec_open2(chain.encCtx, encoder, &encoderOptions) >= 0,
              avcodec_parameters_from_context(outputStream.pointee.codecpar, chain.encCtx) >= 0 else {
            return false
        }
        outputStream.pointee.time_base = chain.encCtx.pointee.time_base
        chain.hwFramesCtx = frames
        framesRef = nil
        chain.scaler = scaler
        scaler = nil
        chain.scaledFrame = scaledFrame
        scaledFrame = nil
        chain.inputPixFmt = inputPixFmt
        chain.sourceWidth = sourceWidth
        chain.sourceHeight = sourceHeight
        chain.initialized = true
        committed = true
        return true
    }
    enum PrimeVideoResult {
        case fatal
        case needMoreInput
        case initialized
    }

    static func retainPrimedFrame(
        _ chain: VideoChain,
        decoded: UnsafeMutablePointer<AVFrame>,
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>
    ) -> Bool {
        if !chain.initialized {
            let format = AVPixelFormat(rawValue: decoded.pointee.format)
            guard initializeVideoChain(
                chain,
                inputStream: inputStream,
                outputStream: outputStream,
                inputPixFmt: format,
                sourceWidth: decoded.pointee.width,
                sourceHeight: decoded.pointee.height
            ) else { return false }
        }
        guard let retained = av_frame_alloc(), av_frame_ref(retained, decoded) >= 0 else { return false }
        chain.pendingFrames.append(retained)
        av_frame_unref(decoded)
        return true
    }

    static func primeVideoPacket(
        _ chain: VideoChain,
        packet: UnsafeMutablePointer<AVPacket>,
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>
    ) -> PrimeVideoResult {
        guard avcodec_send_packet(chain.decCtx, packet) >= 0 else { return .fatal }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        while let decoded = frame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
            guard retainPrimedFrame(chain, decoded: decoded, inputStream: inputStream, outputStream: outputStream) else {
                return .fatal
            }
        }
        return chain.initialized ? .initialized : .needMoreInput
    }

    static func flushPrimingVideo(
        _ chain: VideoChain,
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>
    ) -> PrimeVideoResult {
        guard avcodec_send_packet(chain.decCtx, nil) >= 0 else { return .fatal }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        while let decoded = frame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
            guard retainPrimedFrame(chain, decoded: decoded, inputStream: inputStream, outputStream: outputStream) else {
                return .fatal
            }
        }
        return chain.initialized ? .initialized : .fatal
    }
    /// Derives a 90 kHz origin for the retained audio tail. Scans each
    /// stream to its first usable PTS/DTS and subtracts known durations of
    /// earlier timestamp-less packets before returning the earliest stream
    /// head. A timestamp-less head must not disable the tail rebase.
    static func audioRingHeadPTS90k(
        _ packets: [UnsafeMutablePointer<AVPacket>],
        timeBases: [Int32: AVRational]
    ) -> Int64? {
        let commonTimeBase = AVRational(num: 1, den: 90_000)
        var durationBefore: [Int32: Int64] = [:]
        var heads: [Int32: Int64] = [:]
        for packet in packets {
            let streamIndex = packet.pointee.stream_index
            guard let timeBase = timeBases[streamIndex],
                  timeBase.num != 0,
                  timeBase.den != 0 else {
                continue
            }
            let timestamp = packet.pointee.pts != Int64.min
                ? packet.pointee.pts
                : packet.pointee.dts
            if timestamp != Int64.min, heads[streamIndex] == nil {
                heads[streamIndex] = av_rescale_q(
                    timestamp - (durationBefore[streamIndex] ?? 0),
                    timeBase,
                    commonTimeBase
                )
            }
            if heads[streamIndex] == nil, packet.pointee.duration > 0 {
                durationBefore[streamIndex] = min(
                    Int64.max,
                    (durationBefore[streamIndex] ?? 0) + packet.pointee.duration
                )
            }
        }
        return heads.values.min()
    }
    enum PrimingReadResult {
        case ok
        case again
        case eof
        case readError(String)
    }

    /// av_read_frame is negative for EOF, EAGAIN, and real I/O errors alike.
    /// Only EOF terminates priming; EAGAIN is a transient non-blocking retry;
    /// anything else is a genuine read failure.
    static func classifyPrimingRead(_ ret: Int32) -> PrimingReadResult {
        if ret >= 0 { return .ok }
        if ret == -541_478_725 { return .eof } // AVERROR_EOF (FFERRTAG 'E','O','F',' ')
        if ret == -EAGAIN { return .again }    // AVERROR(EAGAIN); Darwin EAGAIN = 35
        return .readError("video priming read error: \(avErrorString(ret))")
    }
    /// Output bitrate by resolution class. Generous but bounded: AirPlay
    /// renderers buffer ~3 segments; a steady bitrate avoids VBV spikes that
    /// stall segment fetches.
    static func transcodedBitrate(width: Int, height: Int) -> Int64 {
        if width <= 640 && height <= 360 { return 800_000 }
        if width <= 1280 && height <= 720 { return 3_500_000 }
        if width <= 1920 && height <= 1080 { return 7_000_000 }
        return 10_000_000
    }

    /// GOP sizing is independently capped for encoder/segment overhead.
    static func gopFrameCount(forFPS fps: Double, segmentDuration: Double = 4) -> Int32 {
        let clamped = fps.isFinite && fps > 0 ? min(max(fps, 15), 60) : 30
        return Int32((clamped * segmentDuration).rounded())
    }

    static func rescaleVideoPTS(
        _ pts: Int64,
        from input: AVRational,
        to output: AVRational,
        origin90k: Int64 = 0
    ) -> Int64 {
        guard pts != Int64.min else { return pts }
        let commonTimeBase = AVRational(num: 1, den: 90_000)
        let commonPTS = av_rescale_q(pts, input, commonTimeBase)
        return av_rescale_q(max(0, commonPTS - origin90k), commonTimeBase, output)
    }

    /// Repairs a video timestamp while tracking the prior *raw* source value
    /// and a persistent offset. After an anomaly the offset carries forward,
    /// so a following genuine-but-close candidate is shifted with the repaired
    /// timeline instead of collapsing onto it: for 30fps (3000 ticks),
    /// candidates [0, 0, 3100] become [0, 3000, 6100], never [0, 3000, 3100].
    static func repairVideoPTS(
        candidate: Int64?,
        previousRepaired: Int64?,
        previousRaw: Int64?,
        previousOffset: Int64,
        frameDuration: Int64
    ) -> (repaired: Int64, offset: Int64, lastRaw: Int64?) {
        guard let previousRepaired else {
            let repaired = max(candidate ?? 0, 0)
            if let raw = candidate {
                return (repaired, repaired - raw, raw)
            }
            return (repaired, previousOffset, nil)
        }
        if let raw = candidate, let priorRaw = previousRaw, raw > priorRaw {
            let shifted = raw + previousOffset
            if shifted > previousRepaired {
                // Genuine forward timestamp (including VFR/high-FPS deltas):
                // carry the repaired timeline offset only when it remains
                // strictly monotonic past the repaired tail.
                return (shifted, previousOffset, raw)
            }
        }
        // Missing, duplicate, regressed, or forward-but-still-behind the
        // repaired timeline: re-space at one full frame duration and re-anchor
        // the offset onto the raw value when one exists.
        let repaired = previousRepaired + frameDuration
        if let raw = candidate {
            return (repaired, repaired - raw, raw)
        }
        return (repaired, previousOffset, previousRaw)
    }

    static func sourceFrameRate(avg: AVRational, nominal: AVRational) -> Double {
        for rate in [avg, nominal] where rate.den > 0 {
            let fps = Double(rate.num) / Double(rate.den)
            if fps.isFinite && fps > 0 { return fps }
        }
        return 30
    }

    static func sourceFrameRate(inputStream: UnsafeMutablePointer<AVStream>) -> Double {
        sourceFrameRate(
            avg: inputStream.pointee.avg_frame_rate,
            nominal: inputStream.pointee.r_frame_rate
        )
    }

    static func fpsHint(inputStream: UnsafeMutablePointer<AVStream>) -> Double {
        return min(max(sourceFrameRate(inputStream: inputStream), 15), 60)
    }

    static func nextVideoPTS(_ decoded: UnsafeMutablePointer<AVFrame>, chain: VideoChain) -> Int64 {
        let rawPTS = decoded.pointee.best_effort_timestamp != Int64.min
            ? decoded.pointee.best_effort_timestamp
            : decoded.pointee.pts
        let candidate: Int64?
        if rawPTS == Int64.min {
            candidate = nil
        } else {
            candidate = rescaleVideoPTS(
                rawPTS,
                from: chain.inputTimeBase,
                to: chain.encCtx.pointee.time_base,
                origin90k: chain.timestampOrigin90k
            )
        }
        let repair = repairVideoPTS(
            candidate: candidate,
            previousRepaired: chain.hasVideoPTS ? chain.lastVideoPTS : nil,
            previousRaw: chain.lastRawVideoPTS,
            previousOffset: chain.videoPTSOffset,
            frameDuration: chain.frameDurationPTS
        )
        chain.lastVideoPTS = repair.repaired
        chain.lastRawVideoPTS = repair.lastRaw
        chain.videoPTSOffset = repair.offset
        chain.hasVideoPTS = true
        return repair.repaired
    }

    static func writeTranscodedVideo(
        chain: VideoChain,
        packet: UnsafeMutablePointer<AVPacket>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        if avcodec_send_packet(chain.decCtx, packet) < 0 { return }
        var swFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&swFrame) }
        while let decoded = swFrame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
            writeTranscodedVideoFrame(chain: chain, decoded: decoded, out: out, outStream: outStream)
        }
    }

    static func drainPendingVideoFrames(
        _ chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        for frame in chain.pendingFrames {
            writeTranscodedVideoFrame(chain: chain, decoded: frame, out: out, outStream: outStream)
            var framePointer: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&framePointer)
        }
        chain.pendingFrames.removeAll()
    }

    static func scaleVideoFrame(
        _ scaler: OpaquePointer,
        source: UnsafeMutablePointer<AVFrame>,
        destination: UnsafeMutablePointer<AVFrame>
    ) -> Bool {
        guard av_frame_make_writable(destination) >= 0 else { return false }
        var sourcePlanes: [UnsafePointer<UInt8>?] = [
            UnsafePointer(source.pointee.data.0), UnsafePointer(source.pointee.data.1),
            UnsafePointer(source.pointee.data.2), UnsafePointer(source.pointee.data.3),
            UnsafePointer(source.pointee.data.4), UnsafePointer(source.pointee.data.5),
            UnsafePointer(source.pointee.data.6), UnsafePointer(source.pointee.data.7),
        ]
        var sourceStrides: [Int32] = [
            source.pointee.linesize.0, source.pointee.linesize.1, source.pointee.linesize.2,
            source.pointee.linesize.3, source.pointee.linesize.4, source.pointee.linesize.5,
            source.pointee.linesize.6, source.pointee.linesize.7,
        ]
        var destinationPlanes: [UnsafeMutablePointer<UInt8>?] = [
            destination.pointee.data.0, destination.pointee.data.1,
            destination.pointee.data.2, destination.pointee.data.3,
            destination.pointee.data.4, destination.pointee.data.5,
            destination.pointee.data.6, destination.pointee.data.7,
        ]
        var destinationStrides: [Int32] = [
            destination.pointee.linesize.0, destination.pointee.linesize.1,
            destination.pointee.linesize.2, destination.pointee.linesize.3,
            destination.pointee.linesize.4, destination.pointee.linesize.5,
            destination.pointee.linesize.6, destination.pointee.linesize.7,
        ]
        let scaledRows = sourcePlanes.withUnsafeBufferPointer { sourcePlanes in
            sourceStrides.withUnsafeBufferPointer { sourceStrides in
                destinationPlanes.withUnsafeBufferPointer { destinationPlanes in
                    destinationStrides.withUnsafeBufferPointer { destinationStrides in
                        sws_scale(
                            scaler,
                            sourcePlanes.baseAddress,
                            sourceStrides.baseAddress,
                            0,
                            source.pointee.height,
                            destinationPlanes.baseAddress,
                            destinationStrides.baseAddress
                        )
                    }
                }
            }
        }
        return scaledRows == destination.pointee.height
    }

    static func writeTranscodedVideoFrame(
        chain: VideoChain,
        decoded: UnsafeMutablePointer<AVFrame>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        let format = AVPixelFormat(rawValue: decoded.pointee.format)
        guard chain.initialized,
              format == chain.inputPixFmt,
              decoded.pointee.width == chain.sourceWidth,
              decoded.pointee.height == chain.sourceHeight else {
            chain.error = "video format changed during transcode"
            return
        }
        let uploadFrame: UnsafeMutablePointer<AVFrame>
        if let scaler = chain.scaler, let scaled = chain.scaledFrame {
            guard Self.scaleVideoFrame(scaler, source: decoded, destination: scaled) else {
                chain.error = "video frame conversion failed"
                return
            }
            uploadFrame = scaled
        } else {
            uploadFrame = decoded
        }
        var hwFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&hwFrame) }
        guard let hw = hwFrame,
              av_hwframe_get_buffer(chain.hwFramesCtx, hw, 0) >= 0,
              av_hwframe_transfer_data(hw, uploadFrame, 0) >= 0 else {
            chain.error = "video hardware frame conversion failed"
            return
        }
        hw.pointee.pts = nextVideoPTS(decoded, chain: chain)
        if avcodec_send_frame(chain.encCtx, hw) >= 0 {
            drainEncodedVideo(chain: chain, out: out, outStream: outStream)
        }
    }

    static func drainEncodedVideo(
        chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var encPkt = AVPacket()
        av_init_packet(&encPkt)
        let outputStreams = chain.outputStreams.isEmpty ? [outStream] : chain.outputStreams
        while avcodec_receive_packet(chain.encCtx, &encPkt) >= 0 {
            for destination in outputStreams {
                var copy = AVPacket()
                av_init_packet(&copy)
                guard av_packet_ref(&copy, &encPkt) >= 0 else { continue }
                copy.stream_index = destination.pointee.index
                av_packet_rescale_ts(&copy, chain.encCtx.pointee.time_base, destination.pointee.time_base)
                copy.pos = -1
                av_interleaved_write_frame(out, &copy)
                av_packet_unref(&copy)
            }
            av_packet_unref(&encPkt)
        }
    }

    static func flushTranscodedVideo(
        chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        if avcodec_send_packet(chain.decCtx, nil) >= 0 {
            var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&frame) }
            while let decoded = frame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
                writeTranscodedVideoFrame(chain: chain, decoded: decoded, out: out, outStream: outStream)
            }
        }
        if avcodec_send_frame(chain.encCtx, nil) >= 0 {
            drainEncodedVideo(chain: chain, out: out, outStream: outStream)
        }
    }
}
