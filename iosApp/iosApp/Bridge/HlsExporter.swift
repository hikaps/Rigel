import Foundation

/// Local ffmpeg remux/transcode → HLS session. Writes segments + playlist into
/// Documents/proxy/<sessionId>/ and signals readiness when the playlist exists.
/// REMUX: video stream-copy; audio copy when AAC/MP3/FLAC/ALAC else decode→AAC.
/// TRANSCODE: video decode→VideoToolbox H.264, audio decode→AAC.
final class RigelHlsExporter {
    final class Session {
        let queue: DispatchQueue
        var cancel = false
        var finished = false
        var readinessClaimed = false
        var readinessDelivered = false

        init(queue: DispatchQueue) {
            self.queue = queue
        }
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
        onReady: @escaping (String?, String?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        let queue = DispatchQueue(label: "rigel-hls-\(sessionId)")
        let session = Session(queue: queue)
        lock.lock(); sessions[sessionId] = session; lock.unlock()
        queue.async {
            run(
                session: session,
                sessionId: sessionId,
                sourceUrl: sourceUrl,
                headers: headers,
                mode: mode,
                onReady: onReady,
                onError: onError
            )
        }
    }

    static func stopSession(sessionId: String) {
        lock.lock(); sessions[sessionId]?.cancel = true; lock.unlock()
    }

    private static func isCancelled(_ session: Session) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return session.cancel
    }

    private static func finishSession(_ session: Session, sessionId: String) -> Bool {
        lock.lock()
        session.finished = true
        let cancelled = session.cancel
        if sessions[sessionId] === session &&
            (cancelled || !session.readinessClaimed || session.readinessDelivered) {
            sessions.removeValue(forKey: sessionId)
        }
        lock.unlock()
        return cancelled
    }

    @discardableResult
    private static func publishReady(
        session: Session,
        sessionId: String,
        path: String,
        onReady: @escaping (String?, String?) -> Void
    ) -> Bool {
        lock.lock()
        guard !session.cancel, !session.readinessClaimed else {
            lock.unlock()
            return false
        }
        session.readinessClaimed = true
        lock.unlock()

        DispatchQueue.main.async {
            lock.lock()
            let deliver = !session.cancel
            if deliver {
                session.readinessDelivered = true
            }
            if session.finished && sessions[sessionId] === session {
                sessions.removeValue(forKey: sessionId)
            }
            lock.unlock()
            if deliver {
                onReady(path, nil)
            }
        }
        return true
    }

    private static func sourceTimestampOrigin90k(
        _ ctx: UnsafeMutablePointer<AVFormatContext>,
        videoIndex: Int32?,
        audioIndex: Int32?
    ) -> Int64 {
        let commonTimeBase = AVRational(num: 1, den: 90_000)
        var origin: Int64?
        if ctx.pointee.start_time != Int64.min {
            origin = av_rescale_q(
                ctx.pointee.start_time,
                AVRational(num: 1, den: AV_TIME_BASE),
                commonTimeBase
            )
        }
        for index in [videoIndex, audioIndex].compactMap({ $0 }) {
            guard let stream = ctx.pointee.streams[Int(index)],
                  stream.pointee.start_time != Int64.min else { continue }
            let timeBase = stream.pointee.time_base
            guard timeBase.num != 0, timeBase.den != 0 else { continue }
            let start = av_rescale_q(stream.pointee.start_time, timeBase, commonTimeBase)
            origin = origin.map { min($0, start) } ?? start
        }
        return origin ?? 0
    }

