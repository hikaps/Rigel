import Foundation

/// Bounds blocking FFmpeg I/O for external sidecar subtitle inputs and native
/// probes. The state is shared with AVIOInterruptCB, so every read of the
/// deadline/cancellation state is synchronized with callers on other queues.
final class InputWatchdog {
    private enum Phase {
        /// Connect + probe must complete within the total budget.
        case opening(until: DispatchTime)
        /// While reading, any single blocked read longer than the budget
        /// aborts; the budget resets after every successful read.
        case reading(idleLimit: DispatchTimeInterval, lastActivity: DispatchTime)
        case cancelled
    }

    private let lock = NSLock()
    private var phase: Phase
    private let budget: DispatchTimeInterval

    init(timeoutSeconds: Int) {
        self.budget = .seconds(timeoutSeconds)
        self.phase = .opening(until: .now() + .seconds(timeoutSeconds))
    }

    func shouldAbort() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .cancelled:
            return true
        case let .opening(until):
            return DispatchTime.now() >= until
        case let .reading(idleLimit, lastActivity):
            return DispatchTime.now() >= lastActivity + idleLimit
        }
    }

    func cancel() {
        lock.lock()
        phase = .cancelled
        lock.unlock()
    }

    /// Called once after a successful open: switches to the per-read idle
    /// policy used for the rest of the session.
    func startReading() {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = phase { return }
        phase = .reading(idleLimit: budget, lastActivity: .now())
    }

    /// Called after every successful read so active transfers never abort.
    func touch() {
        lock.lock()
        defer { lock.unlock() }
        if case let .reading(idleLimit, _) = phase {
            phase = .reading(idleLimit: idleLimit, lastActivity: .now())
        }
    }
}

private let rigelInputTimeoutMicroseconds: Int64 = 10_000_000

extension RigelHlsExporter {
    static func closeInput(_ fmt: inout UnsafeMutablePointer<AVFormatContext>?) {
        avformat_close_input(&fmt)
    }

    /// Opens a source with bounded FFmpeg I/O. A caller-owned watchdog adds
    /// cancellation/deadline interrupts; nil keeps the primary-source API
    /// usable before Session wiring while rw_timeout still bounds blocking I/O.
    static func openInput(
        url: String,
        headers: [String: String],
        watchdog: InputWatchdog? = nil,
        fmt: inout UnsafeMutablePointer<AVFormatContext>?
    ) -> Bool {
        guard let allocated = avformat_alloc_context() else {
            return false
        }
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        if let watchdog {
            allocated.pointee.interrupt_callback = AVIOInterruptCB(
                callback: { opaque in
                    guard let opaque else { return 0 }
                    let watchdog = Unmanaged<InputWatchdog>.fromOpaque(opaque).takeUnretainedValue()
                    return watchdog.shouldAbort() ? 1 : 0
                },
                opaque: Unmanaged.passUnretained(watchdog).toOpaque()
            )
        }
        var opened = false
        url.withCString { cstr in
            var opts: OpaquePointer? = nil
            defer { if opts != nil { av_dict_free(&opts) } }
            for (key, value) in headers {
                key.withCString { k in
                    value.withCString { v in
                        av_dict_set(&opts, k, v, 0)
                    }
                }
            }
            // Match the probe's analysis cap so session open does not pay the
            // default 5 s budget again on network sources.
            av_dict_set(&opts, "analyzeduration", "2000000", 0)
            av_dict_set(&opts, "rw_timeout", String(rigelInputTimeoutMicroseconds), 0)
            let ret = avformat_open_input(&context, cstr, nil, &opts)
            guard ret >= 0, context != nil else {
                closeInput(&context)
                return
            }
            if avformat_find_stream_info(context, nil) < 0 {
                closeInput(&context)
                return
            }
            opened = true
        }
        guard opened, let openedContext = context else {
            closeInput(&context)
            return false
        }
        watchdog?.startReading()
        fmt = openedContext
        return true
    }

    /// openInput for external sidecar sources, bounded by watchdog:
    /// connect+probe must finish within the budget, and a stalled read later
    /// in the session aborts that sidecar (drops its cues) instead of
    /// freezing the whole session.
    static func openSidecarInput(
        url rawURL: String,
        headers: [String: String],
        watchdog: InputWatchdog,
        fmt: inout UnsafeMutablePointer<AVFormatContext>?
    ) -> Bool {
        // FFmpeg's file protocol does not decode percent-escapes, so
        // resolve percent-encoded file URLs (absoluteString) to plain paths.
        let url: String
        if let fileURL = URL(string: rawURL), fileURL.isFileURL {
            url = fileURL.path(percentEncoded: false)
        } else {
            url = rawURL
        }
        guard let allocated = avformat_alloc_context() else {
            return false
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
            defer { if opts != nil { av_dict_free(&opts) } }
            for (key, value) in headers {
                key.withCString { k in
                    value.withCString { v in
                        av_dict_set(&opts, k, v, 0)
                    }
                }
            }
            av_dict_set(&opts, "analyzeduration", "2000000", 0)
            av_dict_set(&opts, "rw_timeout", String(rigelInputTimeoutMicroseconds), 0)
            let ret = avformat_open_input(&context, cstr, nil, &opts)
            guard ret >= 0, context != nil else {
                closeInput(&context)
                return
            }
            if avformat_find_stream_info(context, nil) < 0 {
                closeInput(&context)
                return
            }
            opened = true
        }
        guard opened, let openedContext = context else {
            closeInput(&context)
            return false
        }
        watchdog.startReading()
        fmt = openedContext
        return true
    }

    static func cleanup(
        ifmt: UnsafeMutablePointer<AVFormatContext>?,
        ofmt: UnsafeMutablePointer<AVFormatContext>?,
        audio: [AudioChain],
        video: VideoChain?,
        subtitleInputs: [SubtitleInput],
        subtitleRenditions: [SubtitleRendition]
    ) {
        var ifmtPtr: UnsafeMutablePointer<AVFormatContext>? = ifmt
        avformat_close_input(&ifmtPtr)
        var closedExternalIDs = Set<Int>()
        for input in subtitleInputs where input.sourceID != 0 && closedExternalIDs.insert(input.sourceID).inserted {
            var inputPtr: UnsafeMutablePointer<AVFormatContext>? = input.context
            avformat_close_input(&inputPtr)
        }
        if let ofmt { avformat_free_context(ofmt) }
        for rendition in subtitleRenditions {
            rendition.chain?.release()
        }
        for audioChain in audio {
            av_audio_fifo_free(audioChain.fifo)
            var swr: OpaquePointer? = audioChain.swr
            swr_free(&swr)
            var dec: UnsafeMutablePointer<AVCodecContext>? = audioChain.decCtx
            avcodec_free_context(&dec)
            var enc: UnsafeMutablePointer<AVCodecContext>? = audioChain.encCtx
            avcodec_free_context(&enc)
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
