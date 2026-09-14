import Foundation

extension RigelHlsExporter {
    static func run(
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
        var subtitleRenditions: [SubtitleRendition] = []
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
            subtitleRenditions.forEach(finishSubtitleRendition)
            cleanup(
                ifmt: ifmt,
                ofmt: ofmt,
                audio: Array(audioChains.values),
                video: videoChain,
                subtitleInputs: subtitleInputs,
                subtitleRenditions: subtitleRenditions
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
        for (offset, track) in session.subtitleTracks.enumerated() {
            var subtitleFmt: UnsafeMutablePointer<AVFormatContext>? = nil
            let watchdog = InputWatchdog(timeoutSeconds: 10)
            guard openSidecarInput(url: track.url, headers: [:], watchdog: watchdog, fmt: &subtitleFmt),
                  let subtitleCtx = subtitleFmt else {
                closeInput(&subtitleFmt)
                reportFailure("Could not prepare the selected subtitle")
                return
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
                reportFailure("Could not prepare the selected subtitle")
                return
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
                    ioWatchdog: watchdog
                )
            )
        }
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
                            ioWatchdog: nil
                        )
                    )
                }
            default:
                break
            }
        }

        let outputAudioIndices: [Int32]
        if selectedVideoIndex == nil {
            outputAudioIndices = defaultAudioIndex.map { [$0] } ?? []
        } else {
            outputAudioIndices = selectedAudioIndices
        }
        let hasMasterPlaylist = selectedVideoIndex != nil
        let baseMasterPath = outDir.appendingPathComponent("base.m3u8").path
        let playlistPath = hasMasterPlaylist
            ? outDir.appendingPathComponent("variant_%v.m3u8").path
            : legacyPlaylistPath
        guard avformat_alloc_output_context2(&ofmt, nil, "hls", playlistPath) >= 0, let out = ofmt else {
            reportFailure("failed to create HLS output context")
            return
        }

        av_opt_set(out.pointee.priv_data, "hls_time", "4", 0)
        // A short first segment pairs with the 2 s GOP so readiness needs
        // ~6 s of media instead of ~8 s; steady-state segments stay 4 s.
        av_opt_set(out.pointee.priv_data, "hls_init_time", "2", 0)
        av_opt_set(out.pointee.priv_data, "hls_list_size", "0", 0)
        av_opt_set(out.pointee.priv_data, "hls_playlist_type", "event", 0)
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

        var primarySubtitleOutputs: [Int32: SubtitleRendition] = [:]
        var externalSubtitleOutputs: [Int: SubtitleRendition] = [:]
        if mainVideoOutput != nil {
            for input in subtitleInputs {
                let isSelectedExternal = input.sourceID != 0
                guard let inputStream = input.context.pointee.streams[Int(input.streamIndex)],
                      let codecpar = inputStream.pointee.codecpar else {
                    if isSelectedExternal {
                        reportFailure("Could not prepare the selected subtitle")
                        return
                    }
                    continue
                }
                let codec = codecpar.pointee.codec_id
                let chain: SubtitleChain?
                if codec == AV_CODEC_ID_WEBVTT {
                    chain = nil
                } else {
                    guard let decoded = makeSubtitleChain(inputStream: inputStream) else {
                        if isSelectedExternal {
                            reportFailure("Could not prepare the selected subtitle")
                            return
                        }
                        NSLog(
                            "[RigelHlsExporter] failed to initialize subtitle decoder for stream %d codec %d",
                            input.streamIndex,
                            codec.rawValue
                        )
                        continue
                    }
                    chain = decoded
                }
                guard let rendition = makeSubtitleRendition(
                    input: input,
                    ordinal: subtitleRenditions.count,
                    outDir: outDir,
                    chain: chain,
                    isSelectedExternal: isSelectedExternal
                ) else {
                    if isSelectedExternal {
                        reportFailure("Could not prepare the selected subtitle")
                        return
                    }
                    NSLog("[RigelHlsExporter] failed to create subtitle rendition for stream %d", input.streamIndex)
                    continue
                }
                subtitleRenditions.append(rendition)
                if input.sourceID == 0 {
                    primarySubtitleOutputs[input.streamIndex] = rendition
                } else {
                    externalSubtitleOutputs[input.sourceID] = rendition
                }
            }
        }

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
            av_opt_set(
                out.pointee.priv_data,
                "var_stream_map",
                streamMapEntries.joined(separator: " "),
                0
            )
            av_opt_set(
                out.pointee.priv_data,
                "master_pl_name",
                "base.m3u8",
                0
            )
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
        /// the primary input's timeline is shifted by the same offset.
        let sidecarOffsetUs = session.startOffsetMs.multipliedReportingOverflow(by: 1_000).partialValue


        var primaryEnded = false
        var endedExternalSources = Set<Int>()
        var lastReadinessCheck = DispatchTime(uptimeNanoseconds: 0)
        var lastInputUs: Int64 = 0
        let externalSourceCount = externalSubtitleOutputs.count
        while true {
            if isCancelled(session) { break }
            paceExport(session: session, exportedUs: lastInputUs)
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
                    lastInputUs = max(
                        lastInputUs,
                        inputPacketUs(&primaryPacket, stream: ctx.pointee.streams[Int(inIdx)])
                    )
                    if let outIdx = streamMap[inIdx],
                       let inStream = ctx.pointee.streams[Int(inIdx)],
                       let outStream = out.pointee.streams[Int(outIdx)] {
                        switch inStream.pointee.codecpar.pointee.codec_type {
                        case AVMEDIA_TYPE_VIDEO:
                            if let chain = videoChain, chain.inputIndex == inIdx {
                                writeTranscodedVideo(chain: chain, packet: &primaryPacket, out: out, outStream: outStream)
                            } else {
                                writeRemuxPacket(
                                    &primaryPacket,
                                    inStream: inStream,
                                    outStream: outStream,
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
                        writeSubtitlePacket(
                            subtitleOutput,
                            packet: &primaryPacket,
                            sidecarOffsetUs: sidecarOffsetUs
                        )
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
                    subtitleOutput.input.ioWatchdog?.touch()
                    didRead = true
                    writeSubtitlePacket(
                        subtitleOutput,
                        packet: &subtitlePacket,
                        sidecarOffsetUs: sidecarOffsetUs
                    )
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
            // Warmup waits until the main and subtitle playlists reference
            // files that already exist; the public master is then immutable
            // until the final trailer pass.
            if !notified {
                let now = DispatchTime.now()
                if now.uptimeNanoseconds - lastReadinessCheck.uptimeNanoseconds >= 100_000_000 {
                    lastReadinessCheck = now
                    let ready: Bool
                    if hasMasterPlaylist {
                        ready = presentationReady(
                            baseMasterURL: URL(fileURLWithPath: baseMasterPath),
                            outDir: outDir,
                            subtitles: subtitleRenditions,
                            final: false
                        )
                    } else {
                        ready = playlistReady(
                            playlistPath: playlistPath,
                            outDir: outDir,
                            variantCount: 1,
                            final: false
                        )
                    }
                    if ready {
                        let published = !hasMasterPlaylist || publishMasterPlaylist(
                            baseMasterURL: URL(fileURLWithPath: baseMasterPath),
                            publicMasterURL: URL(fileURLWithPath: legacyPlaylistPath),
                            subtitles: subtitleRenditions
                        )
                        if published {
                            notified = publishReady(
                                session: session,
                                sessionId: sessionId,
                                path: "\(sessionId)/index.m3u8",
                                onReady: onReady
                            )
                        }
                    }
                }
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
        if terminalError == nil,
           subtitleRenditions.contains(where: { $0.isSelectedExternal && $0.decodeFailed }) {
            terminalError = "Could not prepare the selected subtitle"
        }
        if let terminalError {
            av_write_trailer(out)
            subtitleRenditions.forEach(finishSubtitleRendition)
            reportFailure(terminalError)
            return
        }
        av_write_trailer(out)
        subtitleRenditions.forEach(finishSubtitleRendition)
        let finalReady: Bool
        if hasMasterPlaylist {
            finalReady = presentationReady(
                baseMasterURL: URL(fileURLWithPath: baseMasterPath),
                outDir: outDir,
                subtitles: subtitleRenditions,
                final: true
            )
        } else {
            finalReady = playlistReady(
                playlistPath: playlistPath,
                outDir: outDir,
                variantCount: 1,
                final: true
            )
        }
        if finalReady {
            let published = !hasMasterPlaylist || publishMasterPlaylist(
                baseMasterURL: URL(fileURLWithPath: baseMasterPath),
                publicMasterURL: URL(fileURLWithPath: legacyPlaylistPath),
                subtitles: subtitleRenditions
            )
            if !published {
                reportFailure("failed to publish HLS master playlist")
            } else if !notified {
                notified = publishReady(
                    session: session,
                    sessionId: sessionId,
                    path: "\(sessionId)/index.m3u8",
                    onReady: onReady
                )
            }
        } else if !notified {
            reportFailure("HLS presentation was not ready")
        }
    }

    static let pacingRunAheadLimitUs: Int64 = 20_000_000
    static let pacingPlayheadFreshnessSeconds: Double = 15

    /// Absolute media time of a packet (AV_TIME_BASE µs); 0 when unknown.
    static func inputPacketUs(
        _ packet: UnsafeMutablePointer<AVPacket>,
        stream: UnsafeMutablePointer<AVStream>?
    ) -> Int64 {
        guard let stream, stream.pointee.time_base.num != 0, stream.pointee.time_base.den != 0 else { return 0 }
        let ts = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        guard ts != Int64.min else { return 0 }
        return av_rescale_q(ts, stream.pointee.time_base, AVRational(num: 1, den: AV_TIME_BASE))
    }

    /// True when the export should idle: it is far ahead of a fresh playhead.
    /// An unknown or stale playhead (never reported, or cast playback where
    /// the local position is wrong) keeps the historical free-run behavior.
    static func shouldPace(exportedUs: Int64, playheadMs: Int64, playheadAgeSeconds: Double?) -> Bool {
        guard playheadMs >= 0,
              let age = playheadAgeSeconds,
              age <= pacingPlayheadFreshnessSeconds else { return false }
        return exportedUs - playheadMs * 1000 > pacingRunAheadLimitUs
    }

    /// Blocks the session queue in short sleeps until pacing disengages or
    /// the session is cancelled; playhead jumps (native seeks) re-engage or
    /// release pacing through the same check.
    static func paceExport(session: Session, exportedUs: Int64) {
        while true {
            lock.lock()
            let playheadMs = session.playheadMs
            let updated = session.playheadUpdatedAt
            let cancelled = session.cancel
            lock.unlock()
            if cancelled { return }
            let age = updated.map {
                Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
            }
            guard shouldPace(exportedUs: exportedUs, playheadMs: playheadMs, playheadAgeSeconds: age) else {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
