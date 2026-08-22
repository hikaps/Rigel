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
        onReady: @escaping (String?, String?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        let queue = DispatchQueue(label: "rigel-hls-\(sessionId)")
        lock.lock(); sessions[sessionId] = Session(queue: queue); lock.unlock()
        queue.async {
            run(
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

    private static func isCancelled(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[sessionId]?.cancel ?? true
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
            if notified {
                DispatchQueue.main.async { onError(message) }
            } else {
                notified = true
                DispatchQueue.main.async { onReady(nil, message) }
            }
        }

        defer {
            if !notified {
                notified = true
                DispatchQueue.main.async { onReady(nil, "session ended before playlist was ready") }
            }
            for packet in pendingAudioPackets {
                var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&packetPointer)
            }
            cleanup(ifmt: ifmt, ofmt: ofmt, audio: audioChain, video: videoChain)
            lock.lock(); sessions.removeValue(forKey: sessionId); lock.unlock()
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
            primingLoop: while !chain.initialized && !isCancelled(sessionId) {
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
            if let videoError = videoChain?.error {
                terminalError = videoError
                break
            }
            if !notified && FileManager.default.fileExists(atPath: playlistPath) {
                notified = true
                DispatchQueue.main.async { onReady("\(sessionId)/index.m3u8", nil) }
            }
        }

        if terminalError == nil && !isCancelled(sessionId) {
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
        let inputTimeBase: AVRational
        var timestampOrigin90k: Int64
        let swr: OpaquePointer
        var nextPts: Int64 = 0

        init(
            inputIndex: Int32,
            decCtx: UnsafeMutablePointer<AVCodecContext>,
            encCtx: UnsafeMutablePointer<AVCodecContext>,
            inputTimeBase: AVRational,
            timestampOrigin90k: Int64,
            swr: OpaquePointer
        ) {
            self.inputIndex = inputIndex
            self.decCtx = decCtx
            self.encCtx = encCtx
            self.inputTimeBase = inputTimeBase
            self.timestampOrigin90k = timestampOrigin90k
            self.swr = swr
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
        let sourceTimeBase = inputStream.pointee.time_base
        let packetTimeBase = sourceTimeBase.num != 0 && sourceTimeBase.den != 0
            ? sourceTimeBase
            : AVRational(num: 1, den: 48_000)
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0 else { return nil }
        decCtx.pointee.pkt_timebase = packetTimeBase
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { return nil }

        guard let aacEncoder = avcodec_find_encoder(AV_CODEC_ID_AAC),
              let encCtx = avcodec_alloc_context3(aacEncoder) else { return nil }
        encCtx.pointee.sample_rate = 48000
        av_channel_layout_default(&encCtx.pointee.ch_layout, 2)
        encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        encCtx.pointee.bit_rate = 256_000
        encCtx.pointee.time_base = AVRational(num: 1, den: 48_000)
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

        return AudioChain(
            inputIndex: inputStream.pointee.index,
            decCtx: decCtx,
            encCtx: encCtx,
            inputTimeBase: packetTimeBase,
            timestampOrigin90k: timestampOrigin90k,
            swr: swr
        )
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
            writeTranscodedAudioFrame(chain: chain, decoded: decoded, out: out, outStream: outStream)
        }
    }

    private static func writeTranscodedAudioFrame(
        chain: AudioChain,
        decoded: UnsafeMutablePointer<AVFrame>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        let maxOut = Int(av_rescale_rnd(
            swr_get_delay(chain.swr, 48000) + Int64(decoded.pointee.nb_samples),
            48000, Int64(decoded.pointee.sample_rate), AV_ROUND_UP))
        let planarBytes = maxOut * 2 * 4
        let buf0 = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self)
        let buf1 = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self)
        guard let buf0, let buf1 else { return }
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
        guard outSamples > 0 else { return }

        let audioTimeBase = AVRational(num: 1, den: 90_000)
        let proposedPTS: Int64
        if decoded.pointee.pts == Int64.min {
            proposedPTS = chain.nextPts
        } else {
            let sourcePTS = av_rescale_q(decoded.pointee.pts, chain.inputTimeBase, audioTimeBase)
            let rebasedPTS = max(0, sourcePTS - chain.timestampOrigin90k)
            proposedPTS = av_rescale_q(rebasedPTS, audioTimeBase, chain.encCtx.pointee.time_base)
        }
        encodeAudioSamples(
            chain: chain,
            left: buf0,
            right: buf1,
            sampleCount: outSamples,
            proposedPTS: proposedPTS,
            out: out,
            outStream: outStream
        )
    }

    private static func encodeAudioSamples(
        chain: AudioChain,
        left: UnsafeMutablePointer<UInt8>,
        right: UnsafeMutablePointer<UInt8>,
        sampleCount: Int,
        proposedPTS: Int64,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var encFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&encFrame) }
        guard let enc = encFrame else { return }
        enc.pointee.nb_samples = Int32(sampleCount)
        enc.pointee.format = Int32(AV_SAMPLE_FMT_FLTP.rawValue)
        enc.pointee.sample_rate = 48000
        av_channel_layout_copy(&enc.pointee.ch_layout, &chain.encCtx.pointee.ch_layout)
        guard av_frame_get_buffer(enc, 0) >= 0 else { return }
        memcpy(enc.pointee.data.0, left, sampleCount * 4)
        memcpy(enc.pointee.data.1, right, sampleCount * 4)
        enc.pointee.pts = max(proposedPTS, chain.nextPts)
        chain.nextPts = enc.pointee.pts + Int64(sampleCount)
        if avcodec_send_frame(chain.encCtx, enc) >= 0 {
            drainEncodedAudio(chain: chain, out: out, outStream: outStream)
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
        flushAudioResampler(chain: chain, out: out, outStream: outStream)
        if avcodec_send_frame(chain.encCtx, nil) >= 0 {
            drainEncodedAudio(chain: chain, out: out, outStream: outStream)
        }
    }

    private static func flushAudioResampler(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        let emptyInput = [UnsafePointer<UInt8>?](repeating: nil, count: 8)
        for _ in 0..<8 {
            let delay = swr_get_delay(chain.swr, 48_000)
            if delay <= 0 { break }
            let maxOut = max(1, Int(delay) + 32)
            let planarBytes = maxOut * 2 * 4
            guard let left = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self),
                  let right = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self) else { return }
            defer {
                av_free(left)
                av_free(right)
            }
            var outBufs: [UnsafeMutablePointer<UInt8>?] = [left, right]
            var input = emptyInput
            let samples = Int(swr_convert(
                chain.swr, &outBufs, Int32(maxOut), &input, 0
            ))
            if samples <= 0 { break }
            encodeAudioSamples(
                chain: chain,
                left: left,
                right: right,
                sampleCount: samples,
                proposedPTS: chain.nextPts,
                out: out,
                outStream: outStream
            )
        }
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
    }

    private static func makeVideoChain(
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>,
        timestampOrigin90k: Int64
    ) -> VideoChain? {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(decoder) else { return nil }
        let sourceTimeBase = inputStream.pointee.time_base
        let packetTimeBase = sourceTimeBase.num != 0 && sourceTimeBase.den != 0
            ? sourceTimeBase
            : AVRational(num: 1, den: 90_000)
        let encoderTimeBase = AVRational(num: 1, den: 90_000)
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0 else { return nil }
        decCtx.pointee.pkt_timebase = packetTimeBase
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { return nil }
        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_H264),
              let encCtx = avcodec_alloc_context3(encoder) else { return nil }
        encCtx.pointee.time_base = encoderTimeBase

        let chain = VideoChain(
            inputIndex: inputStream.pointee.index,
            decCtx: decCtx,
            encCtx: encCtx,
            inputTimeBase: packetTimeBase,
            timestampOrigin90k: timestampOrigin90k,
            frameRate: sourceFrameRate(inputStream: inputStream)
        )

        let codecFormat = AVPixelFormat(rawValue: codecpar.pointee.format)
        if codecFormat != AV_PIX_FMT_NONE && codecpar.pointee.width > 0 && codecpar.pointee.height > 0 {
            guard initializeVideoChain(
                chain,
                inputStream: inputStream,
                outputStream: outputStream,
                inputPixFmt: codecFormat,
                sourceWidth: codecpar.pointee.width,
                sourceHeight: codecpar.pointee.height
            ) else { return nil }
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
              let hwCtx,
              let raw = av_hwframe_ctx_alloc(hwCtx) else { return false }
        let framesRef = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: AVBufferRef.self)
        let framesPtr = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: AVHWFramesContext.self)
        framesPtr.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
        framesPtr.pointee.sw_format = AV_PIX_FMT_NV12
        framesPtr.pointee.width = outW
        framesPtr.pointee.height = outH
        framesPtr.pointee.initial_pool_size = 8
        guard av_hwframe_ctx_init(framesRef) >= 0 else { return false }

        var scaler: OpaquePointer? = nil
        var scaledFrame: UnsafeMutablePointer<AVFrame>? = nil
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
            guard av_frame_get_buffer(frame, 0) >= 0 else { return false }
            scaledFrame = frame
        }

        chain.encCtx.pointee.hw_frames_ctx = av_buffer_ref(framesRef)
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
              avcodec_open2(chain.encCtx, encoder, &encoderOptions) >= 0 else { return false }
        guard avcodec_parameters_from_context(outputStream.pointee.codecpar, chain.encCtx) >= 0 else { return false }
        outputStream.pointee.time_base = chain.encCtx.pointee.time_base

        chain.hwFramesCtx = framesRef
        chain.scaler = scaler
        chain.scaledFrame = scaledFrame
        chain.inputPixFmt = inputPixFmt
        chain.sourceWidth = sourceWidth
        chain.sourceHeight = sourceHeight
        chain.initialized = true
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
    /// PTS (90 kHz) of the oldest retained audio packet in the priming tail
    /// ring, used to rebase the shared timeline after eviction. Nil when the
    /// ring is empty or the packet carries no timestamp.
    static func audioRingHeadPTS90k(
        _ packets: [UnsafeMutablePointer<AVPacket>],
        timeBase: AVRational
    ) -> Int64? {
        guard timeBase.num != 0, timeBase.den != 0,
              let first = packets.first,
              first.pointee.pts != Int64.min else { return nil }
        return av_rescale_q(first.pointee.pts, timeBase, AVRational(num: 1, den: 90_000))
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

    static func repairVideoPTS(
        candidate: Int64?,
        previous: Int64?,
        frameDuration: Int64
    ) -> Int64 {
        guard let previous else { return max(candidate ?? 0, 0) }
        guard let candidate else { return previous + frameDuration }
        if candidate > previous {
            // Valid forward timestamp: keep its real cadence even when the
            // delta is smaller than the synthetic frame duration (120fps).
            return candidate
        }
        // Equal or regressed timestamp: re-space at one full frame duration.
        // Duplicate PTS would otherwise reach H.264/MPEG-TS unchanged and be
        // rejected or collapsed; a run of regressions must not compress the
        // timeline toward zero elapsed time.
        return previous + frameDuration
    }

    private static func sourceFrameRate(inputStream: UnsafeMutablePointer<AVStream>) -> Double {
        let rate = inputStream.pointee.avg_frame_rate
        if rate.den > 0 {
            let fps = Double(rate.num) / Double(rate.den)
            if fps.isFinite && fps > 0 { return fps }
        }
        return 30
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
        let pts = repairVideoPTS(
            candidate: candidate,
            previous: chain.hasVideoPTS ? chain.lastVideoPTS : nil,
            frameDuration: chain.frameDurationPTS
        )
        chain.lastVideoPTS = pts
        chain.hasVideoPTS = true
        return pts
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
            for frame in video.pendingFrames {
                var framePointer: UnsafeMutablePointer<AVFrame>? = frame
                av_frame_free(&framePointer)
            }
            video.pendingFrames.removeAll()
            if let scaled = video.scaledFrame {
                var scaledPointer: UnsafeMutablePointer<AVFrame>? = scaled
                av_frame_free(&scaledPointer)
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
