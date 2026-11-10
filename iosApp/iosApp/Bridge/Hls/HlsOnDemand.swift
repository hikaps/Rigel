import Foundation

/// AirPlay remux sessions publish a complete VOD presentation immediately and
/// mux each keyframe-aligned segment when the receiver requests it. Segment
/// boundaries come from the source keyframe index, so every segment is a
/// stream copy that starts with a keyframe and needs no full-file remux.
struct OnDemandPlan {
    let videoIndex: Int32
    let audioIndices: [Int32]
    /// Segment boundaries in the video time base; the last entry is the end.
    let boundariesTB: [Int64]
    let boundaries90k: [Int64]
    /// Source byte offset per boundary, -1 when unknown (bandwidth estimate).
    let byteOffsets: [Int64]
    /// Lifts output timestamps off zero so B-frame DTS stays positive.
    let shift90k: Int64
    let origin90k: Int64
    let startOffsetAbs90k: Int64
    var segmentCount: Int { boundariesTB.count - 1 }
}

/// Request bookkeeping shared by the HTTP server and the producer.
final class OnDemandRequests {
    enum Key: Hashable {
        case segment(Int)
        case subtitle(rendition: Int, period: Int)
    }

    static let timeoutSeconds: Double = 40

    let segmentCount: Int
    let periodCount: Int
    let renditionCount: Int
    let streamCount: Int
    private let condition = NSCondition()
    private var ready = Set<Key>()
    private var waiters: [Key: [OnDemandCompletion]] = [:]
    private var lastRequested = 0
    private var newestWaiting: Key?
    private var closed = false

    init(segmentCount: Int, periodCount: Int, renditionCount: Int, streamCount: Int) {
        self.segmentCount = segmentCount
        self.periodCount = periodCount
        self.renditionCount = renditionCount
        self.streamCount = streamCount
    }

    func key(fileName: String) -> Key? {
        if case let (stream, segment)? = Self.indices(fileName, prefix: "seg", suffix: ".ts"),
           stream < streamCount, segment < segmentCount {
            return .segment(segment)
        }
        if case let (rendition, period)? = Self.indices(fileName, prefix: "subtitle_", suffix: ".vtt"),
           rendition < renditionCount, period < periodCount {
            return .subtitle(rendition: rendition, period: period)
        }
        return nil
    }

    private static func indices(_ name: String, prefix: String, suffix: String) -> (Int, Int)? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let parts = name.dropFirst(prefix.count).dropLast(suffix.count)
            .split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 5,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let first = Int(parts[0]), let second = Int(parts[1]) else { return nil }
        return (first, second)
    }

    /// Returns false when the session is closed; otherwise `completion` runs
    /// exactly once: true when the file is produced, false on failure/timeout.
    func register(_ key: Key, completion: @escaping (Bool) -> Void) -> Bool {
        let once = OnDemandCompletion(completion)
        condition.lock()
        guard !closed else {
            condition.unlock()
            return false
        }
        if ready.contains(key) {
            condition.unlock()
            once.call(true)
            return true
        }
        waiters[key, default: []].append(once)
        newestWaiting = key
        if case .segment(let segment) = key { lastRequested = segment }
        condition.signal()
        condition.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
            // A timed-out request must stop steering the producer.
            self?.abandon(key, once)
            once.call(false)
        }
        return true
    }

    /// Waiting keys plus the most recent one: after a seek the player no
    /// longer wants what it asked for before, so production follows the newest.
    func pending() -> (keys: [Key], newest: Key?, lastRequested: Int) {
        condition.lock(); defer { condition.unlock() }
        return (Array(waiters.keys), newestWaiting.flatMap { waiters[$0] != nil ? $0 : nil }, lastRequested)
    }

    private func abandon(_ key: Key, _ completion: OnDemandCompletion) {
        condition.lock(); defer { condition.unlock() }
        guard var list = waiters[key] else { return }
        list.removeAll { $0 === completion }
        waiters[key] = list.isEmpty ? nil : list
    }

    /// Fails requests the producer will no longer serve (superseded by a seek).
    func drop(_ keys: [Key]) {
        condition.lock()
        let callbacks = keys.flatMap { waiters.removeValue(forKey: $0) ?? [] }
        condition.unlock()
        callbacks.forEach { $0.call(false) }
    }

    /// Tracks the playback position from every segment request, including
    /// ones served from disk, so prefetch keeps ahead of the receiver.
    func noteRequested(_ key: Key) {
        guard case .segment(let segment) = key else { return }
        condition.lock()
        lastRequested = segment
        condition.signal()
        condition.unlock()
    }

    func waitForRequest(seconds: Double) {
        condition.lock()
        if waiters.isEmpty && !closed {
            _ = condition.wait(until: Date(timeIntervalSinceNow: seconds))
        }
        condition.unlock()
    }

    func complete(_ key: Key, ok: Bool) {
        condition.lock()
        if ok { ready.insert(key) }
        let callbacks = waiters.removeValue(forKey: key) ?? []
        condition.unlock()
        callbacks.forEach { $0.call(ok) }
    }

    /// Drops produced segments outside `window`; returns their indices.
    func evictSegments(outside window: ClosedRange<Int>) -> [Int] {
        condition.lock(); defer { condition.unlock() }
        var evicted: [Int] = []
        for case .segment(let segment) in ready where !window.contains(segment) {
            evicted.append(segment)
        }
        for segment in evicted { ready.remove(.segment(segment)) }
        return evicted
    }

    func close() {
        condition.lock()
        closed = true
        ready.removeAll()
        let callbacks = waiters.values.flatMap { $0 }
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        callbacks.forEach { $0.call(false) }
    }
}