    private static func run(
        session: Session,
        sessionId: String,
        sourceUrl: String,
        headers: [String: String],
        mode: String,
        onReady: @escaping (String?, String?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        let outDir = sessionDir(sessionId: sessionId)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let playlistPath = outDir.appendingPathComponent("index.m3u8").path

        var ifmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var ofmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var audioChain: AudioChain? = nil
        var videoChain: VideoChain? = nil
        var pendingAudioPackets: [UnsafeMutablePointer<AVPacket>] = []
        var notified = false
        var terminalError: String?
        func reportFailure(_ message: String) {
            guard !isCancelled(session) else { return }
            if notified {
                DispatchQueue.main.async { onError(message) }
            } else {
                notified = true
                DispatchQueue.main.async { onReady(nil, message) }
            }
        }

        defer {
            let wasCancelled = finishSession(session, sessionId: sessionId)
            if !notified && !wasCancelled {
                notified = true
                DispatchQueue.main.async { onReady(nil, "session ended before playlist was ready") }
            }
            for packet in pendingAudioPackets {
                var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&packetPointer)
            }
            cleanup(ifmt: ifmt, ofmt: ofmt, audio: audioChain, video: videoChain)
        }

        guard openInput(url: sourceUrl, headers: headers, fmt: &ifmt), let ctx = ifmt else {
            reportFailure("failed to open source: \(sourceUrl)")
            return
        }

        guard avformat_alloc_output_context2(&ofmt, nil, "hls", playlistPath) >= 0, let out = ofmt else {
            reportFailure("failed to create HLS output context")
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
        var selectedVideoIndex: Int32?
        var selectedVideoIsDefault = false
        var selectedAudioIndex: Int32?
        var selectedAudioIsDefault = false
        for i in 0..<inCount {
            guard let stream = ctx.pointee.streams[i], let codecpar = stream.pointee.codecpar else { continue }
            let inputIndex = Int32(i)
            let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                let isAttachedPicture = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
                if !isAttachedPicture &&
                    (selectedVideoIndex == nil || (isDefault && !selectedVideoIsDefault)) {
                    selectedVideoIndex = inputIndex
                    selectedVideoIsDefault = isDefault
                }
            case AVMEDIA_TYPE_AUDIO:
                if selectedAudioIndex == nil || (isDefault && !selectedAudioIsDefault) {
                    selectedAudioIndex = inputIndex
                    selectedAudioIsDefault = isDefault
                }
            default:
                break
            }
        }
        let timestampOrigin90k = sourceTimestampOrigin90k(
            ctx,
            videoIndex: selectedVideoIndex,
            audioIndex: selectedAudioIndex
        )

        var streamMap: [Int32: Int32] = [:]
        for i in 0..<inCount {
            let inputIndex = Int32(i)
            guard inputIndex == selectedVideoIndex || inputIndex == selectedAudioIndex,
                  let inStream = ctx.pointee.streams[i],
                  let codecpar = inStream.pointee.codecpar,
                  let outStream = avformat_new_stream(out, nil) else { continue }
            let outIndex = outStream.pointee.index
            streamMap[inputIndex] = outIndex

            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                // remux: verbatim stream copy. transcode: always re-encode.
                if mode == "remux" {
                    if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 {
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        outStream.pointee.time_base = inStream.pointee.time_base
                    }
                } else {
                    videoChain = makeVideoChain(
                        inputStream: inStream,
                        outputStream: outStream,
                        timestampOrigin90k: timestampOrigin90k
                    )
                }
            case AVMEDIA_TYPE_AUDIO:
                if mode == "remux", let name = codecName(codecpar.pointee.codec_id),
                   passthroughAudio.contains(name) {
                    if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 {
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        outStream.pointee.time_base = inStream.pointee.time_base
                    }
                } else {
                    audioChain = makeAudioChain(
                        inputStream: inStream,
                        outputStream: outStream,
                        timestampOrigin90k: timestampOrigin90k
                    )
                }
            default:
                break
            }
        }

        if mode != "remux", selectedVideoIndex != nil, videoChain == nil {
            reportFailure("failed to initialize video transcoder")
            return
        }

