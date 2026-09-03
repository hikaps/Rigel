import Foundation

extension RigelHlsExporter {
    static func isCancelled(_ session: Session) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return session.cancel
    }

    static func finishSession(_ session: Session, sessionId: String) -> Bool {
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
    static func publishReady(
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

    static func sourceTimestampOrigin90k(
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

    static func streamMetadataValue(_ metadata: OpaquePointer?, key: String) -> String? {
        var result: String?
        key.withCString { keyPointer in
            guard let entry = av_dict_get(metadata, keyPointer, nil, 0),
                  let value = entry.pointee.value else { return }
            result = String(cString: value)
        }
        return result
    }

    static func hlsLanguage(for metadata: OpaquePointer?) -> String? {
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
}