final class OnDemandCompletion {
    private let lock = NSLock()
    private var callback: ((Bool) -> Void)?

    init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }

    func call(_ ok: Bool) {
        lock.lock()
        let pending = callback
        callback = nil
        lock.unlock()
        pending?(ok)
    }
}

/// One single-stream MPEG-TS segment, written to a temp file and renamed into
/// place so the HTTP server never serves a partial segment.
final class OnDemandSegmentWriter {
    let url: URL
    private let tmpURL: URL
    private var ctx: UnsafeMutablePointer<AVFormatContext>?
    private let stream: UnsafeMutablePointer<AVStream>

    init?(url: URL, codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational, offsetUs: Int64) {
        self.url = url
        tmpURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        var allocated: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&allocated, nil, "mpegts", tmpURL.path) >= 0,
              let out = allocated else { return nil }
        guard let outStream = avformat_new_stream(out, nil),
              avcodec_parameters_copy(outStream.pointee.codecpar, codecpar) >= 0 else {
            avformat_free_context(out)
            return nil
        }
        outStream.pointee.codecpar.pointee.codec_tag = 0
        outStream.pointee.time_base = timeBase
        out.pointee.output_ts_offset = offsetUs
        guard avio_open(&out.pointee.pb, tmpURL.path, AVIO_FLAG_WRITE) >= 0 else {
            avformat_free_context(out)
            return nil
        }
        guard avformat_write_header(out, nil) >= 0 else {
            avio_closep(&out.pointee.pb)
            avformat_free_context(out)
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
        stream = outStream
        ctx = out
    }

    deinit { discard() }

    func write(_ packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) -> Int32 {
        guard let ctx else { return -1 }
        packet.pointee.stream_index = 0
        packet.pointee.pos = -1
        av_packet_rescale_ts(packet, timeBase, stream.pointee.time_base)
        return av_interleaved_write_frame(ctx, packet)
    }

    func finish() -> Bool {
        guard let out = ctx else { return false }
        ctx = nil
        let trailerRet = av_write_trailer(out)
        let closeRet = avio_closep(&out.pointee.pb)
        avformat_free_context(out)
        guard trailerRet >= 0, closeRet >= 0, rename(tmpURL.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }
        return true
    }

    func discard() {
        guard let out = ctx else { return }
        ctx = nil
        avio_closep(&out.pointee.pb)
        avformat_free_context(out)
        try? FileManager.default.removeItem(at: tmpURL)
    }
}

extension RigelHlsExporter {
    static let onDemandMinimumSegmentSeconds: Int64 = 4
    static let onDemandMaximumSegmentSeconds: Int64 = 30
    static let onDemandSubtitlePeriod90k: Int64 = 360_000
    static let onDemandPrefetchSegments = 3
    static let onDemandRetainBehind = 6
    static let onDemandRetainAhead = 9

    /// Greedy keyframe-aligned boundaries: the first is the last keyframe at or
    /// before `start`, each next one the first keyframe at least `minimum`
    /// later; the final entry is `end`. Nil when any segment would exceed
    /// `maximum` (sparse or missing index).
    static func onDemandSegmentBoundaries(
        keyframes: [Int64],
        start: Int64,
        end: Int64,
        minimum: Int64,
        maximum: Int64
    ) -> [Int64]? {
        guard minimum > 0, let first = keyframes.first else { return nil }
        let b0 = keyframes.last(where: { $0 <= start }) ?? first
        guard end > b0 else { return nil }
        var result = [b0]
        for keyframe in keyframes where keyframe < end && keyframe >= result[result.count - 1] + minimum {
            guard keyframe - result[result.count - 1] <= maximum else { return nil }
            result.append(keyframe)
        }
        guard end - result[result.count - 1] <= maximum else { return nil }
        // Fold a short tail into the previous segment when it still fits.
        if result.count > 1, end - result[result.count - 1] < minimum,
           end - result[result.count - 2] <= maximum {
            result.removeLast()
        }
        result.append(end)
        return result
    }

