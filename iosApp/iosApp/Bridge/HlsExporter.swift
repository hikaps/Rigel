import Foundation
import ComposeApp


/// Local ffmpeg remux/transcode → HLS session. Writes a master playlist,
/// variant playlists, and segments into Documents/proxy/<sessionId>/ and
/// signals readiness when enough media is available.
/// REMUX: video stream-copy; each audio stream is copied when AAC/MP3/FLAC/ALAC
/// or decoded→AAC otherwise. TRANSCODE: video decode→VideoToolbox H.264,
/// each audio stream decode→AAC.
final class RigelHlsExporter {
    final class Session {
        let queue: DispatchQueue
        let startOffsetMs: Int64
        let subtitleTracks: [SubtitleTrack]
        var cancel = false
        var finished = false
        var readinessClaimed = false
        var readinessDelivered = false

        init(
            queue: DispatchQueue,
            startOffsetMs: Int64,
            subtitleTracks: [SubtitleTrack]
        ) {
            self.queue = queue
            self.startOffsetMs = startOffsetMs
            self.subtitleTracks = subtitleTracks
        }
    }

    private struct SubtitleInput {
        let sourceID: Int
        let context: UnsafeMutablePointer<AVFormatContext>
        let streamIndex: Int32
        let timeBase: AVRational
        let language: String?
        let title: String?
    }

    private final class SubtitleOutput {
        let input: SubtitleInput
        let ordinal: Int
        let outputStream: UnsafeMutablePointer<AVStream>
        let chain: SubtitleChain?
        let videoOrdinal: Int

        init(
            input: SubtitleInput,
            ordinal: Int,
            outputStream: UnsafeMutablePointer<AVStream>,
            chain: SubtitleChain?,
            videoOrdinal: Int
        ) {
            self.input = input
            self.ordinal = ordinal
            self.outputStream = outputStream
            self.chain = chain
            self.videoOrdinal = videoOrdinal
        }
    }

    private final class SubtitleChain {
        let decCtx: UnsafeMutablePointer<AVCodecContext>

        init(decCtx: UnsafeMutablePointer<AVCodecContext>) {
            self.decCtx = decCtx
        }

        func release() {
            var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
            avcodec_free_context(&dec)
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
        startOffsetMs: Int64,
        subtitleTracks: [SubtitleTrack],
        onReady: @escaping (String?, String?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        let queue = DispatchQueue(label: "rigel-hls-\(sessionId)")
        let session = Session(
            queue: queue,
            startOffsetMs: startOffsetMs,
            subtitleTracks: subtitleTracks
        )
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
        audioIndices: [Int32]
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
        var indices = audioIndices
        if let videoIndex {
            indices.insert(videoIndex, at: 0)
        }
        for index in indices {
            guard let stream = ctx.pointee.streams[Int(index)],
                  stream.pointee.start_time != Int64.min else { continue }
            let timeBase = stream.pointee.time_base
            guard timeBase.num != 0, timeBase.den != 0 else { continue }
            let start = av_rescale_q(stream.pointee.start_time, timeBase, commonTimeBase)
            origin = origin.map { min($0, start) } ?? start
        }
        return origin ?? 0
    }

    private static func streamMetadataValue(_ metadata: OpaquePointer?, key: String) -> String? {
        var result: String?
        key.withCString { keyPointer in
            guard let entry = av_dict_get(metadata, keyPointer, nil, 0),
                  let value = entry.pointee.value else { return }
            result = String(cString: value)
        }
        return result
    }

    private static func hlsLanguage(for metadata: OpaquePointer?) -> String? {
        guard let value = streamMetadataValue(metadata, key: "language") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 8,
              trimmed.unicodeScalars.allSatisfy({
                  ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
              }) else {
            return nil
        }
        return trimmed
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
        let legacyPlaylistPath = outDir.appendingPathComponent("index.m3u8").path

        var ifmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var ofmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var subtitleInputs: [SubtitleInput] = []
        var subtitleOutputs: [SubtitleOutput] = []
        var videoOutputStreams: [UnsafeMutablePointer<AVStream>] = []
        var audioChains: [Int32: AudioChain] = [:]
        var passthroughAudioIndices: Set<Int32> = []
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
            cleanup(
                ifmt: ifmt,
                ofmt: ofmt,
                audio: Array(audioChains.values),
                video: videoChain,
                subtitleInputs: subtitleInputs,
                subtitles: subtitleOutputs.compactMap(\.chain)
            )
        }

        guard openInput(url: sourceUrl, headers: headers, fmt: &ifmt), let ctx = ifmt else {
            reportFailure("failed to open source: \(sourceUrl)")
            return
        }
        if session.startOffsetMs > 0 {
            let targetUs = session.startOffsetMs.multipliedReportingOverflow(by: 1_000).partialValue
            let seekResult = avformat_seek_file(ctx, -1, 0, targetUs, Int64.max, 0)
            if seekResult < 0 {
                NSLog("[RigelPlayer] failed to seek source to %lld ms", session.startOffsetMs)
            }
        }
        let inCount = Int(ctx.pointee.nb_streams)
        var selectedVideoIndex: Int32?
        var selectedVideoIsDefault = false
        var selectedAudioIndices: [Int32] = []
        var defaultAudioIndex: Int32?
        var foundDefaultAudio = false
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
                selectedAudioIndices.append(inputIndex)
                if defaultAudioIndex == nil || (isDefault && !foundDefaultAudio) {
                    defaultAudioIndex = inputIndex
                    foundDefaultAudio = isDefault
                }
            case AVMEDIA_TYPE_SUBTITLE:
                if isBitmapSubtitle(codecpar.pointee.codec_id) {
                    NSLog("[RigelHlsExporter] skipping bitmap subtitle stream %d", inputIndex)
                } else {
                    subtitleInputs.append(
                        SubtitleInput(
                            sourceID: 0,
                            context: ctx,
                            streamIndex: inputIndex,
                            timeBase: stream.pointee.time_base,
                            language: hlsLanguage(for: stream.pointee.metadata),
                            title: streamMetadataValue(stream.pointee.metadata, key: "title"),
                        )
                    )
                }
            default:
                break
            }
        }

