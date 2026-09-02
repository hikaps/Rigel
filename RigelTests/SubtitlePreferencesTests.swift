import XCTest
@testable import Rigel

final class SubtitlePreferencesTests: XCTestCase {
    func testBottomInsetClampsToSupportedRange() {
        let original = SubtitlePreferences.bottomInset
        defer { SubtitlePreferences.bottomInset = original }

        SubtitlePreferences.bottomInset = 1
        XCTAssertEqual(SubtitlePreferences.bottomInset, 40)

        SubtitlePreferences.bottomInset = 500
        XCTAssertEqual(SubtitlePreferences.bottomInset, 300)
    }

    func testDelayClampsToSupportedRange() {
        let original = SubtitlePreferences.delay
        defer { SubtitlePreferences.delay = original }

        SubtitlePreferences.delay = -20
        XCTAssertEqual(SubtitlePreferences.delay, -10)

        SubtitlePreferences.delay = 20
        XCTAssertEqual(SubtitlePreferences.delay, 10)
    }
}
