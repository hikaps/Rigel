import Foundation

extension RigelHlsExporter {
    static func publishMasterPlaylist(
        baseMasterURL: URL,
        publicMasterURL: URL,
        subtitles: [SubtitleRendition]
    ) -> Bool {
        guard let base = try? String(contentsOf: baseMasterURL, encoding: .utf8) else {
            return false
        }
        let selected = subtitles.first(where: { $0.isSelectedExternal }) ?? subtitles.first
        let mediaLines = subtitles.map { rendition -> String in
            let fallback = "Subtitle-\(rendition.ordinal + 1)"
            var name = streamMapName(rendition.title, fallback: fallback)
            let isSelected = rendition === selected
            if rendition.isSelectedExternal && isSelected {
                name = "RigelSelected__\(name)"
            }
            var line = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(name)\""
            line += ",DEFAULT=\(isSelected ? "YES" : "NO"),AUTOSELECT=\(isSelected ? "YES" : "NO"),FORCED=NO"
            if let language = hlsLanguageValue(rendition.language) {
                line += ",LANGUAGE=\"\(language)\""
            }
            line += ",URI=\"\(rendition.playlistName)\""
            return line
        }
        var output: [String] = []
        var insertedMedia = false
        for rawLine in base.components(separatedBy: .newlines) {
            if !insertedMedia, rawLine.hasPrefix("#EXT-X-STREAM-INF:") {
                output.append(contentsOf: mediaLines)
                insertedMedia = true
            }
            var line = rawLine
            if !subtitles.isEmpty,
               line.hasPrefix("#EXT-X-STREAM-INF:"),
               !line.contains(",SUBTITLES=") {
                line += ",SUBTITLES=\"subs\""
            }
            output.append(line)
        }
        guard insertedMedia else { return false }
        let contents = output.joined(separator: "\n")
        return atomicallyWrite(contents + "\n", to: publicMasterURL)
    }

    static func finalizePresentationAsVOD(
        baseMasterURL: URL?,
        playlistURL: URL?,
        outDir: URL,
        subtitles: [SubtitleRendition]
    ) -> Bool {
        var playlistURLs: [URL] = []
        if let baseMasterURL {
            guard let master = try? String(contentsOf: baseMasterURL, encoding: .utf8) else {
                return false
            }
            let references = playlistReferences(in: master)
            guard !references.isEmpty else { return false }
            for reference in references {
                guard let url = safeChildURL(named: reference, in: outDir) else {
                    return false
                }
                playlistURLs.append(url)
            }
        }
        if let playlistURL {
            playlistURLs.append(playlistURL)
        }
        for subtitle in subtitles {
            guard let url = safeChildURL(named: subtitle.playlistName, in: outDir) else {
                return false
            }
            playlistURLs.append(url)
        }

        var seen = Set<String>()
        for url in playlistURLs where seen.insert(url.path).inserted {
            guard let playlist = try? String(contentsOf: url, encoding: .utf8),
                  let finalized = finalizedVODPlaylist(playlist),
                  atomicallyWrite(finalized, to: url) else {
                return false
            }
        }
        return !playlistURLs.isEmpty
    }