    static func makeOnDemandPlan(
        _ ctx: UnsafeMutablePointer<AVFormatContext>,
        session: Session,
        videoIndex: Int32,
        audioIndices: [Int32],
        passthroughAudioCodecs: [String]
    ) -> OnDemandPlan? {
        guard let video = ctx.pointee.streams[Int(videoIndex)],
              let videoPar = video.pointee.codecpar,
              videoPar.pointee.codec_id == AV_CODEC_ID_H264,
              ctx.pointee.duration > 0 else { return nil }
        for index in audioIndices {
            guard let codecpar = ctx.pointee.streams[Int(index)]?.pointee.codecpar else { return nil }
            // Per-segment TS carries AAC only; other copied codecs keep the full remux.
            if let name = codecName(codecpar.pointee.codec_id), passthroughAudioCodecs.contains(name), name != "aac" {
                return nil
            }
        }
        let timeBase = video.pointee.time_base
        let ninety = AVRational(num: 1, den: 90_000)
        let origin90k = sourceTimestampOrigin90k(ctx, videoIndex: videoIndex, audioIndices: audioIndices)
        // The playlist always covers the whole title so the receiver shows the true duration.
        let startAbs90k = origin90k
        let firstTs = video.pointee.start_time != Int64.min ? video.pointee.start_time : 0
        // Matroska parses deferred cues on its first seek.
        session.inputWatchdog.touch()
        _ = av_seek_frame(ctx, videoIndex, firstTs, AVSEEK_FLAG_BACKWARD)
        var entries: [(ts: Int64, pos: Int64)] = []
        for i in 0..<avformat_index_get_entries_count(video) {
            guard let entry = avformat_index_get_entry(video, i),
                  entry.pointee.flags & AVINDEX_KEYFRAME != 0,
                  entry.pointee.timestamp != Int64.min else { continue }
            entries.append((entry.pointee.timestamp, entry.pointee.pos))
        }
        entries.sort { $0.ts < $1.ts }
        let ctxStart = ctx.pointee.start_time != Int64.min ? ctx.pointee.start_time : 0
        let end = av_rescale_q(ctxStart + ctx.pointee.duration, AVRational(num: 1, den: AV_TIME_BASE), timeBase)
        let seconds = { (value: Int64) in av_rescale_q(value, AVRational(num: 1, den: 1), timeBase) }
        guard let boundaries = onDemandSegmentBoundaries(
            keyframes: entries.map(\.ts),
            start: av_rescale_q(startAbs90k, ninety, timeBase),
            end: end,
            minimum: seconds(onDemandMinimumSegmentSeconds),
            maximum: seconds(onDemandMaximumSegmentSeconds)
        ) else {
            NSLog("[RigelHlsExporter] keyframe index unusable for on-demand VOD; using full remux")
            return nil
        }
        let positions = Dictionary(entries.map { ($0.ts, $0.pos) }, uniquingKeysWith: { first, _ in first })
        let boundaries90k = boundaries.map { av_rescale_q($0, timeBase, ninety) }
        var byteOffsets = boundaries.dropLast().map { positions[$0] ?? -1 }
        byteOffsets.append(ctx.pointee.pb.map { avio_size($0) } ?? -1)
        return OnDemandPlan(
            videoIndex: videoIndex,
            audioIndices: audioIndices,
            boundariesTB: boundaries,
            boundaries90k: boundaries90k,
            byteOffsets: byteOffsets,
            shift90k: boundaries90k[0] < 90_000 ? 90_000 : 0,
            origin90k: origin90k,
            startOffsetAbs90k: startAbs90k
        )
    }

    static func onDemandMediaPlaylist(durations: [Double], uri: (Int) -> String) -> String {
        let target = Int((durations.max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(max(1, target))",
            "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        for (index, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.6f,", duration))
            lines.append(uri(index))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func onDemandTarget(requestPath: String) -> (OnDemandRequests, OnDemandRequests.Key)? {
        let parts = requestPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return nil }
        lock.lock()
        let requests = activeSessionKey(for: String(parts[1])).flatMap { sessions[$0]?.onDemand }
        lock.unlock()
        guard let requests, let key = requests.key(fileName: String(parts[2])) else { return nil }
        return (requests, key)
    }

    static func onDemandResumeMs(sessionId: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return activeSessionKey(for: sessionId).flatMap { sessions[$0]?.onDemandResumeMs }
    }

    static func noteOnDemandRequest(requestPath: String) {
        guard let target = onDemandTarget(requestPath: requestPath) else { return }
        target.0.noteRequested(target.1)
    }

