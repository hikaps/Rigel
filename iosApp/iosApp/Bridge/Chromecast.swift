import Foundation
import Network
import ComposeApp

/// Pure CASTV2 TCP framing helper. The protobuf envelope is encoded/decoded in Kotlin;
/// this layer only handles the 4-byte big-endian length prefix required by the socket.
enum ChromecastFraming {
    static func splitFrames(_ data: Data) -> (frames: [Data], remainder: Data) {
        var frames: [Data] = []
        var offset = 0
        while data.count - offset >= 4 {
            let length = (UInt32(data[offset]) << 24) |
                (UInt32(data[offset + 1]) << 16) |
                (UInt32(data[offset + 2]) << 8) |
                UInt32(data[offset + 3])
            let bodyStart = offset + 4
            let bodyEnd = bodyStart + Int(length)
            guard bodyEnd <= data.count else { break }
            frames.append(data.subdata(in: bodyStart..<bodyEnd))
            offset = bodyEnd
        }
        return (frames, data.subdata(in: offset..<data.count))
    }
}

final class RigelChromecastBridge: NSObject, ChromecastBridge {
    private var activeDiscovery: ChromecastDiscovery?
    private var activeConnections: [CastTLSConnection] = []
    func discover(timeoutMs: Int32, onResult: @escaping ([ChromeDevice]) -> Void) {
        let discovery = ChromecastDiscovery(timeoutMs: Int(timeoutMs)) { [weak self] devices in
            self?.activeDiscovery = nil
            onResult(devices)
        }
        activeDiscovery = discovery
        discovery.start()
    }

    func open(
        host: String,
        port: Int32,
        onFrame: @escaping (KotlinByteArray) -> Void,
        onOpen: @escaping (CastWireConnection?, String?) -> Void,
    ) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: Int(port))) else {
            onOpen(nil, "Invalid Chromecast port")
            return
        }
        let connection = CastTLSConnection(
            host: host,
            port: nwPort,
            onFrame: onFrame,
            onOpen: onOpen,
        )
        connection.onClosed = { [weak self] closed in
            self?.activeConnections.removeAll { $0 === closed }
        }
        activeConnections.append(connection)
        connection.start()
    }
}

private final class ChromecastDiscovery {
    private let timeoutMs: Int
    private let onResult: ([ChromeDevice]) -> Void
    private let queue = DispatchQueue(label: "rigel-chromecast-discovery")
    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []
    private var seen = Set<String>()
    private var devices: [ChromeDevice] = []
    private var finished = false

    init(timeoutMs: Int, onResult: @escaping ([ChromeDevice]) -> Void) {
        self.timeoutMs = max(timeoutMs, 1)
        self.onResult = onResult
    }

    func start() {
        let browser = NWBrowser(
            for: .bonjour(type: "_googlecast._tcp", domain: nil),
            using: .tcp,
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                NSLog("[RigelChromecast] discovery failed: %@", error.localizedDescription)
                self?.finish()
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                self.resolve(result.endpoint, id: name, name: name)
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
            self?.finish()
        }
    }

    private func resolve(_ endpoint: NWEndpoint, id: String, name: String) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        let resolver = NWConnection(to: endpoint, using: .tcp)
        resolvers.append(resolver)
        resolver.stateUpdateHandler = { [weak self, weak resolver] state in
            guard let self, let resolver else { return }
            switch state {
            case .ready:
                if let (host, port) = Self.hostPort(resolver.currentPath?.remoteEndpoint) {
                    self.devices.append(ChromeDevice(id: id, host: host, port: port, name: name))
                }
                self.resolvers.removeAll { $0 === resolver }
                resolver.cancel()
            case .failed, .cancelled:
                self.resolvers.removeAll { $0 === resolver }
                resolver.cancel()
            default:
                break
            }
        }
        resolver.start(queue: queue)
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        browser = nil
        resolvers.forEach { $0.cancel() }
        resolvers.removeAll()
        let result = devices
        DispatchQueue.main.async { [onResult] in onResult(result) }
    }

    private static func hostPort(_ endpoint: NWEndpoint?) -> (String, Int32)? {
        guard let endpoint else { return nil }
        guard case let .hostPort(host, port) = endpoint else { return nil }
        return (host.debugDescription, Int32(port.rawValue))
    }
}

private final class CastTLSConnection: NSObject, CastWireConnection {
    private let host: String
    private let port: NWEndpoint.Port
    private let onFrame: (KotlinByteArray) -> Void
    private let onOpen: (CastWireConnection?, String?) -> Void
    var onClosed: ((CastTLSConnection) -> Void)?
    private let queue = DispatchQueue(label: "rigel-chromecast-connection")
    private var connection: NWConnection?
    private var received = Data()
    private var openCallbackSent = false
    private var closed = false

    init(
        host: String,
        port: NWEndpoint.Port,
        onFrame: @escaping (KotlinByteArray) -> Void,
        onOpen: @escaping (CastWireConnection?, String?) -> Void,
    ) {
        self.host = host
        self.port = port
        self.onFrame = onFrame
        self.onOpen = onOpen
    }

    func start() {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.openCallbackSent else { return }
                self.openCallbackSent = true
                DispatchQueue.main.async { [self] in self.onOpen(self, nil) }
                self.receive()
            case .failed(let error):
                if !self.openCallbackSent {
                    self.openCallbackSent = true
                    DispatchQueue.main.async { [self] in self.onOpen(nil, error.localizedDescription) }
                }
                self.close()
            case .cancelled:
                if !self.openCallbackSent {
                    self.openCallbackSent = true
                    DispatchQueue.main.async { [self] in self.onOpen(nil, "Chromecast connection cancelled") }
                }
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)

    }
    func send(frame: KotlinByteArray) {
        let body = data(from: frame)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)
        connection?.send(content: packet, completion: .contentProcessed { error in
            if let error {
                NSLog("[RigelChromecast] send failed: %@", error.localizedDescription)
            }
        })
    }
    func close() {
        guard !closed else { return }
        closed = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let callback = onClosed
        onClosed = nil
        callback?(self)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.received.append(data)
                let split = ChromecastFraming.splitFrames(self.received)
                self.received = split.remainder
                for frame in split.frames {
                    let bytes = kotlinByteArray(from: frame)
                    DispatchQueue.main.async { [onFrame] in onFrame(bytes) }
                }
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func data(from bytes: KotlinByteArray) -> Data {
        var result = Data()
        result.reserveCapacity(Int(bytes.size))
        for index in 0..<Int(bytes.size) {
            result.append(UInt8(bitPattern: bytes.get(index: Int32(index))))
        }
        return result
    }

    private func kotlinByteArray(from data: Data) -> KotlinByteArray {
        let result = KotlinByteArray(size: Int32(data.count))
        for index in 0..<data.count {
            result.set(index: Int32(index), value: Int8(bitPattern: data[index]))
        }
        return result
    }
}
