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

    static var sessions: [String: Session] = [:]
    static let lock = NSLock()

    static let passthroughAudio = Set(["aac", "mp3", "flac", "alac"])

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
}