        for (offset, track) in session.subtitleTracks.enumerated() {
            var subtitleFmt: UnsafeMutablePointer<AVFormatContext>? = nil
            guard openInput(url: track.url, headers: [:], fmt: &subtitleFmt),
                  let subtitleCtx = subtitleFmt else {
                closeInput(&subtitleFmt)
                NSLog("[RigelHlsExporter] sidecar subtitle failed to open: %@", track.url)
                continue
            }
            let subtitleStreamIndex = (0..<Int(subtitleCtx.pointee.nb_streams)).compactMap { index -> Int32? in
                guard let stream = subtitleCtx.pointee.streams[index],
                      let codecpar = stream.pointee.codecpar,
                      codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
                      !isBitmapSubtitle(codecpar.pointee.codec_id) else { return nil }
                return Int32(index)
            }.first
            guard let subtitleStreamIndex,
                  let subtitleStream = subtitleCtx.pointee.streams[Int(subtitleStreamIndex)] else {
                closeInput(&subtitleFmt)
                NSLog("[RigelHlsExporter] sidecar subtitle has no supported stream: %@", track.url)
                continue
            }
            let language = hlsLanguageValue(track.language)
                ?? hlsLanguage(for: subtitleStream.pointee.metadata)
            let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            subtitleInputs.append(
                SubtitleInput(
                    sourceID: offset + 1,
                    context: subtitleCtx,
                    streamIndex: subtitleStreamIndex,
                    timeBase: subtitleStream.pointee.time_base,
                    language: language,
                    title: title?.isEmpty == false
                        ? title
                        : streamMetadataValue(subtitleStream.pointee.metadata, key: "title"),
                )
            )
        }

