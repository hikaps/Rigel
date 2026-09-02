import Foundation
import UIKit

enum SubtitlePreferences {
    private static let bottomInsetKey = "subtitle-bottom-inset"
    private static let delayKey = "subtitle-delay-seconds"

    static var bottomInset: CGFloat {
        get {
            let value = UserDefaults.standard.object(forKey: bottomInsetKey) as? Double ?? 100
            return CGFloat(min(max(value, 40), 300))
        }
        set {
            UserDefaults.standard.set(min(max(Double(newValue), 40), 300), forKey: bottomInsetKey)
        }
    }

    /// A positive value shows each cue later; a negative value shows it earlier.
    static var delay: TimeInterval {
        get {
            let value = UserDefaults.standard.object(forKey: delayKey) as? Double ?? 0
            return min(max(value, -10), 10)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, -10), 10), forKey: delayKey)
        }
    }
}
