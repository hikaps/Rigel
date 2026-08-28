import Foundation
import ComposeApp

// MARK: - Kotlin interface conformances (Nuvio MPVPlayerBridge pattern)

final class RigelDiscoveryBridge: NSObject, DiscoveryBridge {
    func ssdpSearch(searchTargets: [String], timeoutMs: Int32, onResult: @escaping ([SsdpDevice]) -> Void) {
        Ssdp.search(searchTargets: searchTargets, timeoutMs: Int(timeoutMs), onResult: onResult)
    }
}

final class RigelProbeBridge: NSObject, ProbeBridge {
    func probe(url: String, headers: [String: String], onResult: @escaping (ProbeResult?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (result, error) = RigelProbe.probe(url: url, headers: headers)
            DispatchQueue.main.async { onResult(result, error) }
        }
    }
}

final class RigelTranscodeBridge: NSObject, TranscodeBridge {
    func startHlsSession(
        sessionId: String,
        sourceUrl: String,
        headers: [String: String],
        mode: String,
        startOffsetMs: Int64,
        subtitleTracks: [SubtitleTrack],
        onReady: @escaping (String?, String?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        RigelHlsExporter.startSession(
            sessionId: sessionId,
            sourceUrl: sourceUrl,
            headers: headers,
            mode: mode,
            startOffsetMs: startOffsetMs,
            subtitleTracks: subtitleTracks,
            onReady: onReady,
            onError: onError
        )
    }

    func stopHlsSession(sessionId: String) {
        RigelHlsExporter.stopSession(sessionId: sessionId)
    }
}

final class RigelHttpServerBridge: NSObject, HttpServerBridge {
    private let server = RigelHttpServer(documentRoot: RigelHttpServer.proxyRootURL())

    func start(onStarted: @escaping (KotlinLong, String?) -> Void) {
        server.start { port, error in
            onStarted(KotlinLong(longLong: Int64(port ?? -1)), error)
        }
    }

    func stop() {
        server.stop()
    }

    func lanBaseUrl() -> String? {
        guard let ip = RigelHttpServer.lanIPv4(), let port = server.port else { return nil }
        return "http://\(ip):\(port)"
    }
}

// MARK: - Registration (called from Swift app startup)

enum BridgeRegistry {
    static func register() {
        RigelBridgeFactory.shared.register(
            discovery: RigelDiscoveryBridge(),
            probe: RigelProbeBridge(),
            transcode: RigelTranscodeBridge(),
            httpServer: RigelHttpServerBridge()
        )
        PlayerBridgeFactory.shared.register(bridge: RigelPlayerBridge())
        RendererBridgeFactory.shared.register(bridge: RigelRendererBridge())
        ChromecastBridgeFactory.shared.register(bridge: RigelChromecastBridge())
    }
}
