import XCTest
@testable import Rigel

final class ChromecastFramingTest: XCTestCase {
    func testSplitsOneCompleteFrame() {
        let data = packet(Data([1, 2, 3]))
        let result = ChromecastFraming.splitFrames(data)
        XCTAssertEqual(result.frames, [Data([1, 2, 3])])
        XCTAssertTrue(result.remainder.isEmpty)
    }

    func testKeepsPartialHeader() {
        let result = ChromecastFraming.splitFrames(Data([0, 0, 0]))
        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertEqual(result.remainder, Data([0, 0, 0]))
    }

    func testKeepsPartialBody() {
        let data = Data([0, 0, 0, 4, 1, 2])
        let result = ChromecastFraming.splitFrames(data)
        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertEqual(result.remainder, data)
    }

    func testSplitsTwoFramesAndRetainsRemainder() {
        var data = packet(Data([1]))
        data.append(packet(Data([2, 3])))
        data.append(contentsOf: [0, 0, 0, 2, 9])
        let result = ChromecastFraming.splitFrames(data)
        XCTAssertEqual(result.frames, [Data([1]), Data([2, 3])])
        XCTAssertEqual(result.remainder, Data([0, 0, 0, 2, 9]))
    }

    func testSplitsZeroLengthFrame() {
        let result = ChromecastFraming.splitFrames(Data([0, 0, 0, 0]))
        XCTAssertEqual(result.frames, [Data()])
        XCTAssertTrue(result.remainder.isEmpty)
    }
    func testRejectsOversizedFrame() {
        let result = ChromecastFraming.splitFrames(Data([0xff, 0xff, 0xff, 0xff]))
        XCTAssertTrue(result.oversized)
        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertTrue(result.remainder.isEmpty)
    }


    private func packet(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(body)
        return result
    }
}
