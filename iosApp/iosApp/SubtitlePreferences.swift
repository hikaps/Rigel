import Foundation
import UIKit

enum SubtitleColorPreset: String, CaseIterable, Hashable {
    case transparent
    case white
    case gold
    case cyan
    case red
    case brightGreen
    case purple
    case orange
    case blue
    case black
    case navy
    case darkRed
    case darkGreen
    case darkBlue

    var color: UIColor {
        switch self {
        case .transparent:
            return .clear
        case .white:
            return UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .gold:
            return UIColor(red: 1, green: 0.843, blue: 0, alpha: 1)
        case .cyan:
            return UIColor(red: 0, green: 0.898, blue: 1, alpha: 1)
        case .red:
            return UIColor(red: 1, green: 0.361, blue: 0.361, alpha: 1)
        case .brightGreen:
            return UIColor(red: 0, green: 1, blue: 0.533, alpha: 1)
        case .purple:
            return UIColor(red: 0.608, green: 0.349, blue: 0.714, alpha: 1)
        case .orange:
            return UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 1)
        case .blue:
            return UIColor(red: 0.231, green: 0.51, blue: 0.949, alpha: 1)
        case .black:
            return UIColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .navy:
            return UIColor(red: 0.067, green: 0.094, blue: 0.149, alpha: 1)
        case .darkRed:
            return UIColor(red: 0.498, green: 0.114, blue: 0.114, alpha: 1)
        case .darkGreen:
            return UIColor(red: 0.024, green: 0.306, blue: 0.231, alpha: 1)
        case .darkBlue:
            return UIColor(red: 0.118, green: 0.227, blue: 0.545, alpha: 1)
        }
    }

    var displayName: String {
        switch self {
        case .transparent: return "Transparent"
        case .white: return "White"
        case .gold: return "Gold"
        case .cyan: return "Cyan"
        case .red: return "Red"
        case .brightGreen: return "Green"
        case .purple: return "Purple"
        case .orange: return "Orange"
        case .blue: return "Blue"
        case .black: return "Black"
        case .navy: return "Navy"
        case .darkRed: return "Dark red"
        case .darkGreen: return "Dark green"
        case .darkBlue: return "Dark blue"
        }
    }
}

struct SubtitleAppearance: Equatable {
    var fontSizePoints: CGFloat
    var bold: Bool
    var textColor: SubtitleColorPreset
    var textOpacity: CGFloat
    var backgroundColor: SubtitleColorPreset
    var backgroundOpacity: CGFloat
    var outlineEnabled: Bool
    var outlineColor: SubtitleColorPreset
    var bottomInset: CGFloat

    static let `default` = SubtitleAppearance(
        fontSizePoints: 20,
        bold: false,
        textColor: .white,
        textOpacity: 1,
        backgroundColor: .transparent,
        backgroundOpacity: 0,
        outlineEnabled: true,
        outlineColor: .black,
        bottomInset: 100
    )
}

enum SubtitlePreferences {
    private static let defaults = UserDefaults.standard
    private static let bottomInsetKey = "subtitle-bottom-inset"
    private static let delayKey = "subtitle-delay-seconds"
    private static let fontSizeKey = "subtitle-font-size-points"
    private static let boldKey = "subtitle-bold"
    private static let textColorKey = "subtitle-text-color"
    private static let textOpacityKey = "subtitle-text-opacity"
    private static let backgroundColorKey = "subtitle-background-color"
    private static let backgroundOpacityKey = "subtitle-background-opacity"
    private static let outlineEnabledKey = "subtitle-outline-enabled"
    private static let outlineColorKey = "subtitle-outline-color"

