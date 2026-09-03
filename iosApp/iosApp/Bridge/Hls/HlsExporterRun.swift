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
        for (offset, track) in session.subtitleTracks.enumerated() {
            var subtitleFmt: UnsafeMutablePointer<AVFormatContext>? = nil
            guard openInput(url: track.url, headers: [:], fmt: &subtitleFmt),
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
                if codec != AV_CODEC_ID_WEBVTT {
                    guard avcodec_find_decoder(codec) != nil else {
                        if isSelectedExternal {
                            reportFailure("Could not prepare the selected subtitle")
                            return
                        }
                        NSLog("[RigelHlsExporter] no subtitle decoder for stream %d", input.streamIndex)
                        continue
                    }
                }
                guard let outputStream = avformat_new_stream(out, nil) else {
                    if isSelectedExternal {
                        reportFailure("Could not prepare the selected subtitle")
                        return
                    }
                    continue
                }
                let chain: SubtitleChain?
                if codec == AV_CODEC_ID_WEBVTT {
                    guard avcodec_parameters_copy(outputStream.pointee.codecpar, codecpar) >= 0 else {
                        if isSelectedExternal {
                            reportFailure("Could not prepare the selected subtitle")
                            return
                        }
                        outputStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_DATA
                        continue
                    }
                    outputStream.pointee.codecpar.pointee.codec_tag = 0
                    outputStream.pointee.time_base = input.timeBase
                    chain = nil
                } else {
                    chain = makeSubtitleChain(inputStream: inputStream)
                    guard chain != nil else {
                        if isSelectedExternal {
                            reportFailure("Could not prepare the selected subtitle")
                            return
                        }
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
                        if isSelectedExternal {
                            reportFailure("Could not prepare the selected subtitle")
                            return
                        }
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
            if !notified, let selectedSubtitle = subtitleOutputs.first(where: { $0.input.sourceID != 0 }) {
                markSelectedSubtitleName(
                    in: outDir,
                    output: selectedSubtitle
                )
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
        if let selectedSubtitle = subtitleOutputs.first(where: { $0.input.sourceID != 0 }) {
            markSelectedSubtitleName(
                in: outDir,
                output: selectedSubtitle
            )
        }
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
}