    static func awaitOnDemandFile(requestPath: String, completion: @escaping (Bool) -> Void) -> Bool {
        guard let target = onDemandTarget(requestPath: requestPath) else { return false }
        return target.0.register(target.1, completion: completion)
    }

    /// Serves `plan` until cancellation; returns a failure message, or nil
    /// when cancelled. `publish` reports readiness once segment 0 exists.
    static func runOnDemand(
        session: Session,
        sessionId: String,
        outDir: URL,
        ctx: UnsafeMutablePointer<AVFormatContext>,
        plan: OnDemandPlan,
        defaultAudioIndex: Int32?,
        subtitleInputs: [SubtitleInput],
        publish: () -> Bool
    ) -> String? {
        let mapMpegTS = (subtitleTimestampMapMpegTS(
            mode: "remux",
            sourceOrigin90k: plan.origin90k,
            requestedOffsetMs: session.startOffsetMs,
            encoderOrigin90k: plan.origin90k
        ) + plan.shift90k) % (1 << 33)
        let made = makeSubtitleRenditions(subtitleInputs, outDir: outDir, timestampMapMpegTS: mapMpegTS)
        let renditions = made.renditions
        renditions.forEach { $0.onDemand = true }
        guard let producer = OnDemandProducer(session: session, outDir: outDir, ctx: ctx, plan: plan, renditions: renditions) else {
            cleanup(ifmt: nil, ofmt: nil, audio: [], video: nil, subtitleInputs: [], subtitleRenditions: renditions)
            return "failed to initialize on-demand HLS output"
        }
        defer {
            lock.lock()
            session.onDemand = nil
            lock.unlock()
            producer.close()
        }
        if let error = made.error { return error }
        if let error = producer.preloadSidecars() { return error }
        guard producer.writePlaylists(defaultAudioIndex: defaultAudioIndex) else {
            return "failed to write on-demand HLS playlists"
        }
        lock.lock()
        session.onDemand = producer.requests
        lock.unlock()
        if let error = producer.startRun(at: 0) ?? producer.produceNext() { return error }
        guard publishMasterPlaylist(
            baseMasterURL: outDir.appendingPathComponent("base.m3u8"),
            publicMasterURL: outDir.appendingPathComponent("index.m3u8"),
            subtitles: renditions
        ) else { return "failed to publish HLS master playlist" }
        guard publish() else { return nil }
        return producer.serve()
    }
}

/// Owns demux/mux state for one on-demand session; runs on the session queue.
final class OnDemandProducer {
    private typealias Exporter = RigelHlsExporter
    private static let ninety = AVRational(num: 1, den: 90_000)

    let requests: OnDemandRequests
    private let session: RigelHlsExporter.Session
    private let outDir: URL
    private let ctx: UnsafeMutablePointer<AVFormatContext>
    private let plan: OnDemandPlan
    private let renditions: [SubtitleRendition]
    private let primarySubtitles: [Int32: SubtitleRendition]
    private let video: UnsafeMutablePointer<AVStream>
    /// Template output streams carry the AAC encoder parameters per audio slot.
    private let template: UnsafeMutablePointer<AVFormatContext>
    private let audioSlots: [Int32: Int]
    private let transcodedAudio: Set<Int32>
    private let halfFrame90k: Int64
    private let offsetUs: Int64
    /// Subtitle period p ends inside segment periodSegment[p].
    private let periodSegment: [Int]
    private let periodBoundsMs: [(from: Int64, to: Int64)]

    private var chains: [Int32: AudioChain] = [:]
    private var buffer: RigelHlsExporter.RemuxVideoPacketBuffer?
    private var writers: [Int: OnDemandSegmentWriter] = [:]
    /// Segment each output slot (0 video, 1... audio) is currently writing.
    private var current: [Int] = []
    private var runStart = 0
    private var cursor = 0
    private var sawKeyframe = false
    private var eof = false
    private var failure: String?

