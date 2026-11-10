import Foundation
import Network
import Darwin
import ComposeApp

/// Minimal UPnP AVTransport MediaRenderer so control points (Kodi "Play using…",
/// BubbleUPnP, Jellyfin-web) can push playback TO Rigel.
/// SSDP responder requires joining the multicast group → the
/// com.apple.developer.networking.multicast entitlement; start() reports its absence.
final class UpnpRendererService {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var connectionStates: [ObjectIdentifier: RigelHTTPConnectionState] = [:]
    private var events: RendererEvents?
    private let queue = DispatchQueue(label: "rigel-upnp-renderer")
    private let ssdpQueue = DispatchQueue(label: "rigel-upnp-ssdp")
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private var currentUri: String?
    private var portValue: UInt16 = 0
    private var runningValue = false
    private let deviceUuid = "uuid:rigel-renderer-0001"
    private var ssdpSocket: Int32 = -1
    private static let maxConnections = 16
    private static let headerTimeout: DispatchTimeInterval = .seconds(10)
    private static let idleTimeout: DispatchTimeInterval = .seconds(30)

    var port: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return portValue
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runningValue
    }

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    private func setPort(_ value: UInt16) {
        stateLock.lock()
        portValue = value
        stateLock.unlock()
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        runningValue = value
        stateLock.unlock()
    }

    // MARK: - Lifecycle

    /// Returns nil on success, or an error message. TCP and SSDP startup is
    /// transactional: a failed multicast setup rolls back the TCP listener.
    func start(events: RendererEvents) -> String? {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return startOnQueue(events: events)
        }
        var result: String?
        queue.sync { result = self.startOnQueue(events: events) }
        return result
    }

    private func startOnQueue(events: RendererEvents) -> String? {
        guard listener == nil else { return "UPnP renderer is already running" }
        self.events = events
        setPort(0)
        do {
            let newListener = try NWListener(using: .tcp, on: 0)
            listener = newListener
            setRunning(true)
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
            rollbackOnQueue()
            return error.localizedDescription
        }
        if let error = startSsdpResponder() {
            rollbackOnQueue()
            return error
        }
        return nil
    }

    private func listenerStateOnQueue(_ candidate: NWListener, state: NWListener.State) {
        guard listener === candidate else { return }
        switch state {
        case .ready:
            let readyPort = candidate.port?.rawValue ?? 0
            setPort(readyPort)
            NSLog("[RigelRenderer] http ready on port %d", readyPort)
            announceAlive()
        case .failed(let error):
            NSLog("[RigelRenderer] listener failed: %@", error.localizedDescription)
            rollbackOnQueue()
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
        setRunning(false)
        setPort(0)
        closeAllConnectionsOnQueue()
        closeSsdpOnQueue()
        currentUri = nil
        events = nil
    }

    private func rollbackOnQueue() {
        listener?.cancel()
        listener = nil
        setRunning(false)
        setPort(0)
        closeAllConnectionsOnQueue()
        closeSsdpOnQueue()
        currentUri = nil
        events = nil
    }

    private func closeSsdpOnQueue() {
        if ssdpSocket >= 0 {
            close(ssdpSocket)
            ssdpSocket = -1
        }
    }

    // MARK: - SSDP responder (multicast join → entitlement)

    private func startSsdpResponder() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "socket failed" }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let ptr = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }
        guard bind(fd, ptr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
            close(fd)
            return "SSDP bind failed"
        }
        var mreq = ip_mreq()
        inet_pton(AF_INET, "239.255.255.250", &mreq.imr_multiaddr)
        mreq.imr_interface.s_addr = INADDR_ANY
        let joinRet = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        guard joinRet == 0 else {
            close(fd)
            return "SSDP multicast join failed — com.apple.developer.networking.multicast entitlement required"
        }
        ssdpSocket = fd
        ssdpQueue.async { [weak self] in self?.respondLoop(fd: fd) }
        return nil
    }

    private func respondLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, saPtr, &fromLen)
                }
            }
            if n <= 0 { return }
            guard let text = String(data: Data(buffer.prefix(n)), encoding: .utf8),
                  text.contains("M-SEARCH"),
                  text.contains("urn:schemas-upnp-org:device:MediaRenderer:1") else { continue }
            guard let ip = RigelHttpServer.lanIPv4() else { continue }
            let response = "HTTP/1.1 200 OK\r\n" +
                "CACHE-CONTROL: max-age=1800\r\n" +
                "LOCATION: http://\(ip):\(port)/rootDesc.xml\r\n" +
                "SERVER: Rigel/1.0 UPnP/1.0\r\n" +
                "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n" +
                "USN: \(deviceUuid)::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
            var dest = from
            let data = Data(response.utf8)
            data.withUnsafeBytes { buf in
                withUnsafePointer(to: &dest) { destPtr in
                    destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        _ = sendto(fd, buf.baseAddress, data.count, 0, saPtr, fromLen)
                    }
                }
            }
        }
    }

    private func announceAlive() {
        guard let ip = RigelHttpServer.lanIPv4() else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var mcast = sockaddr_in()
        mcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        mcast.sin_family = sa_family_t(AF_INET)
        mcast.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &mcast.sin_addr)
        let msg = "NOTIFY * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "CACHE-CONTROL: max-age=1800\r\n" +
            "LOCATION: http://\(ip):\(port)/rootDesc.xml\r\n" +
            "NT: urn:schemas-upnp-org:device:MediaRenderer:1\r\n" +
            "NTS: ssdp:alive\r\n" +
            "SERVER: Rigel/1.0 UPnP/1.0\r\n" +
            "USN: \(deviceUuid)::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        let data = Data(msg.utf8)
        data.withUnsafeBytes { buf in
            withUnsafePointer(to: &mcast) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    _ = sendto(fd, buf.baseAddress, data.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - HTTP + SOAP

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

    private func closeAllConnectionsOnQueue() {
        for connection in connections { connection.cancel() }
        for state in connectionStates.values { state.cancelTimer() }
        connections.removeAll()
        connectionStates.removeAll()
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
        // EOF only prevents future reads. Complete frames already buffered
        // by the final receive still need to be served in order.
        switch state.framer.next() {
        case .frame(let frame):
            state.cancelTimer()
            state.processing = true
            respond(connection: connection, frame: frame, halfClosed: state.inputClosed && !state.framer.hasBufferedData)
        case .invalid:
            closeOnQueue(connection)
        case .continueRequestBody:
            sendContinue(connection)
        case .needMore:
            if state.inputClosed {
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
        guard let head = String(data: frame.head, encoding: .utf8),
              let line = head.components(separatedBy: "\r\n").first else {
            closeOnQueue(connection)
            return
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            closeOnQueue(connection)
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let requestWantsClose = head
            .components(separatedBy: "\r\n")
            .dropFirst()
            .contains { headerLine in
                guard let separator = headerLine.firstIndex(of: ":") else { return false }
                let name = headerLine[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                let value = headerLine[headerLine.index(after: separator)...].lowercased()
                return name == "connection" && value.split(separator: ",").contains {
                    $0.trimmingCharacters(in: .whitespaces) == "close"
                }
            }
        let body: String
        let status: String
        switch (method, path) {
        case ("GET", "/rootDesc.xml"):
            body = deviceDescription()
            status = "200 OK"
        case ("GET", "/AVTransport.xml"):
            body = scpd()
            status = "200 OK"
        case ("POST", "/ctl"):
            var requestData = frame.head
            requestData.append(frame.body)
            guard let requestText = String(data: requestData, encoding: .utf8) else {
                closeOnQueue(connection)
                return
            }
            body = handleSoap(requestText: requestText)
            status = body.contains("<s:Fault>") ? "500 Internal Server Error" : "200 OK"
        default:
            send(body: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", connection: connection, keepAlive: false)
            return
        }
        let keepAlive = !halfClosed && !requestWantsClose
        let response = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: text/xml; charset=\"utf-8\"\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n" + body
        send(body: response, connection: connection, keepAlive: keepAlive)
    }

    private func send(body: String, connection: NWConnection, keepAlive: Bool) {
        if let state = connectionStates[ObjectIdentifier(connection)] {
            scheduleTimeout(state, connection: connection, interval: Self.idleTimeout)
        }
        let data = Data(body.utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.finish(connection, keepAlive: keepAlive)
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

    private func handleSoap(requestText: String) -> String {
        let action = soapAction(requestText)
        switch action {
        case "SetAVTransportURI":
            guard let rawUri = extractTag(requestText, "CurrentURI"),
                  rawUri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return soapFault(errorCode: 402, errorDescription: "Invalid Args")
            }
            let uri = rawUri
            currentUri = uri
            let title = extractTag(requestText, "dc:title")
            let events = self.events
            DispatchQueue.main.async { events?.onSetUri(uri: uri, title: title) }
            return soapResponse("SetAVTransportURIResponse")
        case "Play":
            let events = self.events
            DispatchQueue.main.async { events?.onPlay() }
            return soapResponse("PlayResponse")
        case "Pause":
            let events = self.events
            DispatchQueue.main.async { events?.onPause() }
            return soapResponse("PauseResponse")
        case "Stop":
            currentUri = nil
            let events = self.events
            DispatchQueue.main.async { events?.onStop() }
            return soapResponse("StopResponse")
        case "GetPositionInfo":
            return soapResponse("GetPositionInfoResponse", "<TrackDuration>00:00:00</TrackDuration><RelTime>00:00:00</RelTime>")
        case "GetTransportInfo":
            return soapResponse("GetTransportInfoResponse", "<CurrentTransportState>PLAYING</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus>")
        default:
            return soapFault(errorCode: 401, errorDescription: "Invalid Action")
        }
    }

    private func soapAction(_ text: String) -> String {
        for line in text.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("soapaction:") {
                let value = line.dropFirst("SOAPACTION:".count).trimmingCharacters(in: .whitespaces)
                return value.components(separatedBy: "#").last?.replacingOccurrences(of: "\"", with: "") ?? ""
            }
        }
        return ""
    }

    private func extractTag(_ text: String, _ tag: String) -> String? {
        guard let range = text.range(of: "<\(tag)>") else { return nil }
        let start = range.upperBound
        guard let end = text.range(of: "</\(tag)>", range: start..<text.endIndex) else { return nil }
        return String(text[start..<end.lowerBound])
    }

    private func soapResponse(_ action: String, _ extra: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
            "<s:Body><u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">" +
            extra +
            "</u:\(action)></s:Body></s:Envelope>"
    }

    private func soapFault(errorCode: Int, errorDescription: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">" +
            "<s:Body><s:Fault><faultcode>s:Client</faultcode>" +
            "<faultstring>UPnPError</faultstring>" +
            "<detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>\(errorCode)</errorCode>" +
            "<errorDescription>\(errorDescription)</errorDescription></UPnPError></detail>" +
            "</s:Fault></s:Body></s:Envelope>"
    }

    private func deviceDescription() -> String {
        "<?xml version=\"1.0\"?>\n" +
            "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">\n" +
            "<specVersion><major>1</major><minor>0</minor></specVersion>\n" +
            "<device>\n" +
            "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>\n" +
            "<friendlyName>Rigel</friendlyName>\n" +
            "<manufacturer>Rigel</manufacturer>\n" +
            "<modelName>Rigel iOS Player</modelName>\n" +
            "<UDN>\(deviceUuid)</UDN>\n" +
            "<serviceList>\n" +
            "<service>\n" +
            "<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>\n" +
            "<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>\n" +
            "<SCPDURL>/AVTransport.xml</SCPDURL>\n" +
            "<controlURL>/ctl</controlURL>\n" +
            "<eventSubURL>/evt</eventSubURL>\n" +
            "</service>\n" +
            "</serviceList>\n" +
            "</device>\n" +
            "</root>\n"
    }

    private func scpd() -> String {
        "<?xml version=\"1.0\"?>\n" +
            "<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">\n" +
            "<specVersion><major>1</major><minor>0</minor></specVersion>\n" +
            "<actionList>\n" +
            "<action><name>SetAVTransportURI</name><argumentList>\n" +
            "<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>\n" +
            "<argument><name>CurrentURI</name><direction>in</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>\n" +
            "<argument><name>CurrentURIMetaData</name><direction>in</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>\n" +
            "</argumentList></action>\n" +
            "<action><name>Play</name><argumentList><argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument><argument><name>Speed</name><direction>in</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument></argumentList></action>\n" +
            "<action><name>Pause</name></action>\n" +
            "<action><name>Stop</name></action>\n" +
            "<action><name>GetPositionInfo</name></action>\n" +
            "<action><name>GetTransportInfo</name></action>\n" +
            "</actionList>\n" +
            "<serviceStateTable>\n" +
            "<stateVariable sendEvents=\"no\"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>\n" +
            "<stateVariable sendEvents=\"no\"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>\n" +
            "<stateVariable sendEvents=\"no\"><name>TransportPlaySpeed</name><dataType>string</dataType></stateVariable>\n" +
            "<stateVariable sendEvents=\"no\"><name>CurrentTransportState</name><dataType>string</dataType></stateVariable>\n" +
            "</serviceStateTable>\n" +
            "</scpd>\n"
    }
}
