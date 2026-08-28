import Foundation

enum SubtitleParser {
    struct Cue: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    /// Decode subtitle bytes without forcing every source through UTF-8.
    /// UTF-8 remains the first legacy-free fallback; Windows-1252 and Latin-1
    /// cover the common non-Unicode subtitle files while preserving Unicode.
    static func decode(data: Data, encodingName: String? = nil) -> String? {
        let prefix = Array(data.prefix(4))
        if prefix == [0xFF, 0xFE, 0x00, 0x00] {
            return String(data: data, encoding: .utf32LittleEndian)
        }
        if prefix == [0x00, 0x00, 0xFE, 0xFF] {
            return String(data: data, encoding: .utf32BigEndian)
        }
        if Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF] {
            return String(data: data, encoding: .utf8)
        }
        if Array(data.prefix(2)) == [0xFF, 0xFE] {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if Array(data.prefix(2)) == [0xFE, 0xFF] {
            return String(data: data, encoding: .utf16BigEndian)
        }

        if let encodingName,
           let encoding = encoding(for: encodingName),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let decoded = decodeBOMlessUTF16(data) {
            return decoded
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func encoding(for rawName: String) -> String.Encoding? {
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch name {
        case "utf-8", "utf8":
            return .utf8
        case "utf-16", "utf16", "unicode":
            return .utf16
        case "utf-16le", "utf-16-le", "unicodefffe":
            return .utf16LittleEndian
        case "utf-16be", "utf-16-be":
            return .utf16BigEndian
        case "utf-32", "utf32":
            return .utf32
        case "utf-32le", "utf-32-le":
            return .utf32LittleEndian
        case "utf-32be", "utf-32-be":
            return .utf32BigEndian
        case "us-ascii", "ascii":
            return .ascii
        case "windows-1252", "windows1252", "cp1252":
            return .windowsCP1252
        case "iso-8859-1", "iso8859-1", "latin1", "l1":
            return .isoLatin1
        default:
            return nil
        }
    }

    static func decodeCString(_ pointer: UnsafePointer<CChar>) -> String? {
        let data = Data(bytes: pointer, count: Int(strlen(pointer)))
        return decode(data: data)
    }

    private static func decodeBOMlessUTF16(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let sample = Array(data.prefix(min(data.count, 128)))
        let oddNulls = stride(from: 1, to: sample.count, by: 2)
            .reduce(into: 0) { count, index in
                if sample[index] == 0 { count += 1 }
            }
        let evenNulls = stride(from: 0, to: sample.count, by: 2)
            .reduce(into: 0) { count, index in
                if sample[index] == 0 { count += 1 }
            }
        let threshold = max(1, sample.count / 8)
        if oddNulls >= threshold, oddNulls > evenNulls * 2 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if evenNulls >= threshold, evenNulls > oddNulls * 2 {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    static func parseSRT(_ text: String) -> [Cue] {
        parseBlocks(text) { block in
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseRange(block[timingIndex]) else {
                return nil
            }
            return makeCue(start: start, end: end, lines: block.dropFirst(timingIndex + 1))
        }
    }

    static func parseVTT(_ text: String) -> [Cue] {
        parseBlocks(text) { block in
            guard let first = block.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  first.uppercased() != "WEBVTT",
                  !first.uppercased().hasPrefix("NOTE"),
                  !first.uppercased().hasPrefix("STYLE"),
                  let timingIndex = block.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseRange(block[timingIndex]) else {
                return nil
            }
            return makeCue(start: start, end: end, lines: block.dropFirst(timingIndex + 1))
        }
    }

    private static func parseBlocks(
        _ text: String,
        parser: ([String]) -> Cue?
    ) -> [Cue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{feff}", with: "")
        var cues: [Cue] = []
        var block: [String] = []
        for line in normalized.components(separatedBy: "\n") + [""] {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let cue = parser(block) {
                    cues.append(cue)
                }
                block.removeAll(keepingCapacity: true)
            } else {
                block.append(line)
            }
        }
        return cues.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }
    }

    private static func parseRange(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2,
              let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let endToken = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
              let end = parseTimestamp(String(endToken)),
              end > start else {
            return nil
        }
        return (start, end)
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let value = raw.replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts.last ?? "") else {
            return nil
        }
        if parts.count == 2 {
            guard let minutes = Double(parts[0]), minutes >= 0, seconds >= 0 else { return nil }
            return minutes * 60 + seconds
        }
        guard let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              hours >= 0,
              minutes >= 0,
              minutes < 60,
              seconds >= 0,
              seconds < 60 else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func decodeEntities(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&" else {
                output.append(value[index])
                index = value.index(after: index)
                continue
            }
            let bodyStart = value.index(after: index)
            guard let semicolon = value[bodyStart...].firstIndex(of: ";"),
                  value.distance(from: bodyStart, to: semicolon) <= 16 else {
                output.append("&")
                index = bodyStart
                continue
            }
            let body = String(value[bodyStart..<semicolon])
            if let replacement = decodeEntity(body) {
                output.append(contentsOf: replacement)
                index = value.index(after: semicolon)
            } else {
                output.append("&")
                index = bodyStart
            }
        }
        return output
    }

    private static func decodeEntity(_ body: String) -> String? {
        switch body.lowercased() {
        case "nbsp": return " "
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "ndash": return "–"
        case "mdash": return "—"
        case "hellip": return "…"
        case "laquo": return "«"
        case "raquo": return "»"
        case "copy": return "©"
        case "reg": return "®"
        case "trade": return "™"
        default:
            break
        }
        let lower = body.lowercased()
        let value: UInt32?
        if lower.hasPrefix("#x") {
            value = UInt32(body.dropFirst(2), radix: 16)
        } else if lower.hasPrefix("#") {
            value = UInt32(body.dropFirst(), radix: 10)
        } else {
            value = nil
        }
        guard let value,
              value <= 0x10FFFF,
              !(0xD800...0xDFFF).contains(value),
              let scalar = UnicodeScalar(value) else {
            return nil
        }
        return String(scalar)
    }

    private static func makeCue(
        start: TimeInterval,
        end: TimeInterval,
        lines: ArraySlice<String>
    ) -> Cue? {
        let rawText = lines.joined(separator: "\n")
        let stripped: String
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            let range = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
            stripped = regex.stringByReplacingMatches(
                in: rawText,
                options: [],
                range: range,
                withTemplate: ""
            )
        } else {
            stripped = rawText
        }
        let cleaned = decodeEntities(stripped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Cue(start: start, end: end, text: cleaned)
    }
}
