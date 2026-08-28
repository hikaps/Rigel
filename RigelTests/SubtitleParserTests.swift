import XCTest
@testable import Rigel

final class SubtitleParserTests: XCTestCase {
    func testSRTParsesMultilineCuesAndSortsByStart() {
        let text = """
        2
        00:00:03,500 --> 00:00:05,000
        <i>Later</i> line

        1
        00:00:00,000 --> 00:00:01,250
        First line
        Second line
        """

        XCTAssertEqual(
            SubtitleParser.parseSRT(text),
            [
                .init(start: 0, end: 1.25, text: "First line\nSecond line"),
                .init(start: 3.5, end: 5, text: "Later line"),
            ]
        )
    }

    func testSRTSkipsMalformedAndEmptyCues() {
        let text = """
        1
        not a timestamp
        ignored

        2
        00:00:04,000 --> 00:00:03,000
        Backwards

        3
        00:00:05,000 --> 00:00:06,000

        4
        00:00:07,000 --> 00:00:08,000
        Valid
        """

        XCTAssertEqual(
            SubtitleParser.parseSRT(text),
            [.init(start: 7, end: 8, text: "Valid")]
        )
    }

    func testVTTHandlesHeaderNotesCueIdsAndShortTimestamps() {
        let text = """
        WEBVTT - captions

        NOTE
        this is metadata

        cue-2
        1:02.500 --> 1:04.000 align:start
        <b>Hello</b> &amp; goodbye

        00:00:00.250 --> 00:00:01.000
        Early
        """

        XCTAssertEqual(
            SubtitleParser.parseVTT(text),
            [
                .init(start: 0.25, end: 1, text: "Early"),
                .init(start: 62.5, end: 64, text: "Hello & goodbye"),
            ]
        )
    }

    func testVTTSkipsMalformedAndEmptyCues() {
        let text = """
        WEBVTT

        00:00:01.000 --> invalid
        ignored

        00:00:02.000 --> 00:00:03.000
        <c.colorE5E5E5></c>
        """

        XCTAssertTrue(SubtitleParser.parseVTT(text).isEmpty)
    }
    func testDecodeSupportsAsciiUnicodeAndLegacySubtitleBytes() {
        XCTAssertEqual(
            SubtitleParser.decode(data: Data("ASCII subtitle".utf8)),
            "ASCII subtitle"
        )

        let utf16Text = "Café — 日本語"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(contentsOf: utf16Text.data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(
            SubtitleParser.decode(data: utf16)?
                .replacingOccurrences(of: "\u{feff}", with: ""),
            utf16Text
        )

        let windows1252 = Data([
            0x43, 0x61, 0x66, 0xE9, 0x20, 0x96, 0x20, 0x64, 0xE9, 0x6A, 0xE0,
        ])
        XCTAssertEqual(
            SubtitleParser.decode(data: windows1252, encodingName: "windows-1252"),
            "Café – déjà"
        )
    }

    func testSRTDecodesNumericAndNamedEntities() {
        let text = """
        1
        00:00:00,000 --> 00:00:02,000
        Caf&#xE9; &mdash; &#233;
        """

        XCTAssertEqual(
            SubtitleParser.parseSRT(text),
            [.init(start: 0, end: 2, text: "Café — é")]
        )
    }

}
