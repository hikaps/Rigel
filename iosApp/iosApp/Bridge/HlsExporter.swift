import Foundation

/// Local ffmpeg remux/transcode → HLS session. Writes segments + playlist into
/// Documents/proxy/<sessionId>/ and signals readiness when the playlist exists.
/// H.264 video is stream-copied; other video codecs are converted to H.264.
/// Audio is copied when compatible with the selected mode, otherwise converted
/// to AAC.
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
        var setupError: String?
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
                // HLS output uses MPEG-TS. AVPlayer accepts H.264 there, but
                // HEVC/other codecs can leave audio playing with no video
                // output. Keep H.264 as a stream copy and transcode everything
                // else to 8-bit H.264 in software.
                if codecpar.pointee.codec_id == AV_CODEC_ID_H264 {
                    if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 {
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        outStream.pointee.time_base = inStream.pointee.time_base
                    }
                } else if let chain = makeVideoChain(inputStream: inStream, outputStream: outStream) {
                    videoChain = chain
                } else {
                    setupError = "video transcode setup failed"
                    break
                }
            case AVMEDIA_TYPE_AUDIO:
                // AAC/MP3 are TS-compatible; stream-copy them so we never
                // re-encode (the AAC encoder rejects decoded frames larger
                // than its frame size). Everything else decodes to AAC.
                if let name = codecName(codecpar.pointee.codec_id),
                   (name == "aac" || name == "mp3") {
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

        if let setupError {
            notified = true
            DispatchQueue.main.async { onReady(nil, setupError) }
            return
        }
        let headerRet = avformat_write_header(out, nil)
        guard headerRet >= 0 else {
            DispatchQueue.main.async { onReady(nil, "HLS write header failed: \(avErrorString(headerRet))") }
            return
        }

        var pkt = AVPacket()
        av_init_packet(&pkt)
        var cancelled = false
        var reachedEnd = false
        while true {
            if isCancelled(sessionId) {
                cancelled = true
                break
            }
            let readRet = av_read_frame(ctx, &pkt)
            if readRet < 0 {
                reachedEnd = true
                break
            }
            let inIdx = pkt.stream_index
            if let outIdx = streamMap[inIdx],
               let inStream = ctx.pointee.streams[Int(inIdx)],
               let outStream = out.pointee.streams[Int(outIdx)] {
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
                if !notified && playlistReady(playlistPath: playlistPath, outDir: outDir, final: false) {
                    notified = true
                    DispatchQueue.main.async { onReady("\(sessionId)/index.m3u8", nil) }
                }
            }
            av_packet_unref(&pkt)
        }

        guard reachedEnd, !cancelled else { return }
        if let chain = audioChain,
           let outStream = out.pointee.streams[Int(chain.outputIndex)] {
            flushTranscodedAudio(chain: chain, out: out, outStream: outStream)
        }
        if let chain = videoChain,
           let outStream = out.pointee.streams[Int(chain.outputIndex)] {
            flushTranscodedVideo(chain: chain, out: out, outStream: outStream)
        }
        av_write_trailer(out)
        if !notified && playlistReady(playlistPath: playlistPath, outDir: outDir, final: true) {
            notified = true
            DispatchQueue.main.async { onReady("\(sessionId)/index.m3u8", nil) }
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
        let outputIndex: Int32
        let decCtx: UnsafeMutablePointer<AVCodecContext>
        let encCtx: UnsafeMutablePointer<AVCodecContext>
        let swr: OpaquePointer
        let fifo: OpaquePointer
        var nextPts: Int64 = 0

        init(
            inputIndex: Int32,
            outputIndex: Int32,
            decCtx: UnsafeMutablePointer<AVCodecContext>,
            encCtx: UnsafeMutablePointer<AVCodecContext>,
            swr: OpaquePointer,
            fifo: OpaquePointer
        ) {
            self.inputIndex = inputIndex
            self.outputIndex = outputIndex
            self.decCtx = decCtx
            self.encCtx = encCtx
            self.swr = swr
            self.fifo = fifo
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

        guard let fifo = av_audio_fifo_alloc(
            AV_SAMPLE_FMT_FLTP,
            Int32(encCtx.pointee.ch_layout.nb_channels),
            max(encCtx.pointee.frame_size, 1)
        ) else { return nil }
        return AudioChain(
            inputIndex: inputStream.pointee.index,
            outputIndex: outputStream.pointee.index,
            decCtx: decCtx,
            encCtx: encCtx,
            swr: swr,
            fifo: fifo
        )
    }
    private static func writeTranscodedAudio(
        chain: AudioChain,
        packet: UnsafeMutablePointer<AVPacket>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        let ret = avcodec_send_packet(chain.decCtx, packet)
        guard ret >= 0 else {
            NSLog("[RigelHls] audio decoder rejected packet: %@", avErrorString(ret))
            return
        }
        var decoded: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&decoded) }
        if let decoded {
            drainDecodedAudio(chain: chain, frame: decoded, out: out, outStream: outStream)
        }
    }

    private static func drainDecodedAudio(
        chain: AudioChain,
        frame: UnsafeMutablePointer<AVFrame>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        while avcodec_receive_frame(chain.decCtx, frame) >= 0 {
            _ = resampleAudio(chain: chain, decoded: frame)
            encodeAudioFrames(chain: chain, out: out, outStream: outStream, final: false)
        }
    }

    private static func resampleAudio(
        chain: AudioChain,
        decoded: UnsafeMutablePointer<AVFrame>?
    ) -> Int {
        let inputSamples = Int32(decoded?.pointee.nb_samples ?? 0)
        let inputRate = Int64(decoded?.pointee.sample_rate ?? 48000)
        let maxOut = max(1, Int(av_rescale_rnd(
            swr_get_delay(chain.swr, 48000) + Int64(inputSamples),
            48000,
            inputRate,
            AV_ROUND_UP
        )))
        let planarBytes = maxOut * 2 * MemoryLayout<Float>.size
        guard let buf0 = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self),
              let buf1 = av_malloc(planarBytes)?.assumingMemoryBound(to: UInt8.self) else {
            NSLog("[RigelHls] audio resampler allocation failed")
            return 0
        }
        defer {
            av_free(buf0)
            av_free(buf1)
        }

        var outBufs: [UnsafeMutablePointer<UInt8>?] = [buf0, buf1]
        var inData: [UnsafePointer<UInt8>?] = Array(repeating: nil, count: 8)
        if let decoded {
            let rawData = decoded.pointee.data
            inData = [
                UnsafePointer(rawData.0), UnsafePointer(rawData.1), UnsafePointer(rawData.2),
                UnsafePointer(rawData.3), UnsafePointer(rawData.4), UnsafePointer(rawData.5),
                UnsafePointer(rawData.6), UnsafePointer(rawData.7),
            ]
        }
        let outSamples = Int(swr_convert(
            chain.swr,
            &outBufs,
            Int32(maxOut),
            &inData,
            inputSamples
        ))
        guard outSamples > 0 else { return 0 }
        var fifoBufs: [UnsafeMutableRawPointer?] = [
            UnsafeMutableRawPointer(buf0), UnsafeMutableRawPointer(buf1),
        ]
        let written = Int(fifoBufs.withUnsafeMutableBufferPointer { buffer in
            av_audio_fifo_write(chain.fifo, buffer.baseAddress, Int32(outSamples))
        })
        guard written == outSamples else {
            NSLog("[RigelHls] audio FIFO write failed: wrote %d of %d samples", written, outSamples)
            return max(written, 0)
        }
        return written
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
            var encFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&encFrame) }
            guard let enc = encFrame else { return }
            enc.pointee.nb_samples = Int32(frameSize)
            enc.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            enc.pointee.sample_rate = 48000
            av_channel_layout_copy(&enc.pointee.ch_layout, &chain.encCtx.pointee.ch_layout)
            guard av_frame_get_buffer(enc, 0) >= 0 else {
                NSLog("[RigelHls] AAC frame allocation failed")
                return
            }

            var planes: [UnsafeMutableRawPointer?] = [
                UnsafeMutableRawPointer(enc.pointee.data.0),
                UnsafeMutableRawPointer(enc.pointee.data.1),
            ]
            let read = planes.withUnsafeBufferPointer { buffer in
                av_audio_fifo_read(chain.fifo, buffer.baseAddress, Int32(samples))
            }
            guard read == Int32(samples) else {
                NSLog("[RigelHls] audio FIFO read failed: read %d of %d samples", read, samples)
                return
            }
            if samples < frameSize {
                var samplePlanes: [UnsafeMutablePointer<UInt8>?] = [
                    enc.pointee.data.0, enc.pointee.data.1,
                ]
                samplePlanes.withUnsafeMutableBufferPointer { buffer in
                    av_samples_set_silence(
                        buffer.baseAddress,
                        Int32(samples),
                        Int32(frameSize - samples),
                        Int32(chain.encCtx.pointee.ch_layout.nb_channels),
                        AV_SAMPLE_FMT_FLTP
                    )
                }
            }
            enc.pointee.pts = chain.nextPts
            chain.nextPts += Int64(frameSize)
            let ret = avcodec_send_frame(chain.encCtx, enc)
            guard ret >= 0 else {
                NSLog("[RigelHls] AAC encoder rejected frame: %@", avErrorString(ret))
                return
            }
            drainEncodedAudio(chain: chain, out: out, outStream: outStream)
            if samples < frameSize { return }
        }
    }

    private static func flushTranscodedAudio(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var decoded: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&decoded) }
        let decoderRet = avcodec_send_packet(chain.decCtx, nil)
        if decoderRet < 0 {
            NSLog("[RigelHls] audio decoder flush failed: %@", avErrorString(decoderRet))
        } else if let decoded {
            drainDecodedAudio(chain: chain, frame: decoded, out: out, outStream: outStream)
        }

        while swr_get_delay(chain.swr, 48000) > 0 {
            guard resampleAudio(chain: chain, decoded: nil) > 0 else { break }
            encodeAudioFrames(chain: chain, out: out, outStream: outStream, final: false)
        }
        encodeAudioFrames(chain: chain, out: out, outStream: outStream, final: true)

        let encoderRet = avcodec_send_frame(chain.encCtx, nil)
        if encoderRet < 0 {
            NSLog("[RigelHls] AAC encoder flush failed: %@", avErrorString(encoderRet))
        }
        drainEncodedAudio(chain: chain, out: out, outStream: outStream)
    }

    private static func drainEncodedAudio(
        chain: AudioChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var encPkt = AVPacket()
        av_init_packet(&encPkt)
        while avcodec_receive_packet(chain.encCtx, &encPkt) >= 0 {
            encPkt.stream_index = outStream.pointee.index
            av_packet_rescale_ts(&encPkt, chain.encCtx.pointee.time_base, outStream.pointee.time_base)
            encPkt.pos = -1
            let ret = av_interleaved_write_frame(out, &encPkt)
            if ret < 0 {
                NSLog("[RigelHls] AAC packet write failed: %@", avErrorString(ret))
            }
            av_packet_unref(&encPkt)
        }
    }

    // MARK: - Video transcode chain (VideoToolbox)

    private final class VideoChain {
        let inputIndex: Int32
        let outputIndex: Int32
        let inTimeBase: AVRational
        let decCtx: UnsafeMutablePointer<AVCodecContext>
        let encCtx: UnsafeMutablePointer<AVCodecContext>
        let bsf: UnsafeMutablePointer<AVBSFContext>?
        // Lazily built on the first decoded frame; stored in a box so the
        // per-frame write path can cache it.
        let scalerBox: UnsafeMutablePointer<OpaquePointer?>

        init(
            inputIndex: Int32,
            outputIndex: Int32,
            inTimeBase: AVRational,
            decCtx: UnsafeMutablePointer<AVCodecContext>,
            encCtx: UnsafeMutablePointer<AVCodecContext>,
            bsf: UnsafeMutablePointer<AVBSFContext>?
        ) {
            self.inputIndex = inputIndex
            self.outputIndex = outputIndex
            self.inTimeBase = inTimeBase
            self.decCtx = decCtx
            self.encCtx = encCtx
            self.bsf = bsf
            self.scalerBox = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
            self.scalerBox.pointee = nil
        }

        func release() {
            if let sws = scalerBox.pointee { sws_freeContext(sws) }
            scalerBox.deallocate()
            var bsf = bsf
            av_bsf_free(&bsf)
            var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
            avcodec_free_context(&dec)
            var enc: UnsafeMutablePointer<AVCodecContext>? = encCtx
            avcodec_free_context(&enc)
        }
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

        // Software H.264 encode via VideoToolbox: HEVC sources decode to
        // formats (e.g. 10-bit 4:2:0) that direct upload rejects, so frames
        // are converted to an even 720p-class yuv420p output. Some Apple
        // HLS paths reject unusual source dimensions such as 1800x1080.
        let sourceWidth = max(codecpar.pointee.width, 2)
        let sourceHeight = max(codecpar.pointee.height, 2)
        let targetWidth = min(sourceWidth, 1280)
        let targetHeight = max(2, (sourceHeight * targetWidth / sourceWidth) & ~1)
        encCtx.pointee.width = targetWidth
        encCtx.pointee.height = targetHeight
        encCtx.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        encCtx.pointee.time_base = AVRational(num: 1, den: 30)
        encCtx.pointee.framerate = AVRational(num: 30, den: 1)
        encCtx.pointee.bit_rate = 8_000_000
        encCtx.pointee.gop_size = 60
        encCtx.pointee.flags2 |= AV_CODEC_FLAG2_LOCAL_HEADER
        guard avcodec_open2(encCtx, encoder, nil) >= 0 else { return nil }

        guard let filter = av_bsf_get_by_name("h264_mp4toannexb") else { return nil }
        var bsf: UnsafeMutablePointer<AVBSFContext>? = nil
        guard av_bsf_alloc(filter, &bsf) >= 0, let bsf,
              avcodec_parameters_from_context(bsf.pointee.par_in, encCtx) >= 0 else { return nil }
        bsf.pointee.time_base_in = encCtx.pointee.time_base
        guard av_bsf_init(bsf) >= 0 else {
            var failedBsf: UnsafeMutablePointer<AVBSFContext>? = bsf
            av_bsf_free(&failedBsf)
            return nil
        }
        avcodec_parameters_copy(outputStream.pointee.codecpar, bsf.pointee.par_out)
        outputStream.pointee.time_base = bsf.pointee.time_base_out

        return VideoChain(
            inputIndex: inputStream.pointee.index,
            outputIndex: outputStream.pointee.index,
            inTimeBase: inputStream.pointee.time_base,
            decCtx: decCtx,
            encCtx: encCtx,
            bsf: bsf
        )
    }
    private static func writeTranscodedVideo(
        chain: VideoChain,
        packet: UnsafeMutablePointer<AVPacket>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        let ret = avcodec_send_packet(chain.decCtx, packet)
        guard ret >= 0 else {
            NSLog("[RigelHls] video decoder rejected packet: %@", avErrorString(ret))
            return
        }
        var decoded: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        var converted: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_frame_free(&decoded)
            av_frame_free(&converted)
        }
        guard let src = decoded, let dst = converted else { return }
        drainDecodedVideo(chain: chain, decoded: src, converted: dst, out: out, outStream: outStream)
    }

    private static func drainDecodedVideo(
        chain: VideoChain,
        decoded: UnsafeMutablePointer<AVFrame>,
        converted: UnsafeMutablePointer<AVFrame>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        while avcodec_receive_frame(chain.decCtx, decoded) >= 0 {
            convertVideoFrame(
                chain: chain,
                src: decoded,
                dst: converted,
                out: out,
                outStream: outStream
            )
        }
    }

    private static func convertVideoFrame(
        chain: VideoChain,
        src: UnsafeMutablePointer<AVFrame>,
        dst: UnsafeMutablePointer<AVFrame>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        // av_frame_get_buffer allocates owned planes; release the previous
        // frame before allocating the next converted image.
        av_frame_unref(dst)
        let srcPixFmt = AVPixelFormat(rawValue: Int32(src.pointee.format))
        guard sws_isSupportedInput(srcPixFmt) != 0,
              src.pointee.width > 0,
              src.pointee.height > 0 else { return }

        dst.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        dst.pointee.width = chain.encCtx.pointee.width
        dst.pointee.height = chain.encCtx.pointee.height
        guard av_frame_get_buffer(dst, 0) >= 0 else {
            NSLog("[RigelHls] converted video frame allocation failed")
            return
        }

        if chain.scalerBox.pointee == nil {
            guard let built = sws_getContext(
                src.pointee.width,
                src.pointee.height,
                srcPixFmt,
                chain.encCtx.pointee.width,
                chain.encCtx.pointee.height,
                AV_PIX_FMT_YUV420P,
                SWS_BILINEAR,
                nil, nil, nil
            ) else {
                NSLog("[RigelHls] video scaler setup failed")
                av_frame_unref(dst)
                return
            }
            chain.scalerBox.pointee = built
        }
        guard let activeSws = chain.scalerBox.pointee else {
            av_frame_unref(dst)
            return
        }

        var srcPlanes: [UnsafePointer<UInt8>?] = [
            UnsafePointer(src.pointee.data.0), UnsafePointer(src.pointee.data.1),
            UnsafePointer(src.pointee.data.2), UnsafePointer(src.pointee.data.3),
            UnsafePointer(src.pointee.data.4), UnsafePointer(src.pointee.data.5),
            UnsafePointer(src.pointee.data.6), UnsafePointer(src.pointee.data.7),
        ]
        var srcStrides: [Int32] = [
            src.pointee.linesize.0, src.pointee.linesize.1, src.pointee.linesize.2,
            src.pointee.linesize.3, src.pointee.linesize.4, src.pointee.linesize.5,
            src.pointee.linesize.6, src.pointee.linesize.7,
        ]
        var dstPlanes: [UnsafeMutablePointer<UInt8>?] = [
            dst.pointee.data.0, dst.pointee.data.1, dst.pointee.data.2, dst.pointee.data.3,
            dst.pointee.data.4, dst.pointee.data.5, dst.pointee.data.6, dst.pointee.data.7,
        ]
        var dstStrides: [Int32] = [
            dst.pointee.linesize.0, dst.pointee.linesize.1, dst.pointee.linesize.2,
            dst.pointee.linesize.3, dst.pointee.linesize.4, dst.pointee.linesize.5,
            dst.pointee.linesize.6, dst.pointee.linesize.7,
        ]
        srcPlanes.withUnsafeBufferPointer { sp in
            srcStrides.withUnsafeBufferPointer { sst in
                dstPlanes.withUnsafeBufferPointer { dp in
                    dstStrides.withUnsafeBufferPointer { dstt in
                        _ = sws_scale(
                            activeSws,
                            sp.baseAddress,
                            sst.baseAddress,
                            0,
                            src.pointee.height,
                            dp.baseAddress,
                            dstt.baseAddress
                        )
                    }
                }
            }
        }
        dst.pointee.pts = av_rescale_q(src.pointee.pts, chain.inTimeBase, chain.encCtx.pointee.time_base)
        let ret = avcodec_send_frame(chain.encCtx, dst)
        if ret < 0 {
            NSLog("[RigelHls] H.264 encoder rejected frame: %@", avErrorString(ret))
        } else {
            drainEncodedVideo(chain: chain, out: out, outStream: outStream)
        }
        av_frame_unref(dst)
    }

    private static func flushTranscodedVideo(
        chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var decoded: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        var converted: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer {
            av_frame_free(&decoded)
            av_frame_free(&converted)
        }
        let decoderRet = avcodec_send_packet(chain.decCtx, nil)
        if decoderRet < 0 {
            NSLog("[RigelHls] video decoder flush failed: %@", avErrorString(decoderRet))
        } else if let decoded, let converted {
            drainDecodedVideo(
                chain: chain,
                decoded: decoded,
                converted: converted,
                out: out,
                outStream: outStream
            )
        }

        let encoderRet = avcodec_send_frame(chain.encCtx, nil)
        if encoderRet < 0 {
            NSLog("[RigelHls] H.264 encoder flush failed: %@", avErrorString(encoderRet))
        }
        drainEncodedVideo(chain: chain, out: out, outStream: outStream)
        flushVideoBitstreamFilter(chain: chain, out: out, outStream: outStream)
    }

    private static func drainEncodedVideo(
        chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var encPkt = AVPacket()
        av_init_packet(&encPkt)
        while avcodec_receive_packet(chain.encCtx, &encPkt) >= 0 {
            if let bsf = chain.bsf {
                let ret = av_bsf_send_packet(bsf, &encPkt)
                av_packet_unref(&encPkt)
                guard ret >= 0 else {
                    NSLog("[RigelHls] H.264 bitstream filter rejected packet: %@", avErrorString(ret))
                    continue
                }
                drainFilteredVideo(chain: chain, out: out, outStream: outStream)
            } else {
                writeVideoPacket(
                    &encPkt,
                    packetTimeBase: chain.encCtx.pointee.time_base,
                    out: out,
                    outStream: outStream
                )
                av_packet_unref(&encPkt)
            }
        }
    }

    private static func flushVideoBitstreamFilter(
        chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        guard let bsf = chain.bsf else { return }
        let ret = av_bsf_send_packet(bsf, nil)
        guard ret >= 0 else {
            NSLog("[RigelHls] H.264 bitstream filter flush failed: %@", avErrorString(ret))
            return
        }
        drainFilteredVideo(chain: chain, out: out, outStream: outStream)
    }

    private static func drainFilteredVideo(
        chain: VideoChain,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        guard let bsf = chain.bsf else { return }
        var filtered = AVPacket()
        av_init_packet(&filtered)
        while av_bsf_receive_packet(bsf, &filtered) >= 0 {
            writeVideoPacket(
                &filtered,
                packetTimeBase: bsf.pointee.time_base_out,
                out: out,
                outStream: outStream
            )
            av_packet_unref(&filtered)
        }
    }

    private static func writeVideoPacket(
        _ packet: UnsafeMutablePointer<AVPacket>,
        packetTimeBase: AVRational,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        packet.pointee.stream_index = outStream.pointee.index
        if packet.pointee.duration <= 0 { packet.pointee.duration = 1 }
        av_packet_rescale_ts(packet, packetTimeBase, outStream.pointee.time_base)
        packet.pointee.pos = -1
        let ret = av_interleaved_write_frame(out, packet)
        if ret < 0 {
            NSLog("[RigelHls] H.264 packet write failed: %@", avErrorString(ret))
        }
    }

    // MARK: - Helpers

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
            av_audio_fifo_free(audio.fifo)
        }
        if let video {
            video.release()
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
