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
    private var events: RendererEvents?
    private let queue = DispatchQueue(label: "rigel-upnp-renderer")
    private let ssdpQueue = DispatchQueue(label: "rigel-upnp-ssdp")
    private var currentUri: String?
    private(set) var port: UInt16 = 0
    private let deviceUuid = "uuid:rigel-renderer-0001"
    private var ssdpSocket: Int32 = -1

    // MARK: - Lifecycle

    /// Returns nil on success, or an error message.
    func start(events: RendererEvents) -> String? {
        self.events = events
        do {
            let listener = try NWListener(using: .tcp, on: 0)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = listener.port?.rawValue ?? 0
                    NSLog("[RigelRenderer] http ready on port %d", self?.port ?? 0)
                    self?.announceAlive()
                } else if case .failed(let error) = state {
                    NSLog("[RigelRenderer] listener failed: %@", error.localizedDescription)
                }
            }
            listener.start(queue: queue)
        } catch {
            return error.localizedDescription
        }
        return startSsdpResponder()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        if ssdpSocket >= 0 {
            close(ssdpSocket)
            ssdpSocket = -1
        }
        currentUri = nil
    }

    var isRunning: Bool { listener != nil }

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

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        var received = Data()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { received.append(data) }
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
        guard let text = String(data: request, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let body: String
        switch (method, path) {
        case ("GET", "/rootDesc.xml"):
            body = deviceDescription()
        case ("GET", "/AVTransport.xml"):
            body = scpd()
        case ("POST", "/ctl"):
            body = handleSoap(requestText: text)
        default:
            body = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            send(body: body, connection: connection)
            return
        }
        let response = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/xml; charset=\"utf-8\"\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" + body
        send(body: response, connection: connection)
    }

    private func send(body: String, connection: NWConnection) {
        let data = Data(body.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleSoap(requestText: String) -> String {
        let action = soapAction(requestText)
        switch action {
        case "SetAVTransportURI":
            if let uri = extractTag(requestText, "CurrentURI") {
                currentUri = uri
                let title = extractTag(requestText, "dc:title")
                let events = self.events
                DispatchQueue.main.async { events?.onSetUri(uri: uri) }
                _ = title
            }
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
            return soapResponse(
                "GetPositionInfoResponse",
                "<TrackDuration>00:00:00</TrackDuration><RelTime>00:00:00</RelTime>"
            )
        case "GetTransportInfo":
            return soapResponse(
                "GetTransportInfoResponse",
                "<CurrentTransportState>PLAYING</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus>"
            )
        default:
            return soapFault()
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

    private func soapFault() -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">" +
            "<s:Body><s:Fault><faultcode>s:Client</faultcode>" +
            "<faultstring>UPnPError</faultstring>" +
            "<detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>401</errorCode>" +
            "<errorDescription>Invalid Action</errorDescription></UPnPError></detail>" +
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

final class RigelRendererBridge: NSObject, RendererBridge {
    private let service = UpnpRendererService()

    func start(events: RendererEvents) -> String? {
        service.start(events: events)
    }

    func stop() {
        service.stop()
    }

    func isRunning() -> Bool {
        service.isRunning
    }
}
