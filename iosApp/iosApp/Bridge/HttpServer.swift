import Foundation
import Network

/// Minimal LAN static-file HTTP server over Network.framework.
/// Serves Documents/proxy (the HLS session output) on an ephemeral port.
/// Keeps connections alive so players reuse one TCP connection across
/// segment fetches, and answers HEAD plus single byte ranges, which some
/// DLNA control points probe with before playing.
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

    struct ParsedRequest {
        let isHead: Bool
        let path: String
        /// Inclusive start byte of a `Range: bytes=a-`/`bytes=a-b` header; nil when absent.
        let rangeStart: Int64?
        let keepAlive: Bool
    }

    /// Parse the request line plus the headers keep-alive and range behavior
    /// depend on. Pure — testable.
    static func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 3,
              parts[0] == "GET" || parts[0] == "HEAD",
              parts[1].hasPrefix("/"),
              parts[2].hasPrefix("HTTP/") else { return nil }
        var rangeStart: Int64?
        var connectionHeader = ""
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if name == "range" {
                rangeStart = parseByteRangeStart(value)
            } else if name == "connection" {
                connectionHeader = value.lowercased()
            }
        }
        let version = String(parts[2].dropFirst("HTTP/".count))
        let keepAlive = connectionHeader == "close"
            ? false
            : connectionHeader == "keep-alive" || version.hasPrefix("1.1") || version.hasPrefix("2")
        return ParsedRequest(
            isHead: parts[0] == "HEAD",
            path: String(parts[1]),
            rangeStart: rangeStart,
            keepAlive: keepAlive
        )
    }

    /// `bytes=a-b` or `bytes=a-` (single range, other units rejected) → start byte.
    static func parseByteRangeStart(_ value: String) -> Int64? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[..<dash].trimmingCharacters(in: .whitespaces))
    }

    /// Clamp a `bytes=start-` request to the file; nil means unsatisfiable (416).
    static func rangeBounds(start: Int64, fileSize: Int64) -> (start: Int64, end: Int64)? {
        guard start >= 0, fileSize > 0, start < fileSize else { return nil }
        return (start, fileSize - 1)
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
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.queue.async { self.connections.removeAll { $0 === connection } }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty,
                  let request = Self.parseRequest(data) else {
                connection.cancel()
                return
            }
            if isComplete {
                // Client half-closed after sending; serve the request and close.
                self.respond(connection: connection, request: request, halfClosed: true)
            } else {
                self.respond(connection: connection, request: request, halfClosed: false)
            }
        }
    }

    private func respond(connection: NWConnection, request: ParsedRequest, halfClosed: Bool) {
        // A half-closed connection cannot carry another request.
        let keepAlive = request.keepAlive && !halfClosed
        guard let fileURL = Self.resolve(root: documentRoot, path: request.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value else {
            sendSimple(connection, status: "404 Not Found", extraHeaders: "", body: Data("Not found".utf8), keepAlive: keepAlive)
            return
        }
        var status = "200 OK"
        var extraHeaders = "Accept-Ranges: bytes\r\n"
        var start: Int64 = 0
        var end = fileSize - 1
        if let rangeStart = request.rangeStart {
            guard let bounds = Self.rangeBounds(start: rangeStart, fileSize: fileSize) else {
                sendSimple(
                    connection,
                    status: "416 Range Not Satisfiable",
                    extraHeaders: "Content-Range: bytes */\(fileSize)\r\n",
                    body: Data(),
                    keepAlive: keepAlive
                )
                return
            }
            status = "206 Partial Content"
            start = bounds.start
            end = bounds.end
            extraHeaders += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n"
        }
        let head = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(Self.contentType(for: fileURL))\r\n" +
            "Content-Length: \(end - start + 1)\r\n" +
            extraHeaders +
            "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        if request.isHead {
            sendHead(connection, head: head, body: nil, keepAlive: keepAlive)
            return
        }
        guard let file = try? FileHandle(forReadingFrom: fileURL) else {
            connection.cancel()
            return
        }
        if start > 0 { file.seek(toFileOffset: UInt64(start)) }
        sendHead(connection, head: head, body: (file, end - start + 1), keepAlive: keepAlive)
    }

    private func sendSimple(
        _ connection: NWConnection,
        status: String,
        extraHeaders: String,
        body: Data,
        keepAlive: Bool
    ) {
        let head = "HTTP/1.1 \(status)\r\n" +
            "Content-Length: \(body.count)\r\n" + extraHeaders +
            "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.finish(connection, keepAlive: keepAlive)
        })
    }

    private static let chunkSize = 1 << 20

    /// Sends the header block, then streams `body` (nil for HEAD responses).
    private func sendHead(
        _ connection: NWConnection,
        head: String,
        body: (file: FileHandle, remaining: Int64)?,
        keepAlive: Bool
    ) {
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? body?.file.close()
                connection.cancel()
                return
            }
            guard let body else {
                self?.finish(connection, keepAlive: keepAlive)
                return
            }
            self?.sendChunk(connection, file: body.file, remaining: body.remaining, keepAlive: keepAlive)
        })
    }

    private func sendChunk(
        _ connection: NWConnection,
        file: FileHandle,
        remaining: Int64,
        keepAlive: Bool
    ) {
        let data = file.readData(ofLength: Int(min(Int64(Self.chunkSize), remaining)))
        guard !data.isEmpty else {
            // File truncated under a correct Content-Length: closing is the
            // only consistent answer.
            try? file.close()
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? file.close()
                connection.cancel()
                return
            }
            let left = remaining - Int64(data.count)
            if left <= 0 {
                try? file.close()
                self?.finish(connection, keepAlive: keepAlive)
            } else {
                self?.sendChunk(connection, file: file, remaining: left, keepAlive: keepAlive)
            }
        })
    }

    private func finish(_ connection: NWConnection, keepAlive: Bool) {
        if keepAlive {
            receiveRequest(connection)
        } else {
            connection.cancel()
        }
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
