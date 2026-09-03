import Foundation

extension RigelHlsExporter {
    static func markSelectedSubtitleName(in outDir: URL, output: SubtitleOutput) {
        let masterURL = outDir.appendingPathComponent("index.m3u8")
        guard var master = try? String(contentsOf: masterURL, encoding: .utf8),
              let mediaStart = master.range(of: "#EXT-X-MEDIA:TYPE=SUBTITLES"),
              let nameStart = master.range(
                  of: "NAME=\"",
                  range: mediaStart.upperBound..<master.endIndex
              ),
              let nameEnd = master[nameStart.upperBound...].firstIndex(of: "\"") else {
            return
        }
        let baseName = streamMapName(
            output.input.title,
            fallback: "Subtitle-\(output.ordinal + 1)"
        )
        master.replaceSubrange(
            nameStart.upperBound..<nameEnd,
            with: "RigelSelected__\(baseName)"
        )
        try? master.write(to: masterURL, atomically: true, encoding: .utf8)
    }
    static func playlistReady(
        playlistPath: String,
        outDir: URL,
        variantCount: Int,
        final: Bool
    ) -> Bool {
        let masterPath = outDir.appendingPathComponent("index.m3u8").path
        if let master = try? String(contentsOfFile: masterPath, encoding: .utf8),
           master.contains("#EXT-X-STREAM-INF"),
           FileManager.default.fileExists(atPath: outDir.appendingPathComponent("seg0_00000.ts").path) {
            if final { return true }
            guard FileManager.default.fileExists(
                atPath: outDir.appendingPathComponent("seg0_00001.ts").path
            ) else {
                return false
            }
            for variant in 1..<variantCount {
                guard FileManager.default.fileExists(
                    atPath: outDir.appendingPathComponent("seg\(variant)_00000.ts").path
                ) else {
                    return false
                }
            }
            return true
        }

        guard let playlist = try? String(contentsOfFile: playlistPath, encoding: .utf8),
              playlist.contains("#EXTINF"),
              FileManager.default.fileExists(atPath: outDir.appendingPathComponent("seg00000.ts").path) else {
            return false
        }
        if final { return true }
        return FileManager.default.fileExists(atPath: outDir.appendingPathComponent("seg00001.ts").path)
    }

    static func writeRemuxPacket(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        inStream: UnsafeMutablePointer<AVStream>,
        outStream: UnsafeMutablePointer<AVStream>,
        out: UnsafeMutablePointer<AVFormatContext>
    ) {
        pkt.pointee.stream_index = outStream.pointee.index
        av_packet_rescale_ts(pkt, inStream.pointee.time_base, outStream.pointee.time_base)
        pkt.pointee.pos = -1
        av_interleaved_write_frame(out, pkt)
    }

    static func writeRemuxPacketCopies(
        _ packet: UnsafeMutablePointer<AVPacket>,
        inStream: UnsafeMutablePointer<AVStream>,
        outStreams: [UnsafeMutablePointer<AVStream>],
        out: UnsafeMutablePointer<AVFormatContext>
    ) {
        for outStream in outStreams {
            var copy = AVPacket()
            av_init_packet(&copy)
            guard av_packet_ref(&copy, packet) >= 0 else { continue }
            writeRemuxPacket(&copy, inStream: inStream, outStream: outStream, out: out)
            av_packet_unref(&copy)
        }
    }
}
