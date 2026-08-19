import Foundation
import Network

/// Minimal LAN static-file HTTP server over Network.framework.
/// Serves Documents/proxy (the HLS session output) on an ephemeral port.
final class RigelHttpServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "rigel-http-server")

    let documentRoot: URL
    private(set) var port: Int?

    init(documentRoot: URL) {
        self.documentRoot = documentRoot
    }

    static func proxyRootURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("proxy", isDirectory: true)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Resolve a request path against root, rejecting traversal and non-file results.
    static func resolve(root: URL, path: String) -> URL? {
        let cleaned = path.removingPercentEncoding ?? path
        let standardRoot = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(cleaned).standardizedFileURL
        guard candidate.path.hasPrefix(standardRoot + "/") || candidate.path == standardRoot else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "vtt": return "text/vtt"
        case "mp4": return "video/mp4"
        case "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    /// Parse "GET /path HTTP/1.1" → path. Pure — testable.
    static func parseRequestPath(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let path = String(parts[1])
        return path.hasPrefix("/") ? path : nil
    }

    // MARK: - Lifecycle

    func start(onStarted: @escaping (Int32?, String?) -> Void) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: 0)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = Int32(listener.port?.rawValue ?? 0)
                    self?.port = Int(port)
                    DispatchQueue.main.async { onStarted(port, nil) }
                case .failed(let error):
                    DispatchQueue.main.async { onStarted(nil, error.localizedDescription) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            DispatchQueue.main.async { onStarted(nil, error.localizedDescription) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        var received = Data()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                received.append(data)
            }
            if let error {
                connection.cancel()
                return
            }
            if isComplete || received.count > 0 {
                self?.respond(connection: connection, request: received)
            }
        }
    }

    private func respond(connection: NWConnection, request: Data) {
        let requestPath = Self.parseRequestPath(request) ?? "?"
        NSLog("[RigelHttp] GET %@", requestPath)
        guard let path = Self.parseRequestPath(request),
              let fileURL = Self.resolve(root: documentRoot, path: path),
              let data = try? Data(contentsOf: fileURL) else {
            let body = "Not found"
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let headers = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(Self.contentType(for: fileURL))\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Connection: close\r\n\r\n"
        var payload = Data(headers.utf8)
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// First non-loopback IPv4 address (en0/en1) — for TV-visible cast URLs.
    static func lanIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var result: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = current.pointee.ifa_flags
            let family = current.pointee.ifa_addr.pointee.sa_family
            let name = String(cString: current.pointee.ifa_name)
            if family == sa_family_t(AF_INET) && (flags & UInt32(IFF_LOOPBACK)) == 0 &&
                (name == "en0" || name == "en1") {
                var addr = current.pointee.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let sockPtr = withUnsafePointer(to: &addr) { $0 }
                if getnameinfo(sockPtr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result = String(cString: host)
                    break
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }
}