        // Some demuxers leave codecpar.format unset. Prime the decoder until
        // the first real frame reveals its format and dimensions, buffering
        // audio packets encountered before the HLS header can be written.
        if mode != "remux",
           let chain = videoChain,
           !chain.initialized,
           let videoIndex = selectedVideoIndex,
           let videoOutIndex = streamMap[videoIndex],
           let videoInStream = ctx.pointee.streams[Int(videoIndex)],
           let videoOutStream = out.pointee.streams[Int(videoOutIndex)] {
            /// Retained audio is a bounded tail ring, not fatal and not a
            /// drop-the-middle hole: when the byte cap is exceeded the oldest
            /// buffered packets are evicted, so what remains is always the
            /// audio adjacent to the first decoded video frame. The timeline
            /// is then rebased onto the ring head so replay stays continuous.
            let primingAudioByteLimit: Int64 = 8 * 1024 * 1024
            var primingAudioBytes: Int64 = 0
            var primingAudioEvicted = false
            primingLoop: while !chain.initialized && !isCancelled(session) {
                var primePacket = AVPacket()
                av_init_packet(&primePacket)
                let readRet = av_read_frame(ctx, &primePacket)
                switch classifyPrimingRead(readRet) {
                case .ok:
                    break
                case .again:
                    // Non-blocking source: transient, not EOF. Yield briefly
                    // so the retry loop does not spin.
                    usleep(1_000)
                    continue
                case .eof:
                    av_packet_unref(&primePacket)
                    if flushPrimingVideo(chain, inputStream: videoInStream, outputStream: videoOutStream) == .fatal {
                        reportFailure("video decoder produced no usable frame")
                        return
                    }
                    if !chain.initialized {
                        reportFailure("video decoder produced no usable frame")
                        return
                    }
                    // EOF packet is a sentinel, not media: exit the loop
                    // before the dispatch below can feed it to the decoder.
                    break primingLoop
                case .readError(let message):
                    av_packet_unref(&primePacket)
                    reportFailure(message)
                    return
                }
                if primePacket.stream_index == videoIndex {
                    switch primeVideoPacket(
                        chain,
                        packet: &primePacket,
                        inputStream: videoInStream,
                        outputStream: videoOutStream
                    ) {
                    case .fatal:
                        av_packet_unref(&primePacket)
                        reportFailure("failed to initialize video transcoder")
                        return
                    case .needMoreInput, .initialized:
                        break
                    }
                } else if primePacket.stream_index == selectedAudioIndex,
                          let buffered = av_packet_alloc(),
                          av_packet_ref(buffered, &primePacket) >= 0 {
                    primingAudioBytes += Int64(max(0, buffered.pointee.size))
                    pendingAudioPackets.append(buffered)
                    while primingAudioBytes > primingAudioByteLimit,
                          pendingAudioPackets.count > 1,
                          let oldest = pendingAudioPackets.first {
                        primingAudioBytes -= Int64(max(0, oldest.pointee.size))
                        pendingAudioPackets.removeFirst()
                        var oldestPointer: UnsafeMutablePointer<AVPacket>? = oldest
                        av_packet_free(&oldestPointer)
                        primingAudioEvicted = true
                    }
                }
                av_packet_unref(&primePacket)
            }
            if !chain.initialized {
                reportFailure("video decoder produced no usable frame")
                return
            }
            if primingAudioEvicted,
               let audioIndex = selectedAudioIndex,
               let audioInStream = ctx.pointee.streams[Int(audioIndex)],
               let ringHeadPTS = audioRingHeadPTS90k(pendingAudioPackets, timeBase: audioInStream.pointee.time_base) {
                // Rebase both chains onto the retained tail so replayed audio
                // and the first video frames share one continuous timeline.
                chain.timestampOrigin90k = ringHeadPTS
                audioChain?.timestampOrigin90k = ringHeadPTS
            }
        }
        let headerRet = avformat_write_header(out, nil)
        guard headerRet >= 0 else {
            reportFailure("HLS write header failed: \(avErrorString(headerRet))")
            return
        }

        if let chain = videoChain, chain.initialized,
           let videoOutIndex = streamMap[chain.inputIndex],
           let videoOutStream = out.pointee.streams[Int(videoOutIndex)] {
            drainPendingVideoFrames(chain, out: out, outStream: videoOutStream)
        }
        if let videoError = videoChain?.error {
            av_write_trailer(out)
            reportFailure(videoError)
            return
        }
        for buffered in pendingAudioPackets {
            let inIdx = buffered.pointee.stream_index
            if let outIdx = streamMap[inIdx],
               let inStream = ctx.pointee.streams[Int(inIdx)],
               let outStream = out.pointee.streams[Int(outIdx)] {
                if let chain = audioChain, chain.inputIndex == inIdx {
                    writeTranscodedAudio(chain: chain, packet: buffered, out: out, outStream: outStream)
                } else {
                    writeRemuxPacket(buffered, inStream: inStream, outStream: outStream, out: out)
                }
            }
            var bufferedPointer: UnsafeMutablePointer<AVPacket>? = buffered
            av_packet_free(&bufferedPointer)
        }
        pendingAudioPackets.removeAll()

