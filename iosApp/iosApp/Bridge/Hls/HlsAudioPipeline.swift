import Foundation

final class AudioChain {
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

extension RigelHlsExporter {
    static func makeAudioChain(
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

    static func writeTranscodedAudio(
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

    static func writeTranscodedAudioFrame(
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

    static func enqueueAudioSamples(
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

    static func encodeAudioFrames(
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

    static func drainEncodedAudio(
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

    static func flushTranscodedAudio(
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

    static func enqueueResamplerTail(
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
}
