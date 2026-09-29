import Foundation
import Network

/// Bounded incremental HTTP/1.x framing shared by the proxy and UPnP servers.
/// A frame contains exactly one header block and its declared body; any bytes
/// following it remain buffered for the next frame.
struct RigelHTTPFrame {
    let head: Data
    let body: Data
}

struct RigelHTTPFramer {
    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 1 * 1024 * 1024

    enum Event {
        case needMore
        case continueRequestBody
        case frame(RigelHTTPFrame)
        case invalid
    }

    private var buffer = Data()
    private var continueRequested = false
    /// Whether unread bytes remain after the last complete frame.
    var hasBufferedData: Bool { !buffer.isEmpty }

    init() {}

    mutating func append(_ data: Data) -> Event {
        if !data.isEmpty { buffer.append(data) }
        return next()
    }

    mutating func next() -> Event {
        let marker = Data([13, 10, 13, 10])
        guard let delimiter = buffer.range(of: marker) else {
            return buffer.count > Self.maxHeaderBytes ? .invalid : .needMore
        }

        let headerEnd = delimiter.lowerBound
        let headerBytes = headerEnd + marker.count
        guard headerBytes <= Self.maxHeaderBytes,
              let headerText = String(data: Data(buffer.prefix(headerEnd)), encoding: .utf8),
              let framing = Self.contentLength(in: headerText) else {
            return .invalid
        }
        let (bodyEnd, overflow) = headerBytes.addingReportingOverflow(framing.contentLength)
        guard !overflow, framing.contentLength <= Self.maxBodyBytes, bodyEnd >= headerBytes else {
            return .invalid
        }
        if buffer.count < bodyEnd {
            if framing.contentLength > 0, framing.expectsContinue, !continueRequested {
                continueRequested = true
                return .continueRequestBody
            }
            return .needMore
        }

        let frame = RigelHTTPFrame(
            head: Data(buffer.prefix(headerBytes)),
            body: Data(buffer[headerBytes..<bodyEnd])
        )
        buffer.removeSubrange(0..<bodyEnd)
        continueRequested = false
        return .frame(frame)
    }

    private static func contentLength(in headerText: String) -> (contentLength: Int, expectsContinue: Bool)? {
        let lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty, !lines[0].isEmpty else { return nil }
        var contentLength: Int?
        var expectsContinue = false
        for line in lines.dropFirst() {
            guard !line.isEmpty, let separator = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.value < 128 && $0.value >= 33 && $0.value != 127 }) else {
                return nil
            }
            if name == "content-length" {
                guard !value.isEmpty,
                      value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                      let parsed = Int(value), parsed <= Self.maxBodyBytes else { return nil }
                if let contentLength, contentLength != parsed { return nil }
                contentLength = parsed
            } else if name == "transfer-encoding", !value.isEmpty {
                // Chunked framing is deliberately unsupported; accepting it
                // would make the bounded Content-Length contract ambiguous.
                return nil
            } else if name == "expect" {
                guard value.lowercased() == "100-continue" else { return nil }
                expectsContinue = true
            }
        }
        return (contentLength ?? 0, expectsContinue)
    }
}

/// Per-connection parser and cancellation-owned idle timer.
final class RigelHTTPConnectionState {
    var framer = RigelHTTPFramer()
    var timer: DispatchSourceTimer?
    var processing = false
    var inputClosed = false

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// Minimal LAN static-file HTTP server over Network.framework.
/// Serves Documents/proxy (the HLS session output) on an ephemeral port.
/// Keeps connections alive so players reuse one TCP connection across
/// segment fetches, and answers HEAD plus single byte ranges, which some
/// DLNA control points probe with before playing.
final class RigelHttpServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var connectionStates: [ObjectIdentifier: RigelHTTPConnectionState] = [:]
    private let queue = DispatchQueue(label: "rigel-http-server")
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private var portValue: Int?
    private var pendingStartCallbacks: [(Int32?, String?) -> Void] = []
    private static let maxConnections = 32
    private static let headerTimeout: DispatchTimeInterval = .seconds(10)
    private static let idleTimeout: DispatchTimeInterval = .seconds(30)