        var pkt = AVPacket()
        av_init_packet(&pkt)
        while true {
            if isCancelled(session) { break }
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
            if let videoError = videoChain?.error {
                terminalError = videoError
                break
            }
            if !notified &&
                playlistReady(playlistPath: playlistPath, outDir: outDir, final: false) {
                notified = publishReady(
                    session: session,
                    sessionId: sessionId,
                    path: "\(sessionId)/index.m3u8",
                    onReady: onReady
                )
            }
        }

        if terminalError == nil && !isCancelled(session) {
            if let chain = audioChain,
               let outIndex = streamMap[chain.inputIndex],
               let outStream = out.pointee.streams[Int(outIndex)] {
                flushTranscodedAudio(chain: chain, out: out, outStream: outStream)
            }
            if let chain = videoChain, chain.initialized,
               let outIndex = streamMap[chain.inputIndex],
               let outStream = out.pointee.streams[Int(outIndex)] {
                flushTranscodedVideo(chain: chain, out: out, outStream: outStream)
            }
        }
        if let videoError = videoChain?.error {
            terminalError = terminalError ?? videoError
        }
        if let terminalError {
            av_write_trailer(out)
            reportFailure(terminalError)
            return
        }
        av_write_trailer(out)
        if !notified && playlistReady(playlistPath: playlistPath, outDir: outDir, final: true) {
            notified = publishReady(
                session: session,
                sessionId: sessionId,
                path: "\(sessionId)/index.m3u8",
                onReady: onReady
            )
        }
    }

    private static func playlistReady(playlistPath: String, outDir: URL, final: Bool) -> Bool {
        guard let playlist = try? String(contentsOfFile: playlistPath, encoding: .utf8),
              playlist.contains("#EXTINF"),
              FileManager.default.fileExists(atPath: outDir.appendingPathComponent("seg00000.ts").path) else {
            return false
        }
        if final { return true }
        return FileManager.default.fileExists(atPath: outDir.appendingPathComponent("seg00001.ts").path)
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
        let inputTimeBase: AVRational
        var timestampOrigin90k: Int64
        let swr: OpaquePointer
        let fifo: OpaquePointer
        var nextPts: Int64 = 0

        init(
            inputIndex: Int32,
            decCtx: UnsafeMutablePointer<AVCodecContext>,
            encCtx: UnsafeMutablePointer<AVCodecContext>,
            inputTimeBase: AVRational,
            timestampOrigin90k: Int64,
            swr: OpaquePointer,
            fifo: OpaquePointer
        ) {
            self.inputIndex = inputIndex
            self.decCtx = decCtx
            self.encCtx = encCtx
            self.inputTimeBase = inputTimeBase
            self.timestampOrigin90k = timestampOrigin90k
            self.swr = swr
            self.fifo = fifo
        }
    }

    private static func makeAudioChain(
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>,
        timestampOrigin90k: Int64
    ) -> AudioChain? {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(decoder) else { return nil }
        var encCtx: UnsafeMutablePointer<AVCodecContext>?
        var swr: OpaquePointer?
        var fifo: OpaquePointer?
        func fail() -> AudioChain? {
            var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
            avcodec_free_context(&dec)
            if encCtx != nil {
                var enc = encCtx
                avcodec_free_context(&enc)
            }
            if swr != nil { swr_free(&swr) }
            if fifo != nil { av_audio_fifo_free(fifo) }
            return nil
        }

        let sourceTimeBase = inputStream.pointee.time_base
        let packetTimeBase = sourceTimeBase.num != 0 && sourceTimeBase.den != 0
            ? sourceTimeBase : AVRational(num: 1, den: 48_000)
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0 else { return fail() }
        decCtx.pointee.pkt_timebase = packetTimeBase
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { return fail() }

        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_AAC),
              let allocatedEnc = avcodec_alloc_context3(encoder) else { return fail() }
        encCtx = allocatedEnc
        allocatedEnc.pointee.sample_rate = 48_000
        av_channel_layout_default(&allocatedEnc.pointee.ch_layout, 2)
        allocatedEnc.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        allocatedEnc.pointee.bit_rate = 256_000
        allocatedEnc.pointee.time_base = AVRational(num: 1, den: 48_000)
        guard avcodec_open2(allocatedEnc, encoder, nil) >= 0 else { return fail() }

        var inputLayout = decCtx.pointee.ch_layout
        var outputLayout = allocatedEnc.pointee.ch_layout
        swr_alloc_set_opts2(
            &swr, &outputLayout, AV_SAMPLE_FMT_FLTP, 48_000,
            &inputLayout, decCtx.pointee.sample_fmt, decCtx.pointee.sample_rate, 0, nil
        )
        guard let swr, swr_init(swr) >= 0 else { return fail() }
        guard let allocatedFifo = av_audio_fifo_alloc(
            AV_SAMPLE_FMT_FLTP,
            Int32(allocatedEnc.pointee.ch_layout.nb_channels),
            max(allocatedEnc.pointee.frame_size, 1)
        ) else { return fail() }
        fifo = allocatedFifo
        guard avcodec_parameters_from_context(outputStream.pointee.codecpar, allocatedEnc) >= 0 else {
            return fail()
        }
        outputStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        outputStream.pointee.time_base = AVRational(num: 1, den: 48_000)
        return AudioChain(
            inputIndex: inputStream.pointee.index,
            decCtx: decCtx,
            encCtx: allocatedEnc,
            inputTimeBase: packetTimeBase,
            timestampOrigin90k: timestampOrigin90k,
            swr: swr,
            fifo: allocatedFifo
        )
    }

    private static func writeTranscodedAudio(
        chain: AudioChain,
        packet: UnsafeMutablePointer<AVPacket>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        guard avcodec_send_packet(chain.decCtx, packet) >= 0 else { return }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        while let decoded = frame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
            writeTranscodedAudioFrame(chain: chain, decoded: decoded, out: out, outStream: outStream)
        }
    }

    private static func writeTranscodedAudioFrame(
        chain: AudioChain,
        decoded: UnsafeMutablePointer<AVFrame>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        let maxOut = max(1, Int(av_rescale_rnd(
            swr_get_delay(chain.swr, 48_000) + Int64(decoded.pointee.nb_samples),
            48_000, Int64(decoded.pointee.sample_rate), AV_ROUND_UP
        )))
        let bytes = maxOut * 2 * MemoryLayout<Float>.size
        guard let left = av_malloc(bytes)?.assumingMemoryBound(to: UInt8.self),
              let right = av_malloc(bytes)?.assumingMemoryBound(to: UInt8.self) else { return }
        defer { av_free(left); av_free(right) }
        var output: [UnsafeMutablePointer<UInt8>?] = [left, right]
        let data = decoded.pointee.data
        var input: [UnsafePointer<UInt8>?] = [
            UnsafePointer(data.0), UnsafePointer(data.1), UnsafePointer(data.2), UnsafePointer(data.3),
            UnsafePointer(data.4), UnsafePointer(data.5), UnsafePointer(data.6), UnsafePointer(data.7),
        ]
        let samples = Int(swr_convert(
            chain.swr, &output, Int32(maxOut), &input, decoded.pointee.nb_samples
        ))
        guard samples > 0 else { return }

        let common = AVRational(num: 1, den: 90_000)
        let proposedPTS: Int64
        if decoded.pointee.pts == Int64.min {
            proposedPTS = chain.nextPts
        } else {
            let sourcePTS = av_rescale_q(decoded.pointee.pts, chain.inputTimeBase, common)
            proposedPTS = av_rescale_q(
                max(0, sourcePTS - chain.timestampOrigin90k),
                common,
                chain.encCtx.pointee.time_base
            )
        }
        enqueueAudioSamples(
            chain: chain, left: left, right: right, sampleCount: samples, proposedPTS: proposedPTS,
            out: out, outStream: outStream
        )
    }

    private static func enqueueAudioSamples(
        chain: AudioChain,
        left: UnsafeMutablePointer<UInt8>,
        right: UnsafeMutablePointer<UInt8>,
        sampleCount: Int,
        proposedPTS: Int64,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        if av_audio_fifo_size(chain.fifo) == 0 {
            chain.nextPts = max(chain.nextPts, proposedPTS)
        }
        var planes: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(left), UnsafeMutableRawPointer(right)]
        guard planes.withUnsafeMutableBufferPointer({
            av_audio_fifo_write(chain.fifo, $0.baseAddress, Int32(sampleCount))
        }) == Int32(sampleCount) else { return }
        encodeAudioFrames(chain: chain, out: out, outStream: outStream, final: false)
    }

    private static func encodeAudioFrames(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>,
        final: Bool
    ) {
        let frameSize = max(Int(chain.encCtx.pointee.frame_size), 1)
        while true {
            let queued = Int(av_audio_fifo_size(chain.fifo))
            guard queued >= frameSize || (final && queued > 0) else { return }
            let samples = min(queued, frameSize)
            var encoded: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&encoded) }
            guard let frame = encoded else { return }
            frame.pointee.nb_samples = Int32(frameSize)
            frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            frame.pointee.sample_rate = 48_000
            av_channel_layout_copy(&frame.pointee.ch_layout, &chain.encCtx.pointee.ch_layout)
            guard av_frame_get_buffer(frame, 0) >= 0 else { return }
            var planes: [UnsafeMutableRawPointer?] = [
                UnsafeMutableRawPointer(frame.pointee.data.0), UnsafeMutableRawPointer(frame.pointee.data.1),
            ]
            guard planes.withUnsafeBufferPointer({
                av_audio_fifo_read(chain.fifo, $0.baseAddress, Int32(samples))
            }) == Int32(samples) else { return }
            if samples < frameSize {
                var silencePlanes: [UnsafeMutablePointer<UInt8>?] = [frame.pointee.data.0, frame.pointee.data.1]
                silencePlanes.withUnsafeMutableBufferPointer {
                    av_samples_set_silence(
                        $0.baseAddress, Int32(samples), Int32(frameSize - samples),
                        Int32(chain.encCtx.pointee.ch_layout.nb_channels), AV_SAMPLE_FMT_FLTP
                    )
                }
            }
            frame.pointee.pts = chain.nextPts
            chain.nextPts += Int64(frameSize)
            guard avcodec_send_frame(chain.encCtx, frame) >= 0 else { return }
            drainEncodedAudio(chain: chain, out: out, outStream: outStream)
            if samples < frameSize { return }
        }
    }

    private static func drainEncodedAudio(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var packet = AVPacket()
        av_init_packet(&packet)
        while avcodec_receive_packet(chain.encCtx, &packet) >= 0 {
            packet.stream_index = outStream.pointee.index
            av_packet_rescale_ts(&packet, chain.encCtx.pointee.time_base, outStream.pointee.time_base)
            packet.pos = -1
            av_interleaved_write_frame(out, &packet)
            av_packet_unref(&packet)
        }
    }

    private static func flushTranscodedAudio(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        if avcodec_send_packet(chain.decCtx, nil) >= 0 {
            var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&frame) }
            while let decoded = frame, avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
                writeTranscodedAudioFrame(chain: chain, decoded: decoded, out: out, outStream: outStream)
            }
        }
        while swr_get_delay(chain.swr, 48_000) > 0 {
            guard enqueueResamplerTail(chain: chain, out: out, outStream: outStream) else { break }
        }
        encodeAudioFrames(chain: chain, out: out, outStream: outStream, final: true)
        if avcodec_send_frame(chain.encCtx, nil) >= 0 {
            drainEncodedAudio(chain: chain, out: out, outStream: outStream)
        }
    }

    private static func enqueueResamplerTail(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) -> Bool {
        let capacity = max(1, Int(swr_get_delay(chain.swr, 48_000)) + 32)
        let bytes = capacity * 2 * MemoryLayout<Float>.size
        guard let left = av_malloc(bytes)?.assumingMemoryBound(to: UInt8.self),
              let right = av_malloc(bytes)?.assumingMemoryBound(to: UInt8.self) else { return false }
        defer { av_free(left); av_free(right) }
        var output: [UnsafeMutablePointer<UInt8>?] = [left, right]
        let samples = Int(swr_convert(chain.swr, &output, Int32(capacity), nil, 0))
        guard samples > 0 else { return false }
        enqueueAudioSamples(
            chain: chain, left: left, right: right, sampleCount: samples, proposedPTS: chain.nextPts,
            out: out, outStream: outStream
        )
        return true
    }

    // MARK: - Video transcode chain (VideoToolbox)

    private final class VideoChain {
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

    private static func makeVideoChain(
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
    private static func initializeVideoChain(
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
        let framesPtr = UnsafeMutableRawPointer(frames).assumingMemoryBound(to: AVHWFramesContext.self)
        framesPtr.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
        framesPtr.pointee.sw_format = AV_PIX_FMT_NV12
        framesPtr.pointee.width = outW
        framesPtr.pointee.height = outH
        framesPtr.pointee.initial_pool_size = 8
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
    private enum PrimeVideoResult {
        case fatal
        case needMoreInput
        case initialized
    }

    private static func retainPrimedFrame(
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

    private static func primeVideoPacket(
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

    private static func flushPrimingVideo(
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
    /// Derives a 90 kHz origin for the retained audio tail. Scans to the
    /// first usable PTS/DTS and subtracts known durations of earlier packets;
    /// a timestamp-less head must not disable the tail rebase.
    static func audioRingHeadPTS90k(
        _ packets: [UnsafeMutablePointer<AVPacket>],
        timeBase: AVRational
    ) -> Int64? {
        guard timeBase.num != 0, timeBase.den != 0 else { return nil }
        var durationBefore: Int64 = 0
        for packet in packets {
            let timestamp = packet.pointee.pts != Int64.min
                ? packet.pointee.pts
                : packet.pointee.dts
            if timestamp != Int64.min {
                return av_rescale_q(
                    timestamp - durationBefore,
                    timeBase,
                    AVRational(num: 1, den: 90_000)
                )
            }
            if packet.pointee.duration > 0 {
                durationBefore = min(Int64.max, durationBefore + packet.pointee.duration)
            }
        }
        return nil
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
    private static func transcodedBitrate(width: Int, height: Int) -> Int64 {
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

    private static func sourceFrameRate(inputStream: UnsafeMutablePointer<AVStream>) -> Double {
        sourceFrameRate(
            avg: inputStream.pointee.avg_frame_rate,
            nominal: inputStream.pointee.r_frame_rate
        )
    }

    private static func fpsHint(inputStream: UnsafeMutablePointer<AVStream>) -> Double {
        return min(max(sourceFrameRate(inputStream: inputStream), 15), 60)
    }

    private static func nextVideoPTS(_ decoded: UnsafeMutablePointer<AVFrame>, chain: VideoChain) -> Int64 {
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
            writeTranscodedVideoFrame(chain: chain, decoded: decoded, out: out, outStream: outStream)
        }
    }

    private static func drainPendingVideoFrames(
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

    private static func writeTranscodedVideoFrame(
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
            guard sws_scale_frame(scaler, scaled, decoded) == 0 else {
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

    private static func flushTranscodedVideo(
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
            av_audio_fifo_free(audio.fifo)
            var swr: OpaquePointer? = audio.swr
            swr_free(&swr)
            var dec: UnsafeMutablePointer<AVCodecContext>? = audio.decCtx
            avcodec_free_context(&dec)
            var enc: UnsafeMutablePointer<AVCodecContext>? = audio.encCtx
            avcodec_free_context(&enc)
        }
        video?.release()
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
