import SwiftUI
import UIKit
import CoreText

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Living-room palette: blue-black room, amber "tally lamp" for focus and now.
enum Palette {
    static let bg = UIColor(hex: 0x0A0F15)
    static let panel = UIColor(hex: 0x0F1720)
    static let cell = UIColor(hex: 0x16212C)
    static let cellNow = UIColor(hex: 0x1D2C3B)
    static let cellHover = UIColor(hex: 0x243546)
    static let line = UIColor(hex: 0x21303F)
    static let lineSoft = UIColor(hex: 0x18232E)
    static let fg = UIColor(hex: 0xE9EEF3)
    static let fg2 = UIColor(hex: 0xA3B3C3)
    static let fg3 = UIColor(hex: 0x6C7F92)
    static let accent = UIColor(hex: 0xF5A83C)
    static let accentInk = UIColor(hex: 0x1B1206)
    static let live = UIColor(hex: 0xEF4A40)
    static let ok = UIColor(hex: 0x5FD39A)
    static let logoBack = UIColor(hex: 0x0C131A)

    static func logo(_ hue: Double) -> UIColor {
        var h = hue.truncatingRemainder(dividingBy: 360) / 360
        if h < 0 { h += 1 }
        return UIColor(hue: CGFloat(h), saturation: 0.5, brightness: 0.45, alpha: 1)
    }
}

enum Theme {
    static let bg = Color(uiColor: Palette.bg)
    static let panel = Color(uiColor: Palette.panel)
    static let cell = Color(uiColor: Palette.cell)
    static let cellNow = Color(uiColor: Palette.cellNow)
    static let cellHover = Color(uiColor: Palette.cellHover)
    static let line = Color(uiColor: Palette.line)
    static let fg = Color(uiColor: Palette.fg)
    static let fg2 = Color(uiColor: Palette.fg2)
    static let fg3 = Color(uiColor: Palette.fg3)
    static let accent = Color(uiColor: Palette.accent)
    static let accentInk = Color(uiColor: Palette.accentInk)
    static let live = Color(uiColor: Palette.live)
    static let ok = Color(uiColor: Palette.ok)
}

enum TFont {
    /// Condensed San Francisco: fits more of a program title into a guide cell.
    static func cond(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight, width: .condensed)
    }
    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .medium) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    static func cond(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> Font {
        Font(TFont.cond(size, weight) as CTFont)
    }
}

enum Fmt {
    static func time(_ d: Date, _ h24: Bool) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        if h24 { return String(format: "%02d:%02d", h, m) }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12):" + String(format: "%02d", m) + (h < 12 ? " am" : " pm")
    }

    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return dayFormatter.string(from: d)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func localeUses24h() -> Bool {
        let f = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return !f.contains("a")
    }
}
