import Foundation

/// Bounds blocking FFmpeg I/O for external sidecar subtitle inputs. FFmpeg's
/// network stack has no default request timeout: a remote sidecar whose
/// server accepts the connection and then goes silent would block the
/// session queue forever, leaving playback stuck in "preparing". All reads
/// for one input happen on that session's serial queue, so plain fields are
/// sufficient (the C interrupt callback runs on the same thread).
final class InputWatchdog {
    private enum Phase {
        /// Connect + probe must complete within the total budget.
        case opening(until: DispatchTime)
        /// While reading, any single blocked read longer than the budget
        /// aborts; the budget resets after every successful read.
        case reading(idleLimit: DispatchTimeInterval, lastActivity: DispatchTime)
    }

    private var phase: Phase
    private let budget: DispatchTimeInterval

    init(timeoutSeconds: Int) {
        self.budget = .seconds(timeoutSeconds)
        self.phase = .opening(until: .now() + .seconds(timeoutSeconds))
    }

    func shouldAbort() -> Bool {
        switch phase {
        case let .opening(until):
            return DispatchTime.now() >= until
        case let .reading(idleLimit, lastActivity):
            return DispatchTime.now() >= lastActivity + idleLimit
        }
    }

    /// Called once after a successful open: switches to the per-read idle
    /// policy used for the rest of the session.
    func startReading() {
        phase = .reading(idleLimit: budget, lastActivity: .now())
    }

    /// Called after every successful read so active transfers never abort.
    func touch() {
        if case let .reading(idleLimit, _) = phase {
            phase = .reading(idleLimit: idleLimit, lastActivity: .now())
        }
    }
}

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

    /// openInput for external sidecar sources, bounded by `watchdog`:
    /// connect+probe must finish within the budget, and a stalled read later
    /// in the session aborts that sidecar (drops its cues) instead of
    /// freezing the whole session.
    static func openSidecarInput(
        url: String,
        headers: [String: String],
        watchdog: InputWatchdog,
        fmt: inout UnsafeMutablePointer<AVFormatContext>?
    ) -> Bool {
        guard let allocated = avformat_alloc_context() else {
            return openInput(url: url, headers: headers, fmt: &fmt)
        }
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                let watchdog = Unmanaged<InputWatchdog>.fromOpaque(opaque).takeUnretainedValue()
                return watchdog.shouldAbort() ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(watchdog).toOpaque()
        )
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
            // On failure avformat_open_input frees the context and nulls it.
            let ret = avformat_open_input(&context, cstr, nil, &opts)
            if opts != nil { av_dict_free(&opts) }
            guard ret >= 0, context != nil else { return }
            if avformat_find_stream_info(context, nil) < 0 {
                closeInput(&context)
                return
            }
            opened = true
        }
        if opened {
            watchdog.startReading()
            fmt = context
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
