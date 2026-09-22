import Foundation
import ComposeApp

/// Local ffmpeg remux/transcode → HLS session. Writes a master playlist,
/// variant playlists, and segments into Documents/proxy/<sessionId>/ and
/// signals readiness when enough media is available.
/// AirPlay VOD sessions defer readiness until the completed playlist is rewritten from EVENT to VOD.
/// REMUX: video stream-copy; each audio stream is copied when AAC/MP3/FLAC/ALAC
/// or decoded→AAC otherwise. TRANSCODE: video decode→VideoToolbox H.264,
/// each audio stream decode→AAC.
final class RigelHlsExporter {
    final class Session {
        let queue: DispatchQueue
        let startOffsetMs: Int64
        let waitForCompletion: Bool
        let subtitleTracks: [SubtitleTrack]
        var cancel = false
        var finished = false
        var cleanupPending = false
        var readinessClaimed = false
        var readinessDelivered = false
        /// Local playhead feed (absolute media ms) driving export pacing.
        var playheadMs: Int64 = -1
        var playheadUpdatedAt: DispatchTime?

        init(
            queue: DispatchQueue,
            startOffsetMs: Int64,
            subtitleTracks: [SubtitleTrack],
            waitForCompletion: Bool
        ) {
            self.queue = queue
            self.startOffsetMs = startOffsetMs
            self.subtitleTracks = subtitleTracks
            self.waitForCompletion = waitForCompletion
        }
    }

    static var sessions: [String: Session] = [:]
    static let lock = NSLock()
    static let subtitlePlaylistLock = NSLock()

    static func readSubtitlePlaylist(_ url: URL) -> Data? {
        subtitlePlaylistLock.lock()
        defer { subtitlePlaylistLock.unlock() }
        return try? Data(contentsOf: url)
    }

    static let passthroughAudio = Set(["aac", "mp3", "flac", "alac"])

    static func isValidSessionId(_ sessionId: String) -> Bool {
        guard !sessionId.isEmpty, sessionId.utf8.count <= 128 else { return false }
        return sessionId.utf8.allSatisfy { byte in
            switch byte {
            case 45, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }

    private static func isSafeSessionDirectory(sessionId: String) -> Bool {
        guard isValidSessionId(sessionId) else { return false }
        let root = RigelHttpServer.proxyRootURL().standardizedFileURL.path
        let child = sessionDir(sessionId: sessionId).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return child.hasPrefix(prefix)
    }

    private static func activeSessionKey(for sessionId: String) -> String? {
        sessions.keys.first { $0.caseInsensitiveCompare(sessionId) == .orderedSame }
    }
    private static func reportStartFailure(
        _ message: String,
        onReady: @escaping (String?, String?) -> Void
    ) {
        DispatchQueue.main.async { onReady(nil, message) }
    }

    static func sessionDir(sessionId: String) -> URL {
        RigelHttpServer.proxyRootURL().appendingPathComponent(sessionId, isDirectory: true)
    }

    static func startSession(
        sessionId: String,
        sourceUrl: String,
        headers: [String: String],
        mode: String,
        passthroughAudioCodecs: [String] = [],
        startOffsetMs: Int64,
        subtitleTracks: [SubtitleTrack],
        waitForCompletion: Bool = false,
        onReady: @escaping (String?, String?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard isSafeSessionDirectory(sessionId: sessionId) else {
            reportStartFailure("Invalid HLS session id", onReady: onReady)
            return
        }
        let queue = DispatchQueue(label: "rigel-hls-\(sessionId)")
        let session = Session(
            queue: queue,
            startOffsetMs: startOffsetMs,
            subtitleTracks: subtitleTracks,
            waitForCompletion: waitForCompletion
        )
        lock.lock()
        guard activeSessionKey(for: sessionId) == nil else {
            lock.unlock()
            reportStartFailure("HLS session is already active", onReady: onReady)
            return
        }
        sessions[sessionId] = session
        lock.unlock()
        queue.async {
            run(
                session: session,
                sessionId: sessionId,
                sourceUrl: sourceUrl,
                headers: headers,
                mode: mode,
                passthroughAudioCodecs: passthroughAudioCodecs,
                onReady: onReady,
                onError: onError
            )
        }
    }

    static func stopSession(sessionId: String) {
        guard isSafeSessionDirectory(sessionId: sessionId) else { return }
        lock.lock()
        let key = activeSessionKey(for: sessionId) ?? sessionId
        let session = sessions[key]
        let queue = session?.queue
        session?.cancel = true
        session?.cleanupPending = true
        lock.unlock()
        deleteSessionDir(sessionId: key, session: session, writerQueue: queue)
    }

    /// Local playhead feed from the host player; see paceExport.
    static func updatePlayhead(sessionId: String, positionMs: Int64) {
        lock.lock()
        let key = activeSessionKey(for: sessionId) ?? sessionId
        sessions[key]?.playheadMs = positionMs
        sessions[key]?.playheadUpdatedAt = .now()
        lock.unlock()
    }

    /// The directory must outlive the writer: deleting mid-write races
    /// ffmpeg's segment opens. An active session deletes on its own serial
    /// queue, so the removal runs strictly after run() finishes; a session
    /// that already ended has no writer and is removed right away.
    private static func deleteSessionDir(
        sessionId: String,
        session: Session?,
        writerQueue: DispatchQueue?
    ) {
        let removeIfOwned = {
            if session == nil {
                lock.lock()
                guard activeSessionKey(for: sessionId) == nil else {
                    lock.unlock()
                    return
                }
                try? FileManager.default.removeItem(at: sessionDir(sessionId: sessionId))
                lock.unlock()
                return
            }

            lock.lock()
            guard sessions[sessionId] === session else {
                lock.unlock()
                return
            }
            lock.unlock()

            try? FileManager.default.removeItem(at: sessionDir(sessionId: sessionId))

            lock.lock()
            if sessions[sessionId] === session {
                sessions.removeValue(forKey: sessionId)
            }
            lock.unlock()
        }
        if let writerQueue {
            writerQueue.async(execute: removeIfOwned)
        } else {
            removeIfOwned()
        }
    }
}