    let documentRoot: URL

    var port: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return portValue
    }

    init(documentRoot: URL) {
        self.documentRoot = documentRoot
        queue.setSpecific(key: queueKey, value: ())
    }

    private func setPort(_ value: Int?) {
        stateLock.lock()
        portValue = value
        stateLock.unlock()
    }
    private func resolveStartCallbacksOnQueue(port: Int32?, error: String?) {
        let callbacks = pendingStartCallbacks
        pendingStartCallbacks.removeAll()
        for callback in callbacks {
            if Thread.isMainThread {
                callback(port, error)
            } else {
                DispatchQueue.main.async { callback(port, error) }
            }
        }
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
        /// Inclusive start byte of a Range: bytes=a-/bytes=a-b header; nil when absent.
        let rangeStart: Int64?
        let keepAlive: Bool
    }

    /// Parse the request line plus the headers keep-alive and range behavior
    /// depend on. Pure and testable; framing is performed by RigelHTTPFramer.
    static func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 3,
              parts[0] == "GET" || parts[0] == "HEAD",
              parts[1].hasPrefix("/"),
              parts[2].hasPrefix("HTTP/") else { return nil }
        var rangeStart: Int64?
        var connectionHeader = ""
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { return nil }
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

    /// bytes=a-b or bytes=a- (single range, other units rejected) to start byte.
    static func parseByteRangeStart(_ value: String) -> Int64? {
        guard value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[..<dash].trimmingCharacters(in: .whitespaces))
    }

    /// Clamp a bytes=start- request to the file; nil means unsatisfiable (416).
    static func rangeBounds(start: Int64, fileSize: Int64) -> (start: Int64, end: Int64)? {
        guard start >= 0, fileSize > 0, start < fileSize else { return nil }
        return (start, fileSize - 1)
    }

    // MARK: - Lifecycle

    func start(onStarted: @escaping (Int32?, String?) -> Void) {
        queue.async { [weak self] in
            self?.startOnQueue(onStarted: onStarted)
        }
    }

    private func startOnQueue(onStarted: @escaping (Int32?, String?) -> Void) {
        if let currentPort = portValue, listener != nil {
            DispatchQueue.main.async { onStarted(Int32(currentPort), nil) }
            return
        }
        if listener != nil {
            pendingStartCallbacks.append(onStarted)
            return
        }
        pendingStartCallbacks.append(onStarted)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let newListener = try NWListener(using: params, on: 0)
            listener = newListener
            newListener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { [weak self] in self?.acceptOnQueue(connection) }
            }
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                self?.queue.async { [weak self, weak newListener] in
                    guard let self, let newListener else { return }
                    self.listenerStateOnQueue(newListener, state: state)
                }
            }
            newListener.start(queue: queue)
        } catch {
            listener = nil
            setPort(nil)
            resolveStartCallbacksOnQueue(port: nil, error: error.localizedDescription)
        }
    }

    private func listenerStateOnQueue(
        _ candidate: NWListener,
        state: NWListener.State
    ) {
        guard listener === candidate else { return }
        switch state {
        case .ready:
            let readyPort = Int(candidate.port?.rawValue ?? 0)
            setPort(readyPort)
            resolveStartCallbacksOnQueue(port: Int32(readyPort), error: nil)
        case .failed(let error):
            candidate.cancel()
            listener = nil
            setPort(nil)
            closeAllConnectionsOnQueue()
            resolveStartCallbacksOnQueue(port: nil, error: error.localizedDescription)
        default:
            break
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync { self.stopOnQueue() }
        }
    }
    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        setPort(nil)
        closeAllConnectionsOnQueue()
        resolveStartCallbacksOnQueue(port: nil, error: "HTTP server stopped")
    }

    private func closeAllConnectionsOnQueue() {
        for connection in connections { connection.cancel() }
        for state in connectionStates.values { state.cancelTimer() }
        connections.removeAll()
        connectionStates.removeAll()
    }

    private func acceptOnQueue(_ connection: NWConnection) {
        guard listener != nil, connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let state = RigelHTTPConnectionState()
        let id = ObjectIdentifier(connection)
        connections.append(connection)
        connectionStates[id] = state
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            self?.queue.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                if case .cancelled = newState { self.removeOnQueue(connection) }
                if case .failed = newState { self.removeOnQueue(connection) }
            }
        }
        connection.start(queue: queue)
        scheduleTimeout(state, connection: connection, interval: Self.headerTimeout)
        receiveRequest(connection)
    }

    private func removeOnQueue(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionStates.removeValue(forKey: id)?.cancelTimer()
        connections.removeAll { $0 === connection }
    }

    private func closeOnQueue(_ connection: NWConnection) {
        removeOnQueue(connection)
        connection.cancel()
    }

    private func scheduleTimeout(
        _ state: RigelHTTPConnectionState,
        connection: NWConnection,
        interval: DispatchTimeInterval
    ) {
        state.cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self, weak connection, weak state] in
            guard let self, let connection, let state,
                  self.connectionStates[ObjectIdentifier(connection)] === state else { return }
            self.closeOnQueue(connection)
        }
        state.timer = timer
        timer.resume()
    }

    private func receiveRequest(_ connection: NWConnection) {
        guard let state = connectionStates[ObjectIdentifier(connection)], !state.processing else { return }
        // Drain every complete frame already buffered before touching the
        // socket again; EOF (inputClosed) only prevents future reads.
        switch state.framer.next() {
        case .frame(let frame):
            state.cancelTimer()
            state.processing = true
            // A frame is the last one this connection can carry only when the
            // peer half-closed AND no pipelined bytes remain buffered.
            respond(connection: connection, frame: frame, halfClosed: state.inputClosed && !state.framer.hasBufferedData)
        case .invalid:
            closeOnQueue(connection)
        case .continueRequestBody:
            sendContinue(connection)
        case .needMore:
            if state.inputClosed {
                // EOF with an incomplete frame: nothing more can arrive.
                closeOnQueue(connection)
                return
            }
            if state.timer == nil {
                scheduleTimeout(state, connection: connection, interval: Self.headerTimeout)
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] data, _, isComplete, error in
                self?.queue.async { [weak self, weak connection] in
                    guard let self, let connection,
                          let state = self.connectionStates[ObjectIdentifier(connection)] else { return }
                    if error != nil {
                        self.closeOnQueue(connection)
                        return
                    }
                    if isComplete { state.inputClosed = true }
                    if let data, !data.isEmpty {
                        switch state.framer.append(data) {
                        case .frame(let frame):
                            state.cancelTimer()
                            state.processing = true
                            self.respond(connection: connection, frame: frame, halfClosed: state.inputClosed && !state.framer.hasBufferedData)
                        case .invalid:
                            self.closeOnQueue(connection)
                        case .continueRequestBody:
                            self.sendContinue(connection)
                        case .needMore:
                            if state.inputClosed && !state.framer.hasBufferedData {
                                self.closeOnQueue(connection)
                            } else {
                                self.receiveRequest(connection)
                            }
                        }
                    } else if state.inputClosed {
                        self.closeOnQueue(connection)
                    } else {
                        self.receiveRequest(connection)
                    }
                }
            }
        }
    }

    private func sendContinue(_ connection: NWConnection) {
        let response = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connectionStates[ObjectIdentifier(connection)] != nil else { return }
                if error != nil {
                    self.closeOnQueue(connection)
                } else {
                    self.receiveRequest(connection)
                }
            }
        })
    }

    private func respond(connection: NWConnection, frame: RigelHTTPFrame, halfClosed: Bool) {
        guard let request = Self.parseRequest(frame.head) else {
            closeOnQueue(connection)
            return
        }
        // A half-closed connection cannot carry another request.
        let keepAlive = request.keepAlive && !halfClosed
        guard let fileURL = Self.resolve(root: documentRoot, path: request.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value else {
            sendSimple(connection, status: "404 Not Found", extraHeaders: "", body: Data("Not found".utf8), keepAlive: keepAlive)
            return
        }
        if fileURL.pathExtension.lowercased() == "m3u8",
           request.rangeStart == nil,
           let playlist = RigelHlsExporter.readSubtitlePlaylist(fileURL) {
            let headers = "Content-Type: \(Self.contentType(for: fileURL))\r\n"
            if request.isHead {
                let head = "HTTP/1.1 200 OK\r\nContent-Length: \(playlist.count)\r\n\(headers)Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
                sendHead(connection, head: head, body: nil, keepAlive: keepAlive)
            } else {
                sendSimple(connection, status: "200 OK", extraHeaders: headers, body: playlist, keepAlive: keepAlive)
            }
            return
        }
        var status = "200 OK"
        var extraHeaders = "Accept-Ranges: bytes\r\n"
        var start: Int64 = 0
        var end = fileSize - 1
        if let rangeStart = request.rangeStart {
            guard let bounds = Self.rangeBounds(start: rangeStart, fileSize: fileSize) else {
                sendSimple(connection, status: "416 Range Not Satisfiable", extraHeaders: "Content-Range: bytes */\(fileSize)\r\n", body: Data(), keepAlive: keepAlive)
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
            closeOnQueue(connection)
            return
        }
        if start > 0 { file.seek(toFileOffset: UInt64(start)) }
        sendHead(connection, head: head, body: (file, end - start + 1), keepAlive: keepAlive)
    }

    private func sendSimple(_ connection: NWConnection, status: String, extraHeaders: String, body: Data, keepAlive: Bool) {
        if let state = connectionStates[ObjectIdentifier(connection)] {
            scheduleTimeout(state, connection: connection, interval: Self.idleTimeout)
        }
        let head = "HTTP/1.1 \(status)\r\n" +
            "Content-Length: \(body.count)\r\n" + extraHeaders +
            "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.finish(connection, keepAlive: keepAlive)
        })
    }

    private static let chunkSize = 1 << 20

    /// Sends the header block, then streams body (nil for HEAD responses).
    private func sendHead(_ connection: NWConnection, head: String, body: (file: FileHandle, remaining: Int64)?, keepAlive: Bool) {
        if let state = connectionStates[ObjectIdentifier(connection)] {
            scheduleTimeout(state, connection: connection, interval: Self.idleTimeout)
        }
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

    private func sendChunk(_ connection: NWConnection, file: FileHandle, remaining: Int64, keepAlive: Bool) {
        if let state = connectionStates[ObjectIdentifier(connection)] {
            scheduleTimeout(state, connection: connection, interval: Self.idleTimeout)
        }
        let data = file.readData(ofLength: Int(min(Int64(Self.chunkSize), remaining)))
        guard !data.isEmpty else {
            try? file.close()
            closeOnQueue(connection)
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
        guard let state = connectionStates[ObjectIdentifier(connection)] else {
            closeOnQueue(connection)
            return
        }
        state.processing = false
        if keepAlive {
            scheduleTimeout(state, connection: connection, interval: Self.idleTimeout)
            receiveRequest(connection)
        } else {
            closeOnQueue(connection)
        }
    }

    /// First non-loopback IPv4 address (en0/en1) for TV-visible cast URLs.
    static func lanIPv4() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  pointer.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(pointer.pointee.ifa_addr, socklen_t(pointer.pointee.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 { address = String(cString: host); break }
        }
        return address
    }
}
