import Foundation
import Network
import ComposeApp

/// Pure CASTV2 TCP framing helper. The protobuf envelope is encoded/decoded in Kotlin;
/// this layer only handles the 4-byte big-endian length prefix required by the socket.
enum ChromecastFraming {
    static let maxFrameLength = 16 * 1024 * 1024

    struct SplitResult {
        let frames: [Data]
        let remainder: Data
        let oversized: Bool
    }

    static func splitFrames(_ data: Data) -> SplitResult {
        var frames: [Data] = []
        var offset = 0
        while data.count - offset >= 4 {
            let length = (UInt32(data[offset]) << 24) |
                (UInt32(data[offset + 1]) << 16) |
                (UInt32(data[offset + 2]) << 8) |
                UInt32(data[offset + 3])
            guard length <= UInt32(maxFrameLength) else {
                return SplitResult(frames: frames, remainder: Data(), oversized: true)
            }
            let bodyStart = offset + 4
            let bodyEnd = bodyStart + Int(length)
            guard bodyEnd <= data.count else { break }
            frames.append(data.subdata(in: bodyStart..<bodyEnd))
            offset = bodyEnd
        }
        return SplitResult(
            frames: frames,
            remainder: data.subdata(in: offset..<data.count),
            oversized: false,
        )
    }
}