    init?(
        session: RigelHlsExporter.Session,
        outDir: URL,
        ctx: UnsafeMutablePointer<AVFormatContext>,
        plan: OnDemandPlan,
        renditions: [SubtitleRendition]
    ) {
        guard let video = ctx.pointee.streams[Int(plan.videoIndex)] else { return nil }
        var allocated: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&allocated, nil, "mpegts", nil) >= 0, let template = allocated else {
            return nil
        }
        var slots: [Int32: Int] = [:]
        var transcoded = Set<Int32>()
        for (offset, index) in plan.audioIndices.enumerated() {
            guard let input = ctx.pointee.streams[Int(index)],
                  let outStream = avformat_new_stream(template, nil) else {
                avformat_free_context(template)
                return nil
            }
            slots[index] = offset + 1
            if input.pointee.codecpar.pointee.codec_id != AV_CODEC_ID_AAC {
                transcoded.insert(index)
            } else {
                avcodec_parameters_copy(outStream.pointee.codecpar, input.pointee.codecpar)
                outStream.pointee.time_base = input.pointee.time_base
            }
        }
        self.session = session
        self.outDir = outDir
        self.ctx = ctx
        self.plan = plan
        self.renditions = renditions
        self.video = video
        self.template = template
        audioSlots = slots
        transcodedAudio = transcoded
        primarySubtitles = Dictionary(
            renditions.filter { $0.input.sourceID == 0 }.map { ($0.input.streamIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        halfFrame90k = av_rescale_q(
            Exporter.remuxFrameDuration(inputStream: video), video.pointee.time_base, Self.ninety
        ) / 2
        offsetUs = av_rescale_q(plan.shift90k, Self.ninety, AVRational(num: 1, den: AV_TIME_BASE))

        let b90 = plan.boundaries90k
        let total90k = b90[b90.count - 1] - b90[0]
        let periodCount = Int((total90k + Exporter.onDemandSubtitlePeriod90k - 1) / Exporter.onDemandSubtitlePeriod90k)
        // Cue times are relative to the requested start; periods start at b0.
        let b0RelMs = (b90[0] - plan.startOffsetAbs90k) / 90
        var segments: [Int] = []
        var bounds: [(from: Int64, to: Int64)] = []
        for period in 0..<periodCount {
            let start90k = Int64(period) * Exporter.onDemandSubtitlePeriod90k
            let end90k = min(start90k + Exporter.onDemandSubtitlePeriod90k, total90k)
            let periodEnd90k = b90[0] + end90k
            segments.append((0..<plan.segmentCount).last(where: { b90[$0] < periodEnd90k }) ?? 0)
            bounds.append((b0RelMs + start90k / 90, b0RelMs + end90k / 90))
        }
        periodSegment = segments
        periodBoundsMs = bounds
        requests = OnDemandRequests(
            segmentCount: plan.segmentCount,
            periodCount: periodCount,
            renditionCount: renditions.count,
            streamCount: plan.audioIndices.count + 1
        )
    }

    func close() {
        requests.close()
        writers.values.forEach { $0.discard() }
        writers.removeAll()
        buffer?.release()
        buffer = nil
        freeChains()
        Exporter.cleanup(ifmt: nil, ofmt: template, audio: [], video: nil, subtitleInputs: [], subtitleRenditions: renditions)
    }

    private func freeChains() {
        Exporter.cleanup(ifmt: nil, ofmt: nil, audio: Array(chains.values), video: nil, subtitleInputs: [], subtitleRenditions: [])
        chains.removeAll()
    }

    /// Sidecars are small: decode them fully so every period has its cues.
    func preloadSidecars() -> String? {
        let sidecarOffsetUs = session.startOffsetMs.multipliedReportingOverflow(by: 1_000).partialValue
        for rendition in renditions where rendition.input.sourceID != 0 {
            var retries = 0
            readLoop: while !Exporter.isCancelled(session) {
                var packet = AVPacket()
                av_init_packet(&packet)
                rendition.input.ioWatchdog?.touch()
                let readRet = av_read_frame(rendition.input.context, &packet)
                switch Exporter.classifyPrimingRead(readRet) {
                case .ok:
                    retries = 0
                    Exporter.writeSubtitlePacket(
                        rendition, packet: &packet, sidecarOffsetUs: sidecarOffsetUs,
                        sourceTimestampOrigin90k: plan.origin90k
                    )
                    av_packet_unref(&packet)
                case .eof:
                    av_packet_unref(&packet)
                    break readLoop
                case .again:
                    av_packet_unref(&packet)
                    retries += 1
                    guard retries > 100 else {
                        usleep(1_000)
                        continue
                    }
                    return "Could not prepare the selected subtitle"
                case .readError:
                    av_packet_unref(&packet)
                    return "Could not prepare the selected subtitle"
                }
            }
            if rendition.decodeFailed { return "Could not prepare the selected subtitle" }
        }
        return nil
    }

    func writePlaylists(defaultAudioIndex: Int32?) -> Bool {
        let b90 = plan.boundaries90k
        let durations = (0..<plan.segmentCount).map { Double(b90[$0 + 1] - b90[$0]) / 90_000 }
        for slot in 0...plan.audioIndices.count {
            let playlist = Exporter.onDemandMediaPlaylist(durations: durations) { segmentName(slot: slot, segment: $0) }
            guard write(playlist, to: "variant_\(slot).m3u8") else { return false }
        }
        let periodDurations = periodBoundsMs.map { Double($0.to - $0.from) / 1_000 }
        for rendition in renditions {
            let playlist = Exporter.onDemandMediaPlaylist(durations: periodDurations) {
                "subtitle_\(rendition.ordinal)_\(String(format: "%05d", $0)).vtt"
            }
            guard write(playlist, to: rendition.playlistName) else { return false }
        }

        var master = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for (offset, index) in plan.audioIndices.enumerated() {
            let isDefault = index == defaultAudioIndex
            var line = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"group_aud\",NAME=\"Audio-\(offset + 1)\""
            line += ",DEFAULT=\(isDefault ? "YES" : "NO"),AUTOSELECT=YES"
            if let language = Exporter.hlsLanguage(for: ctx.pointee.streams[Int(index)]?.pointee.metadata) {
                line += ",LANGUAGE=\"\(language)\""
            }
            line += ",URI=\"variant_\(offset + 1).m3u8\""
            master.append(line)
        }
        var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth())"
        let par = video.pointee.codecpar.pointee
        if par.width > 0, par.height > 0 { inf += ",RESOLUTION=\(par.width)x\(par.height)" }
        inf += ",CODECS=\"\(videoCodecString())\(plan.audioIndices.isEmpty ? "" : ",mp4a.40.2")\""
        if !plan.audioIndices.isEmpty { inf += ",AUDIO=\"group_aud\"" }
        master += [inf, "variant_0.m3u8"]
        return write(master.joined(separator: "\n") + "\n", to: "base.m3u8")
    }

    private func write(_ contents: String, to name: String) -> Bool {
        (try? contents.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil
    }

    private func segmentName(slot: Int, segment: Int) -> String {
        "seg\(slot)_\(String(format: "%05d", segment)).ts"
    }

    private func bandwidth() -> Int64 {
        let b90 = plan.boundaries90k
        var peak: Int64 = 0
        for segment in 0..<plan.segmentCount {
            let bytes = plan.byteOffsets[segment + 1] - plan.byteOffsets[segment]
            let duration90k = b90[segment + 1] - b90[segment]
            guard plan.byteOffsets[segment] >= 0, plan.byteOffsets[segment + 1] > 0, bytes > 0, duration90k > 0 else { continue }
            peak = max(peak, bytes * 8 * 90_000 / duration90k)
        }
        let bitRate = max(peak, ctx.pointee.bit_rate)
        return bitRate > 0 ? bitRate : 8_000_000
    }

    private func videoCodecString() -> String {
        let par = video.pointee.codecpar.pointee
        if let extradata = par.extradata, par.extradata_size >= 4, extradata[0] == 1 {
            return String(format: "avc1.%02x%02x%02x", extradata[1], extradata[2], extradata[3])
        }
        let profile = par.profile > 0 ? par.profile : 100
        let level = par.level > 0 ? par.level : 40
        return String(format: "avc1.%02x00%02x", profile & 0xff, level)
    }

    // MARK: - Production

    /// Repositions the demuxer at segment `segment` with fresh codec state.
    func startRun(at segment: Int) -> String? {
        writers.values.forEach { $0.discard() }
        writers.removeAll()
        buffer?.release()
        buffer = Exporter.RemuxVideoPacketBuffer(
            frameDuration: Exporter.remuxFrameDuration(inputStream: video),
            maximumPendingPackets: Exporter.remuxTimestampBufferLimit(inputStream: video)
        )
        freeChains()
        for index in transcodedAudio {
            guard let input = ctx.pointee.streams[Int(index)], let slot = audioSlots[index],
                  let outStream = template.pointee.streams[slot - 1],
                  let chain = Exporter.makeAudioChain(inputStream: input, outputStream: outStream, timestampOrigin90k: 0) else {
                return "failed to initialize audio transcoder"
            }
            let timeBase = outStream.pointee.time_base
            chain.packetSink = { [unowned self] packet in
                self.writeMedia(slot: slot, packet: packet, timeBase: timeBase, isKeyframe: true)
            }
            chains[index] = chain
        }
        session.inputWatchdog.touch()
        let seekRet = av_seek_frame(ctx, plan.videoIndex, plan.boundariesTB[segment], AVSEEK_FLAG_BACKWARD)
        guard seekRet >= 0 else { return "on-demand seek failed: \(Exporter.avErrorString(seekRet))" }
        current = Array(repeating: segment, count: plan.audioIndices.count + 1)
        runStart = segment
        cursor = segment
        sawKeyframe = false
        eof = false
        failure = nil
        return nil
    }

    /// Produces segment `cursor` (and everything through the end at EOF).
    func produceNext() -> String? {
        let segment = cursor
        var retried = false
        var againCount = 0
        while !isComplete(segment) {
            if Exporter.isCancelled(session) { return "cancelled" }
            if let failure { return failure }
            if let error = chains.values.compactMap(\.error).first { return error }
            var packet = AVPacket()
            av_init_packet(&packet)
            session.inputWatchdog.touch()
            let readRet = av_read_frame(ctx, &packet)
            switch Exporter.classifyPrimingRead(readRet) {
            case .ok:
                againCount = 0
                session.inputWatchdog.touch()
                handle(&packet)
                av_packet_unref(&packet)
            case .eof:
                av_packet_unref(&packet)
                finishAtEOF()
            case .again:
                av_packet_unref(&packet)
                againCount += 1
                guard againCount > 100 else {
                    usleep(1_000)
                    continue
                }
                return "primary read error: \(Exporter.avErrorString(readRet))"
            case .readError(let message):
                av_packet_unref(&packet)
                // One reconnect attempt: reopen the run at this segment.
                guard !retried else { return message }
                retried = true
                if let error = startRun(at: segment) { return error }
            }
        }
        if let failure { return failure }
        let last = eof ? plan.segmentCount - 1 : segment
        for produced in segment...max(segment, last) {
            requests.complete(.segment(produced), ok: true)
            writeSubtitles(endingIn: produced)
        }
        cursor = last + 1
        return nil
    }

    /// Serves requests until cancellation; returns a failure message or nil.
    func serve() -> String? {
        while !Exporter.isCancelled(session) {
            let (keys, newest, lastRequested) = requests.pending()
            func segmentOf(_ key: OnDemandRequests.Key) -> Int {
                switch key {
                case .segment(let segment): return segment
                case .subtitle(_, let period): return periodSegment[period]
                }
            }
            let target: Int?
            if let newest {
                // Stay with the newest burst of requests; older far-away ones are stale.
                let anchor = segmentOf(newest)
                target = keys.map(segmentOf).filter { abs($0 - anchor) <= 3 }.min() ?? anchor
                let stale = keys.filter { abs(segmentOf($0) - anchor) > 3 }
                if !stale.isEmpty { requests.drop(stale) }
            } else if let wanted = keys.map(segmentOf).min() {
                target = wanted
            } else if cursor < plan.segmentCount, cursor <= lastRequested + Exporter.onDemandPrefetchSegments {
                target = cursor
            } else {
                target = nil
            }
            guard let target else {
                requests.waitForRequest(seconds: 0.25)
                continue
            }
            let began = DispatchTime.now()
            var seekSeconds = 0.0
            if target < cursor || target > cursor + 2 {
                if let error = startRun(at: target) { return Exporter.isCancelled(session) ? nil : error }
                seekSeconds = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e9
            }
            let produced = cursor
            if let error = produceNext() { return Exporter.isCancelled(session) ? nil : error }
            let total = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e9
            NSLog("[RigelOnDemand] segment %d produced in %.2f s (seek %.2f s, wanted %d)", produced, total, seekSeconds, target)
            evict(around: lastRequested)
        }
        return nil
    }

    private func evict(around segment: Int) {
        let window = max(0, segment - Exporter.onDemandRetainBehind)...(segment + Exporter.onDemandRetainAhead)
        for evicted in requests.evictSegments(outside: window) {
            for slot in 0...plan.audioIndices.count {
                try? FileManager.default.removeItem(at: outDir.appendingPathComponent(segmentName(slot: slot, segment: evicted)))
            }
        }
    }

    private func isComplete(_ segment: Int) -> Bool {
        guard current[0] > segment else { return false }
        for slot in 1..<current.count where current[slot] <= segment {
            // Audio lags video by up to a segment; once video is two segments
            // ahead the audio for `segment` is final.
            guard current[0] > segment + 1 else { return false }
            while current[slot] <= segment {
                guard finishSegment(slot: slot) else { return true }
            }
        }
        return true
    }

    private func handle(_ packet: UnsafeMutablePointer<AVPacket>) {
        let index = packet.pointee.stream_index
        if index == plan.videoIndex {
            guard var pending = buffer else { return }
            switch pending.append(packet) {
            case .failure(let message):
                failure = message
            case .ready(let ready):
                writeVideo(ready)
            }
            buffer = pending
        } else if let slot = audioSlots[index], let input = ctx.pointee.streams[Int(index)] {
            if let chain = chains[index] {
                Exporter.writeTranscodedAudio(
                    chain: chain, packet: packet, out: template, outStream: template.pointee.streams[slot - 1]!
                )
            } else if writeMedia(slot: slot, packet: packet, timeBase: input.pointee.time_base, isKeyframe: true) < 0 {
                failure = failure ?? "audio packet write failed"
            }
        } else if let rendition = primarySubtitles[index] {
            Exporter.writeSubtitlePacket(
                rendition,
                packet: packet,
                sidecarOffsetUs: session.startOffsetMs.multipliedReportingOverflow(by: 1_000).partialValue,
                sourceTimestampOrigin90k: plan.origin90k
            )
        }
    }

    private func writeVideo(_ ready: [RigelHlsExporter.RemuxReadyPacket]) {
        for readyPacket in ready {
            var pointer: UnsafeMutablePointer<AVPacket>? = readyPacket.packet
            defer { av_packet_free(&pointer) }
            guard failure == nil else { continue }
            readyPacket.packet.pointee.pts = readyPacket.timestamps.pts
            readyPacket.packet.pointee.dts = readyPacket.timestamps.dts
            let isKeyframe = readyPacket.packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            if writeMedia(slot: 0, packet: readyPacket.packet, timeBase: video.pointee.time_base, isKeyframe: isKeyframe) < 0 {
                failure = failure ?? "HLS video packet write failed"
            }
        }
    }

    /// Routes a packet to its segment file, splitting video only at keyframes.
    private func writeMedia(slot: Int, packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational, isKeyframe: Bool) -> Int32 {
        let ts = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        guard ts != Int64.min else { return 0 }
        let ts90k = av_rescale_q(ts, timeBase, Self.ninety)
        let b90 = plan.boundaries90k
        if slot == 0 {
            if !sawKeyframe {
                guard isKeyframe else { return 0 }
                sawKeyframe = true
            }
            if isKeyframe {
                while current[0] + 1 < plan.segmentCount, ts90k >= b90[current[0] + 1] - halfFrame90k {
                    guard finishSegment(slot: 0) else { return -1 }
                }
            }
        } else {
            guard ts90k >= b90[runStart] else { return 0 }
            while current[slot] + 1 < plan.segmentCount, ts90k >= b90[current[slot] + 1] {
                guard finishSegment(slot: slot) else { return -1 }
            }
        }
        guard current[slot] < plan.segmentCount, let writer = writer(slot: slot) else { return -1 }
        return writer.write(packet, timeBase: timeBase)
    }

    private func writer(slot: Int) -> OnDemandSegmentWriter? {
        if let writer = writers[slot] { return writer }
        let codecpar: UnsafePointer<AVCodecParameters>?
        let timeBase: AVRational
        if slot == 0 {
            codecpar = UnsafePointer(video.pointee.codecpar)
            timeBase = video.pointee.time_base
        } else {
            let stream = template.pointee.streams[slot - 1]
            codecpar = stream.map { UnsafePointer($0.pointee.codecpar) }
            timeBase = stream?.pointee.time_base ?? AVRational(num: 1, den: 48_000)
        }
        guard let codecpar, let writer = OnDemandSegmentWriter(
            url: outDir.appendingPathComponent(segmentName(slot: slot, segment: current[slot])),
            codecpar: codecpar,
            timeBase: timeBase,
            offsetUs: offsetUs
        ) else {
            failure = failure ?? "failed to open on-demand HLS segment"
            return nil
        }
        writers[slot] = writer
        return writer
    }

    /// Closes the slot's current segment (header-only when it got no packets).
    private func finishSegment(slot: Int) -> Bool {
        guard let writer = writers.removeValue(forKey: slot) ?? writer(slot: slot), writer.finish() else {
            failure = failure ?? "failed to write on-demand HLS segment"
            return false
        }
        current[slot] += 1
        return true
    }

    private func finishAtEOF() {
        if var pending = buffer {
            switch pending.finish() {
            case .failure(let message): failure = failure ?? message
            case .ready(let ready): writeVideo(ready)
            }
            buffer = pending
        }
        for (index, chain) in chains {
            guard let slot = audioSlots[index], let outStream = template.pointee.streams[slot - 1] else { continue }
            Exporter.flushTranscodedAudio(chain: chain, out: template, outStream: outStream)
        }
        for slot in 0..<current.count {
            while current[slot] < plan.segmentCount {
                guard finishSegment(slot: slot) else { return }
            }
        }
        eof = true
    }

    private func writeSubtitles(endingIn segment: Int) {
        for period in periodSegment.indices where periodSegment[period] == segment {
            for rendition in renditions {
                let bounds = periodBoundsMs[period]
                let url = outDir.appendingPathComponent("subtitle_\(rendition.ordinal)_\(String(format: "%05d", period)).vtt")
                let written = (try? Exporter.subtitlePeriodVTT(rendition, from: bounds.from, to: bounds.to)
                    .write(to: url, atomically: true, encoding: .utf8)) != nil
                requests.complete(.subtitle(rendition: rendition.ordinal, period: period), ok: written)
            }
        }
    }
}
