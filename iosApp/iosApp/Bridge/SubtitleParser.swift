import Foundation

enum SubtitleParser {
    struct Cue: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
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
        let cleaned = stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return Cue(start: start, end: end, text: cleaned)
    }
}
