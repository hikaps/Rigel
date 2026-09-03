import Foundation

extension RigelHlsExporter {
    static func closeInput(_ fmt: inout UnsafeMutablePointer<AVFormatContext>?) {
        avformat_close_input(&fmt)
    }

    static func openInput(url: String, headers: [String: String], fmt: inout UnsafeMutablePointer<AVFormatContext>?) -> Bool {
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
            if avformat_find_stream_info(fmt, nil) < 0 {
                closeInput(&fmt)
                return
            }
            opened = true
        }
        return opened
    }

    static func cleanup(
        ifmt: UnsafeMutablePointer<AVFormatContext>?,
        ofmt: UnsafeMutablePointer<AVFormatContext>?,
        audio: [AudioChain],
        video: VideoChain?,
        subtitleInputs: [SubtitleInput],
        subtitles: [SubtitleChain]
    ) {
        var ifmtPtr: UnsafeMutablePointer<AVFormatContext>? = ifmt
        avformat_close_input(&ifmtPtr)
        var closedExternalIDs = Set<Int>()
        for input in subtitleInputs where input.sourceID != 0 && closedExternalIDs.insert(input.sourceID).inserted {
            var inputPtr: UnsafeMutablePointer<AVFormatContext>? = input.context
            avformat_close_input(&inputPtr)
        }
        if let ofmt { avformat_free_context(ofmt) }
        for audioChain in audio {
            av_audio_fifo_free(audioChain.fifo)
            var swr: OpaquePointer? = audioChain.swr
            swr_free(&swr)
            var dec: UnsafeMutablePointer<AVCodecContext>? = audioChain.decCtx
            avcodec_free_context(&dec)
            var enc: UnsafeMutablePointer<AVCodecContext>? = audioChain.encCtx
            avcodec_free_context(&enc)
        }
        for subtitleChain in subtitles {
            subtitleChain.release()
        }
        video?.release()
    }

    static func codecName(_ id: AVCodecID) -> String? {
        guard let name = avcodec_get_name(id) else { return nil }
        return String(cString: name)
    }

    static func avErrorString(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        av_strerror(code, &buf, buf.count)
        return String(cString: buf)
    }
}