    static var appearance: SubtitleAppearance {
        get {
            let fallback = SubtitleAppearance.default
            return SubtitleAppearance(
                fontSizePoints: normalized(
                    double(forKey: fontSizeKey, default: Double(fallback.fontSizePoints)),
                    range: 12...40,
                    step: 2
                ),
                bold: defaults.object(forKey: boldKey) as? Bool ?? fallback.bold,
                textColor: color(forKey: textColorKey, default: fallback.textColor),
                textOpacity: normalized(
                    double(forKey: textOpacityKey, default: Double(fallback.textOpacity)),
                    range: 0...1
                ),
                backgroundColor: color(forKey: backgroundColorKey, default: fallback.backgroundColor),
                backgroundOpacity: normalized(
                    double(forKey: backgroundOpacityKey, default: Double(fallback.backgroundOpacity)),
                    range: 0...1
                ),
                outlineEnabled: defaults.object(forKey: outlineEnabledKey) as? Bool ?? fallback.outlineEnabled,
                outlineColor: color(forKey: outlineColorKey, default: fallback.outlineColor),
                bottomInset: normalized(
                    double(forKey: bottomInsetKey, default: Double(fallback.bottomInset)),
                    range: 40...300,
                    step: 10
                )
            )
        }
        set {
            let normalizedAppearance = SubtitleAppearance(
                fontSizePoints: normalized(
                    Double(newValue.fontSizePoints),
                    range: 12...40,
                    step: 2
                ),
                bold: newValue.bold,
                textColor: newValue.textColor,
                textOpacity: normalized(Double(newValue.textOpacity), range: 0...1),
                backgroundColor: newValue.backgroundColor,
                backgroundOpacity: normalized(Double(newValue.backgroundOpacity), range: 0...1),
                outlineEnabled: newValue.outlineEnabled,
                outlineColor: newValue.outlineColor,
                bottomInset: normalized(
                    Double(newValue.bottomInset),
                    range: 40...300,
                    step: 10
                )
            )
            defaults.set(Double(normalizedAppearance.fontSizePoints), forKey: fontSizeKey)
            defaults.set(normalizedAppearance.bold, forKey: boldKey)
            defaults.set(normalizedAppearance.textColor.rawValue, forKey: textColorKey)
            defaults.set(Double(normalizedAppearance.textOpacity), forKey: textOpacityKey)
            defaults.set(normalizedAppearance.backgroundColor.rawValue, forKey: backgroundColorKey)
            defaults.set(Double(normalizedAppearance.backgroundOpacity), forKey: backgroundOpacityKey)
            defaults.set(normalizedAppearance.outlineEnabled, forKey: outlineEnabledKey)
            defaults.set(normalizedAppearance.outlineColor.rawValue, forKey: outlineColorKey)
            defaults.set(Double(normalizedAppearance.bottomInset), forKey: bottomInsetKey)
        }
    }

    /// A positive value shows each cue later; a negative value shows it earlier.
    static var delay: TimeInterval {
        get {
            let value = double(forKey: delayKey, default: 0)
            return min(max(value, -10), 10)
        }
        set {
            defaults.set(min(max(newValue, -10), 10), forKey: delayKey)
        }
    }

    static func reset() {
        appearance = .default
        delay = 0
    }

    private static func color(forKey key: String, default fallback: SubtitleColorPreset) -> SubtitleColorPreset {
        guard let rawValue = defaults.string(forKey: key),
              let color = SubtitleColorPreset(rawValue: rawValue) else {
            return fallback
        }
        return color
    }

    private static func double(forKey key: String, default fallback: Double) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber else {
            return fallback
        }
        return value.doubleValue
    }

    private static func normalized(
        _ value: Double,
        range: ClosedRange<Double>,
        step: Double? = nil
    ) -> CGFloat {
        let finite = value.isFinite ? value : range.lowerBound
        let clamped = min(max(finite, range.lowerBound), range.upperBound)
        guard let step, step > 0 else { return CGFloat(clamped) }
        let stepped = (clamped / step).rounded() * step
        return CGFloat(min(max(stepped, range.lowerBound), range.upperBound))
    }
}