    static func finalizedVODPlaylist(_ playlist: String) -> String? {
        guard playlist.contains("#EXTM3U"),
              playlist.contains("#EXT-X-ENDLIST") else {
            return nil
        }
        if playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD") {
            return playlist
        }
        guard playlist.contains("#EXT-X-PLAYLIST-TYPE:EVENT") else {
            return nil
        }
        return playlist.replacingOccurrences(
            of: "#EXT-X-PLAYLIST-TYPE:EVENT",
            with: "#EXT-X-PLAYLIST-TYPE:VOD"
        )
    }
    static func presentationReady(
        baseMasterURL: URL,
        outDir: URL,
        subtitles: [SubtitleRendition],
        final: Bool
    ) -> Bool {
        guard let base = try? String(contentsOf: baseMasterURL, encoding: .utf8) else {
            return false
        }
        let mediaPlaylists = playlistReferences(in: base)
        guard !mediaPlaylists.isEmpty else { return false }
        for playlistName in mediaPlaylists {
            guard let playlistURL = safeChildURL(named: playlistName, in: outDir),
                  let playlist = try? String(contentsOf: playlistURL, encoding: .utf8) else {
                return false
            }
            let media = playlistReferences(in: playlist)
            guard !media.isEmpty else { return false }
            let requiredCount = !final && playlistName.contains("variant_0") ? 2 : 1
            guard media.count >= requiredCount else { return false }
            for mediaName in media {
                guard let mediaURL = safeChildURL(named: mediaName, in: outDir),
                      FileManager.default.fileExists(atPath: mediaURL.path) else {
                    return false
                }
            }
        }
        for rendition in subtitles {
            guard let playlistURL = safeChildURL(named: rendition.playlistName, in: outDir),
                  let playlist = try? String(contentsOf: playlistURL, encoding: .utf8),
                  playlist.contains("#EXTM3U"),
                  playlist.contains("#EXT-X-PLAYLIST-TYPE:EVENT") else {
                return false
            }
            for mediaName in playlistReferences(in: playlist) {
                guard let mediaURL = safeChildURL(named: mediaName, in: outDir),
                      FileManager.default.fileExists(atPath: mediaURL.path) else {
                    return false
                }
            }
        }
        return true
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

    private static func playlistReferences(in playlist: String) -> [String] {
        let lines = playlist.components(separatedBy: .newlines)
        let directReferences = lines.compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return line.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
        }
        let attributeReferences = lines.compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MEDIA:"),
                  let uriRange = line.range(of: "URI=\"") else {
                return nil
            }
            let valueStart = uriRange.upperBound
            guard let valueEnd = line[valueStart...].firstIndex(of: "\"") else {
                return nil
            }
            return line[valueStart..<valueEnd]
                .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
        }
        return directReferences + attributeReferences
    }

    private static func safeChildURL(named name: String, in directory: URL) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("..") else { return nil }
        let url = directory.appendingPathComponent(name)
        let directoryPath = directory.standardizedFileURL.path
        let childPath = url.standardizedFileURL.path
        guard childPath.hasPrefix(directoryPath + "/") else { return nil }
        return url
    }

    private static func atomicallyWrite(_ contents: String, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try contents.write(to: temporary, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    /// Supplies timestamps for remux packets whose source has no usable PTS/DTS.
    /// MPEG-TS/HLS cannot segment such packets reliably; keep the repair in the
    /// source stream time base before writeRemuxPacket rescales it.
    static func remuxFrameDuration(inputStream: UnsafeMutablePointer<AVStream>) -> Int64 {
        for rate in [inputStream.pointee.avg_frame_rate, inputStream.pointee.r_frame_rate]
            where rate.num > 0 && rate.den > 0 {
            let duration = av_rescale_q(
                1,
                AVRational(num: rate.den, den: rate.num),
                inputStream.pointee.time_base
            )
            if duration > 0 { return duration }
        }
        return 1
    }

    static func repairedRemuxTimestamps(
        pts: Int64,
        dts: Int64,
        duration: Int64,
        nextTimestamp: Int64?,
        frameDuration: Int64
    ) -> (pts: Int64, dts: Int64, nextTimestamp: Int64) {
        let step = max(duration, max(frameDuration, 1))
        let normalizedPTS = pts != Int64.min
            ? pts
            : (dts != Int64.min ? dts : (nextTimestamp ?? 0))
        let normalizedDTS = dts != Int64.min ? dts : normalizedPTS
        return (
            pts: normalizedPTS,
            dts: normalizedDTS,
            nextTimestamp: max(normalizedPTS, normalizedDTS) + step
        )
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
}
