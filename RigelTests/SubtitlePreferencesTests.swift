import XCTest
@testable import Rigel

final class SubtitlePreferencesTests: XCTestCase {
    private let keys = [
        "subtitle-bottom-inset",
        "subtitle-delay-seconds",
        "subtitle-font-size-points",
        "subtitle-bold",
        "subtitle-text-color",
        "subtitle-text-opacity",
        "subtitle-background-color",
        "subtitle-background-opacity",
        "subtitle-outline-enabled",
        "subtitle-outline-color",
    ]

    func testDefaultsMatchPlayerAppearanceContract() {
        withCleanPreferences {
            XCTAssertEqual(SubtitlePreferences.appearance, .default)
            XCTAssertEqual(SubtitlePreferences.delay, 0)
        }
    }

    func testAppearanceClampsSupportedRanges() {
        withCleanPreferences {
            SubtitlePreferences.appearance = SubtitleAppearance(
                fontSizePoints: 1,
                bold: true,
                textColor: .gold,
                textOpacity: -1,
                backgroundColor: .navy,
                backgroundOpacity: 2,
                outlineEnabled: false,
                outlineColor: .cyan,
                bottomInset: 500
            )

            let appearance = SubtitlePreferences.appearance
            XCTAssertEqual(appearance.fontSizePoints, 12)
            XCTAssertEqual(appearance.textOpacity, 0)
            XCTAssertEqual(appearance.backgroundOpacity, 1)
            XCTAssertEqual(appearance.bottomInset, 300)
            XCTAssertTrue(appearance.bold)
            XCTAssertEqual(appearance.textColor, .gold)
            XCTAssertEqual(appearance.backgroundColor, .navy)
            XCTAssertFalse(appearance.outlineEnabled)
            XCTAssertEqual(appearance.outlineColor, .cyan)
        }
    }

    func testDelayClampsToSupportedRange() {
        withCleanPreferences {
            SubtitlePreferences.delay = -20
            XCTAssertEqual(SubtitlePreferences.delay, -10)

            SubtitlePreferences.delay = 20
            XCTAssertEqual(SubtitlePreferences.delay, 10)
        }
    }

    func testInvalidStoredColorsFallBackToFieldDefaults() {
        withCleanPreferences {
            let defaults = UserDefaults.standard
            defaults.set("not-a-color", forKey: "subtitle-text-color")
            defaults.set("not-a-color", forKey: "subtitle-background-color")
            defaults.set("not-a-color", forKey: "subtitle-outline-color")

            let appearance = SubtitlePreferences.appearance
            XCTAssertEqual(appearance.textColor, .white)
            XCTAssertEqual(appearance.backgroundColor, .transparent)
            XCTAssertEqual(appearance.outlineColor, .black)
        }
    }

    func testAppearanceRoundTripsAndResetRestoresDefaults() {
        withCleanPreferences {
            let custom = SubtitleAppearance(
                fontSizePoints: 28,
                bold: true,
                textColor: .cyan,
                textOpacity: 0.7,
                backgroundColor: .darkBlue,
                backgroundOpacity: 0.6,
                outlineEnabled: false,
                outlineColor: .white,
                bottomInset: 180
            )
            SubtitlePreferences.appearance = custom
            SubtitlePreferences.delay = -3.4

            XCTAssertEqual(SubtitlePreferences.appearance, custom)
            XCTAssertEqual(SubtitlePreferences.delay, -3.4, accuracy: 0.0001)

            SubtitlePreferences.reset()
            XCTAssertEqual(SubtitlePreferences.appearance, .default)
            XCTAssertEqual(SubtitlePreferences.delay, 0)
        }
    }

    private func withCleanPreferences(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        var saved: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                saved[key] = value
            }
        }
        defer {
            for key in keys {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in saved {
                defaults.set(value, forKey: key)
            }
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        body()
    }
}
