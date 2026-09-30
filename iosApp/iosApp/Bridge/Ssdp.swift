import Foundation
import Darwin
import ComposeApp

/// Minimal SSDP client: sends M-SEARCH datagrams to 239.255.255.250:1900 and
/// collects unicast replies on the same socket until timeout.
/// Send-only multicast + unicast replies — does not join the group, so the
/// com.apple.developer.networking.multicast entitlement is not required.
enum Ssdp {
    static let multicastHost = "239.255.255.250"
    static let multicastPort: UInt16 = 1900

    /// Pure packet builder — unit-tested against a byte fixture.
    static func packet(searchTarget: String) -> Data {
        let s = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: \(multicastHost):\(multicastPort)\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 3\r\n" +
            "ST: \(searchTarget)\r\n\r\n"
        return Data(s.utf8)
    }

    struct Reply {
        let usn: String
        let location: String
        let server: String?
        let searchTarget: String
        let responderAddress: String?
    }

    /// Parse an SSDP response's header block (CRLF-terminated). Pure — testable.
    static func parseReply(_ data: Data, responderAddress: String? = nil) -> Reply? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 200") else { return nil }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let usn = headers["usn"], let location = headers["location"] else { return nil }
        return Reply(
            usn: usn,
            location: location,
            server: headers["server"],
            searchTarget: headers["st"] ?? "",
            responderAddress: responderAddress
        )
    }

    /// Blocking search with a global timeout. Calls `onResult` on the main queue.
    static func search(
        searchTargets: [String],
        timeoutMs: Int,
        onResult: @escaping ([SsdpDevice]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [SsdpDevice] = []
            defer { DispatchQueue.main.async { onResult(out) } }

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = 0
            local.sin_addr.s_addr = INADDR_ANY
            let localPtr = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }
            guard bind(fd, localPtr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else { return }

            var ttl: UInt8 = 2
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

            for target in searchTargets {
                var mcast = sockaddr_in()
                mcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                mcast.sin_family = sa_family_t(AF_INET)
                mcast.sin_port = multicastPort.bigEndian
                inet_pton(AF_INET, multicastHost, &mcast.sin_addr)
                let mcastPtr = withUnsafePointer(to: &mcast) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                }
                let packet = packet(searchTarget: target)
                packet.withUnsafeBytes { buf in
                    _ = sendto(fd, buf.baseAddress, packet.count, 0, mcastPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
            var seen = Set<String>()
            while DispatchTime.now() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let remaining = deadline.uptimeNanoseconds - DispatchTime.now().uptimeNanoseconds
                guard remaining > 0 else { break }
                let ms = Int(remaining / 1_000_000)
                let pollRet = poll(&pfd, 1, Int32(ms))
                guard pollRet > 0 else { break }
                var buffer = [UInt8](repeating: 0, count: 65536)
                var responder = sockaddr_storage()
                var responderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &responder) { responderPtr in
                    responderPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { responderSockaddr in
                        recvfrom(fd, &buffer, buffer.count, 0, responderSockaddr, &responderLength)
                    }
                }
                guard n > 0 else { continue }
                let responderAddress: String? = withUnsafePointer(to: &responder) { responderPtr in
                    responderPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4Ptr in
                        guard ipv4Ptr.pointee.sin_family == sa_family_t(AF_INET) else { return nil }
                        var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var value = ipv4Ptr.pointee.sin_addr
                        guard inet_ntop(AF_INET, &value, &address, socklen_t(INET_ADDRSTRLEN)) != nil else {
                            return nil
                        }
                        return String(cString: address)
                    }
                }
                guard let reply = parseReply(Data(buffer.prefix(n)), responderAddress: responderAddress) else { continue }
                let key = "\(reply.usn)|\(reply.searchTarget)"
                if seen.contains(key) { continue }
                seen.insert(key)
                out.append(SsdpDevice(
                    usn: reply.usn,
                    location: reply.location,
                    server: reply.server,
                    searchTarget: reply.searchTarget,
                    responderAddress: reply.responderAddress
                ))
            }
        }
    }
}