        let outputAudioIndices: [Int32]
        if selectedVideoIndex == nil {
            outputAudioIndices = defaultAudioIndex.map { [$0] } ?? []
        } else {
            outputAudioIndices = selectedAudioIndices
        }
        let hasMasterPlaylist = selectedVideoIndex != nil
        var variantCount = hasMasterPlaylist ? outputAudioIndices.count + 1 : 1
        let playlistPath = hasMasterPlaylist
            ? outDir.appendingPathComponent("variant_%v.m3u8").path
            : legacyPlaylistPath
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
            hasMasterPlaylist
                ? outDir.appendingPathComponent("seg%v_%05d.ts").path
                : outDir.appendingPathComponent("seg%05d.ts").path,
            0
        )

        var outputInputIndices = outputAudioIndices
        if let selectedVideoIndex {
            outputInputIndices.insert(selectedVideoIndex, at: 0)
        }
        let timestampOrigin90k = sourceTimestampOrigin90k(
            ctx,
            videoIndex: selectedVideoIndex,
            audioIndices: outputAudioIndices
        )

        var streamMap: [Int32: Int32] = [:]
        var mainVideoOutput: UnsafeMutablePointer<AVStream>?
        for inputIndex in outputInputIndices {
            guard let inStream = ctx.pointee.streams[Int(inputIndex)],
                  let codecpar = inStream.pointee.codecpar,
                  let outStream = avformat_new_stream(out, nil) else { continue }
            let outIndex = outStream.pointee.index
            streamMap[inputIndex] = outIndex

            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                mainVideoOutput = outStream
                // remux: verbatim stream copy. transcode: always re-encode.
                if mode == "remux" {
                    if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 {
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        outStream.pointee.time_base = inStream.pointee.time_base
                    }
                } else if let chain = makeVideoChain(
                    inputStream: inStream,
                    outputStream: outStream,
                    timestampOrigin90k: timestampOrigin90k
                ) {
                    videoChain = chain
                    chain.outputStreams = [outStream]
                }
            case AVMEDIA_TYPE_AUDIO:
                if let language = streamMetadataValue(inStream.pointee.metadata, key: "language") {
                    language.withCString { value in
                        av_dict_set(&outStream.pointee.metadata, "language", value, 0)
                    }
                }
                if mode == "remux", let name = codecName(codecpar.pointee.codec_id),
                   passthroughAudio.contains(name) {
                    passthroughAudioIndices.insert(inputIndex)
                    if avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 {
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        outStream.pointee.time_base = inStream.pointee.time_base
                    }
                } else if let chain = makeAudioChain(
                    inputStream: inStream,
                    outputStream: outStream,
                    timestampOrigin90k: timestampOrigin90k
                ) {
                    audioChains[inputIndex] = chain
                }
            default:
                break
            }
        }

        var primarySubtitleOutputs: [Int32: SubtitleOutput] = [:]
        var externalSubtitleOutputs: [Int: SubtitleOutput] = [:]
        if let mainVideoOutput {
            videoOutputStreams = [mainVideoOutput]
            for input in subtitleInputs {
                guard let inputStream = input.context.pointee.streams[Int(input.streamIndex)],
                      let codecpar = inputStream.pointee.codecpar else { continue }
                let codec = codecpar.pointee.codec_id
                if codec != AV_CODEC_ID_WEBVTT {
                    guard avcodec_find_decoder(codec) != nil else {
                        NSLog("[RigelHlsExporter] no subtitle decoder for stream %d", input.streamIndex)
                        continue
                    }
                }
                guard let outputStream = avformat_new_stream(out, nil) else { continue }
                let chain: SubtitleChain?
                if codec == AV_CODEC_ID_WEBVTT {
                    guard avcodec_parameters_copy(outputStream.pointee.codecpar, codecpar) >= 0 else {
                        outputStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_DATA
                        continue
                    }
                    outputStream.pointee.codecpar.pointee.codec_tag = 0
                    outputStream.pointee.time_base = input.timeBase
                    chain = nil
                } else {
                    chain = makeSubtitleChain(inputStream: inputStream)
                    guard chain != nil else {
                        NSLog(
                            "[RigelHlsExporter] failed to initialize subtitle decoder for stream %d codec %d",
                            input.streamIndex,
                            codec.rawValue
                        )
                        outputStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_DATA
                        continue
                    }
                    outputStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
                    outputStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_WEBVTT
                    outputStream.pointee.codecpar.pointee.codec_tag = 0
                    outputStream.pointee.time_base = AVRational(num: 1, den: 1_000)
                }
                if let language = input.language {
                    language.withCString { value in
                        av_dict_set(&outputStream.pointee.metadata, "language", value, 0)
                    }
                }
                if let title = input.title {
                    title.withCString { value in
                        av_dict_set(&outputStream.pointee.metadata, "title", value, 0)
                    }
                }
                let videoOrdinal: Int
                if subtitleOutputs.isEmpty {
                    videoOrdinal = 0
                } else {
                    videoOrdinal = videoOutputStreams.count
                    guard let duplicateVideo = avformat_new_stream(out, nil),
                          avcodec_parameters_copy(duplicateVideo.pointee.codecpar, mainVideoOutput.pointee.codecpar) >= 0 else {
                        chain?.release()
                        outputStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_DATA
                        continue
                    }
                    duplicateVideo.pointee.codecpar.pointee.codec_tag = 0
                    duplicateVideo.pointee.time_base = mainVideoOutput.pointee.time_base
                    videoOutputStreams.append(duplicateVideo)
                    videoChain?.outputStreams = videoOutputStreams
                }
                let output = SubtitleOutput(
                    input: input,
                    ordinal: subtitleOutputs.count,
                    outputStream: outputStream,
                    chain: chain,
                    videoOrdinal: videoOrdinal
                )
                subtitleOutputs.append(output)
                if input.sourceID == 0 {
                    primarySubtitleOutputs[input.streamIndex] = output
                } else {
                    externalSubtitleOutputs[input.sourceID] = output
                }
            }
        }
        variantCount += max(0, subtitleOutputs.count - 1)

        if mode != "remux", selectedVideoIndex != nil, videoChain == nil {
            reportFailure("failed to initialize video transcoder")
            return
        }

        if hasMasterPlaylist {
            var streamMapEntries: [String] = []
            var mainEntry = "v:0"
            if !outputAudioIndices.isEmpty {
                mainEntry += ",agroup:aud"
            }
            if let firstSubtitle = subtitleOutputs.first {
                mainEntry += ",s:\(firstSubtitle.ordinal),sgroup:subs"
                if let language = firstSubtitle.input.language {
                    mainEntry += ",language:\(language)"
                }
                mainEntry += ",default:yes"
            }
            streamMapEntries.append(mainEntry)
            for (audioNumber, inputIndex) in outputAudioIndices.enumerated() {
                var entry = "a:\(audioNumber),agroup:aud"
                if inputIndex == defaultAudioIndex {
                    entry += ",default:yes"
                }
                if let language = hlsLanguage(
                    for: ctx.pointee.streams[Int(inputIndex)]?.pointee.metadata
                ) {
                    entry += ",language:\(language)"
                } else {
                    entry += ",name:Audio-\(audioNumber + 1)"
                }
                streamMapEntries.append(entry)
            }
            for subtitle in subtitleOutputs.dropFirst() {
                var entry = "v:\(subtitle.videoOrdinal)"
                if !outputAudioIndices.isEmpty {
                    entry += ",agroup:aud"
                }
                entry += ",s:\(subtitle.ordinal),sgroup:subs,default:no"
                if let language = subtitle.input.language {
                    entry += ",language:\(language)"
                }
                let name = streamMapName(subtitle.input.title, fallback: "Subtitle-\(subtitle.ordinal + 1)")
                entry += ",name:\(name)"
                streamMapEntries.append(entry)
            }
            av_opt_set(
                out.pointee.priv_data,
                "var_stream_map",
                streamMapEntries.joined(separator: " "),
                0
            )
            av_opt_set(
                out.pointee.priv_data,
                "master_pl_name",
                "index.m3u8",
                0
            )
            av_opt_set(out.pointee.priv_data, "master_pl_publish_rate", "1", 0)
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
                } else if outputAudioIndices.contains(primePacket.stream_index),
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
            if primingAudioEvicted {
                var audioTimeBases: [Int32: AVRational] = [:]
                for audioIndex in outputAudioIndices {
                    if let audioStream = ctx.pointee.streams[Int(audioIndex)] {
                        audioTimeBases[audioIndex] = audioStream.pointee.time_base
                    }
                }
                if let ringHeadPTS = audioRingHeadPTS90k(
                    pendingAudioPackets,
                    timeBases: audioTimeBases
                ) {
                    // Rebase every chain onto the retained tail so replayed
                    // audio and the first decoded video share one timeline.
                    chain.timestampOrigin90k = ringHeadPTS
                    for audioChain in audioChains.values {
                        audioChain.timestampOrigin90k = ringHeadPTS
                    }
                }
            }
        }
        if let mainVideoOutput, videoOutputStreams.count > 1 {
            for duplicateVideo in videoOutputStreams.dropFirst() {
                avcodec_parameters_copy(
                    duplicateVideo.pointee.codecpar,
                    mainVideoOutput.pointee.codecpar
                )
                duplicateVideo.pointee.time_base = mainVideoOutput.pointee.time_base
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
                if let chain = audioChains[inIdx] {
                    writeTranscodedAudio(chain: chain, packet: buffered, out: out, outStream: outStream)
                } else if passthroughAudioIndices.contains(inIdx) {
                    writeRemuxPacket(buffered, inStream: inStream, outStream: outStream, out: out)
                }
            }
            var bufferedPointer: UnsafeMutablePointer<AVPacket>? = buffered
            av_packet_free(&bufferedPointer)
        }
        pendingAudioPackets.removeAll()

        /// Sidecar subtitle files keep absolute timestamps; after a proxy seek
        /// the primary input's timeline is shifted, so sidecar cues must shift
        /// by the same offset (and cues ending at/before it are dropped) to
        /// stay aligned with picture and audio.
        let sidecarOffsetUs = session.startOffsetMs.multipliedReportingOverflow(by: 1_000).partialValue
        func writeSubtitlePacket(
            _ output: SubtitleOutput,
            packet: UnsafeMutablePointer<AVPacket>
        ) {
            guard let inputStream = output.input.context.pointee.streams[Int(output.input.streamIndex)] else { return }
            var shiftedPacket = packet
            if output.input.sourceID != 0, sidecarOffsetUs > 0,
               packet.pointee.pts != Int64.min {
                let inputTimeBase = inputStream.pointee.time_base.num != 0 &&
                    inputStream.pointee.time_base.den != 0
                    ? inputStream.pointee.time_base
                    : AVRational(num: 1, den: 1_000)
                let offsetInInput = av_rescale_q(
                    sidecarOffsetUs,
                    AVRational(num: 1, den: AV_TIME_BASE),
                    inputTimeBase
                )
                let end = packet.pointee.duration > 0
                    ? packet.pointee.pts + packet.pointee.duration
                    : packet.pointee.pts
                guard end > offsetInInput else { return }
                shiftedPacket.pointee.pts = max(0, packet.pointee.pts - offsetInInput)
                if shiftedPacket.pointee.dts != Int64.min {
                    shiftedPacket.pointee.dts = shiftedPacket.pointee.pts
                }
                if packet.pointee.duration > 0 {
                    shiftedPacket.pointee.duration = end - max(offsetInInput, packet.pointee.pts)
                }
            }
            if let chain = output.chain {
                writeTranscodedSubtitle(
                    chain: chain,
                    packet: shiftedPacket,
                    inputStream: inputStream,
                    out: out,
                    outStream: output.outputStream
                )
            } else {
                writeRemuxPacket(
                    shiftedPacket,
                    inStream: inputStream,
                    outStream: output.outputStream,
                    out: out
                )
            }
        }

        var primaryEnded = false
        var endedExternalSources = Set<Int>()
        let externalSourceCount = externalSubtitleOutputs.count
        while true {
            if isCancelled(session) { break }
            var didRead = false
            if !primaryEnded {
                var primaryPacket = AVPacket()
                av_init_packet(&primaryPacket)
                let readRet = av_read_frame(ctx, &primaryPacket)
                if readRet < 0 {
                    primaryEnded = true
                } else {
                    didRead = true
                    let inIdx = primaryPacket.stream_index
                    if let outIdx = streamMap[inIdx],
                       let inStream = ctx.pointee.streams[Int(inIdx)],
                       let outStream = out.pointee.streams[Int(outIdx)] {
                        switch inStream.pointee.codecpar.pointee.codec_type {
                        case AVMEDIA_TYPE_VIDEO:
                            if let chain = videoChain, chain.inputIndex == inIdx {
                                writeTranscodedVideo(chain: chain, packet: &primaryPacket, out: out, outStream: outStream)
                            } else {
                                writeRemuxPacketCopies(
                                    &primaryPacket,
                                    inStream: inStream,
                                    outStreams: videoOutputStreams,
                                    out: out
                                )
                            }
                        case AVMEDIA_TYPE_AUDIO:
                            if let chain = audioChains[inIdx] {
                                writeTranscodedAudio(chain: chain, packet: &primaryPacket, out: out, outStream: outStream)
                            } else if passthroughAudioIndices.contains(inIdx) {
                                writeRemuxPacket(&primaryPacket, inStream: inStream, outStream: outStream, out: out)
                            }
                        default:
                            break
                        }
                    } else if let subtitleOutput = primarySubtitleOutputs[inIdx] {
                        writeSubtitlePacket(subtitleOutput, packet: &primaryPacket)
                    }
                    av_packet_unref(&primaryPacket)
                }
            }

            for subtitleOutput in externalSubtitleOutputs.values {
                let sourceID = subtitleOutput.input.sourceID
                guard !endedExternalSources.contains(sourceID) else { continue }
                var subtitlePacket = AVPacket()
                av_init_packet(&subtitlePacket)
                let readRet = av_read_frame(subtitleOutput.input.context, &subtitlePacket)
                if readRet < 0 {
                    endedExternalSources.insert(sourceID)
                } else {
                    didRead = true
                    writeSubtitlePacket(subtitleOutput, packet: &subtitlePacket)
                    av_packet_unref(&subtitlePacket)
                }
            }

            if !didRead &&
                (primaryEnded && endedExternalSources.count == externalSourceCount) {
                break
            }
            if let videoError = videoChain?.error {
                terminalError = videoError
                break
            }
            if !notified &&
                playlistReady(
                    playlistPath: playlistPath,
                    outDir: outDir,
                    variantCount: variantCount,
                    final: false
                ) {
                notified = publishReady(
                    session: session,
                    sessionId: sessionId,
                    path: "\(sessionId)/index.m3u8",
                    onReady: onReady
                )
            }
        }

        if terminalError == nil && !isCancelled(session) {
            for audioIndex in outputAudioIndices {
                guard let chain = audioChains[audioIndex],
                      let outIndex = streamMap[chain.inputIndex],
                      let outStream = out.pointee.streams[Int(outIndex)] else { continue }
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
        if !notified &&
            playlistReady(
                playlistPath: playlistPath,
                outDir: outDir,
                variantCount: variantCount,
                final: true
            ) {
            notified = publishReady(
                session: session,
                sessionId: sessionId,
                path: "\(sessionId)/index.m3u8",
                onReady: onReady
            )
        }
    }

    private static func playlistReady(
        playlistPath: String,
        outDir: URL,
        variantCount: Int,
        final: Bool
    ) -> Bool {
        let masterPath = outDir.appendingPathComponent("index.m3u8").path
        if let master = try? String(contentsOfFile: masterPath, encoding: .utf8),
           master.contains("#EXT-X-STREAM-INF"),
           FileManager.default.fileExists(atPath: outDir.appendingPathComponent("seg0_00000.ts").path) {
            if final { return true }
            guard FileManager.default.fileExists(
                atPath: outDir.appendingPathComponent("seg0_00001.ts").path
            ) else {
                return false
            }
            for variant in 1..<variantCount {
                guard FileManager.default.fileExists(
                    atPath: outDir.appendingPathComponent("seg\(variant)_00000.ts").path
                ) else {
                    return false
                }
            }
            return true
        }

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

    private static func writeRemuxPacketCopies(
        _ packet: UnsafeMutablePointer<AVPacket>,
        inStream: UnsafeMutablePointer<AVStream>,
        outStreams: [UnsafeMutablePointer<AVStream>],
        out: UnsafeMutablePointer<AVFormatContext>
    ) {
        for outStream in outStreams {
            var copy = AVPacket()
            av_init_packet(&copy)
            guard av_packet_ref(&copy, packet) >= 0 else { continue }
            writeRemuxPacket(&copy, inStream: inStream, outStream: outStream, out: out)
            av_packet_unref(&copy)
        }
    }

    private static func isBitmapSubtitle(_ id: AVCodecID) -> Bool {
        switch id {
        case AV_CODEC_ID_DVD_SUBTITLE,
             AV_CODEC_ID_DVB_SUBTITLE,
             AV_CODEC_ID_XSUB,
             AV_CODEC_ID_HDMV_PGS_SUBTITLE:
            return true
        default:
            return false
        }
    }

    private static func hlsLanguageValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({
            ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) ||
            $0.value == 45
        }) else { return nil }
        return trimmed
    }

    private static func streamMapName(_ value: String?, fallback: String) -> String {
        let source = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = source?.isEmpty == false ? source! : fallback
        let sanitized = candidate.unicodeScalars.map { scalar -> String in
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isLower = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            return isUpper || isLower || isDigit || scalar.value == 45 || scalar.value == 95
                ? String(scalar)
                : "_"
        }.joined()
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func makeSubtitleChain(
        inputStream: UnsafeMutablePointer<AVStream>
    ) -> SubtitleChain? {
        guard let codecpar = inputStream.pointee.codecpar,
              let decoder = avcodec_find_decoder(codecpar.pointee.codec_id),
              let decCtx = avcodec_alloc_context3(decoder) else {
            return nil
        }
        func fail() -> SubtitleChain? {
            var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
            avcodec_free_context(&dec)
            return nil
        }

        let sourceTimeBase = inputStream.pointee.time_base
        let packetTimeBase = sourceTimeBase.num != 0 && sourceTimeBase.den != 0
            ? sourceTimeBase
            : AVRational(num: 1, den: 1_000)
        guard avcodec_parameters_to_context(decCtx, codecpar) >= 0 else { return fail() }
        decCtx.pointee.pkt_timebase = packetTimeBase
        guard avcodec_open2(decCtx, decoder, nil) >= 0 else { return fail() }
        return SubtitleChain(decCtx: decCtx)
    }


    private static func plainSubtitleText(_ value: String) -> String {
        let fields = value.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
        let body = fields.count == 10 ? String(fields[9]) : value
        return body
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func subtitleText(_ subtitle: AVSubtitle) -> String? {
        guard let rects = subtitle.rects else { return nil }
        var lines: [String] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = rects[index] else { continue }
            let raw: String?
            if let ass = rect.pointee.ass {
                raw = SubtitleParser.decodeCString(UnsafePointer(ass))
            } else if let text = rect.pointee.text {
                raw = SubtitleParser.decodeCString(UnsafePointer(text))
            } else {
                raw = nil
            }
            if let raw {
                let cleaned = plainSubtitleText(raw)
                if !cleaned.isEmpty {
                    lines.append(cleaned)
                }
            }
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func writeTranscodedSubtitle(
        chain: SubtitleChain,
        packet: UnsafeMutablePointer<AVPacket>,
        inputStream: UnsafeMutablePointer<AVStream>,
        out: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) {
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        let decodeResult = avcodec_decode_subtitle2(
            chain.decCtx,
            &subtitle,
            &gotSubtitle,
            packet
        )
        guard decodeResult >= 0, gotSubtitle != 0, let text = subtitleText(subtitle) else {
            avsubtitle_free(&subtitle)
            return
        }
        defer { avsubtitle_free(&subtitle) }

        let textData = Data(text.utf8)
        guard textData.count <= Int(Int32.max) else { return }
        var encoded = AVPacket()
        av_init_packet(&encoded)
        guard av_new_packet(&encoded, Int32(textData.count)) >= 0,
              let destination = encoded.data else {
            return
        }
        textData.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                memcpy(destination, baseAddress, textData.count)
            }
        }
        let inputTimeBase = inputStream.pointee.time_base.num != 0 &&
            inputStream.pointee.time_base.den != 0
            ? inputStream.pointee.time_base
            : AVRational(num: 1, den: 1_000)
        let outputTimeBase = outStream.pointee.time_base.num != 0 &&
            outStream.pointee.time_base.den != 0
            ? outStream.pointee.time_base
            : AVRational(num: 1, den: 1_000)
        let inputPTS = packet.pointee.pts != Int64.min
            ? packet.pointee.pts
            : av_rescale_q(subtitle.pts, AVRational(num: 1, den: AV_TIME_BASE), inputTimeBase)
        encoded.pts = av_rescale_q(inputPTS, inputTimeBase, outputTimeBase)
        encoded.dts = encoded.pts
        if packet.pointee.duration > 0 {
            encoded.duration = av_rescale_q(packet.pointee.duration, inputTimeBase, outputTimeBase)
        } else {
            let displayDuration = Int64(subtitle.end_display_time) -
                Int64(subtitle.start_display_time)
            encoded.duration = max(1, displayDuration)
        }
        encoded.stream_index = outStream.pointee.index
        encoded.pos = -1
        av_interleaved_write_frame(out, &encoded)
        av_packet_unref(&encoded)
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

    private static func scaleVideoFrame(
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

    private static func drainEncodedVideo(
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

    private static func closeInput(_ fmt: inout UnsafeMutablePointer<AVFormatContext>?) {
        avformat_close_input(&fmt)
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
            if avformat_find_stream_info(fmt, nil) < 0 {
                closeInput(&fmt)
                return
            }
            opened = true
        }
        return opened
    }

    private static func cleanup(
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
